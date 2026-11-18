defmodule AtlasE2E.PullTest.Support do
  @moduledoc false
  # The pull-e2e harness tests' shared pieces: a temp folder, the stub built once per run,
  # a hub, and a liveness FIFO: a child that holds its write end (`exec 5>"$fifo"`) is gone
  # exactly when the watcher (a `cat` on it) sees the end of the file, an event, no `ps`.

  def tmp!(name) do
    dir = Path.join(System.tmp_dir!(), "pe-test-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    # Resolved, as the wrapper's run folder is (/tmp → /private/tmp on macOS).
    {resolved, 0} = System.cmd("/bin/sh", ["-c", ~s(cd "$0" && pwd -P), dir])
    String.trim(resolved)
  end

  @doc """
  The stub built from the sources in this tree, once per content: its path names the
  sha256 of `pull/stub`'s Go sources and `go.mod`. A binary built from other sources (an
  earlier round's, left in the same temp folder) is never taken for it (gatefix round 1:
  the gate's tests ran a stale `pe-test-stub/pull-stub` with the old tether). Built under a
  unique name and renamed into place, so tests that build it at once never see half a file.
  """
  def stub! do
    out = Path.join([System.tmp_dir!(), "pe-test-stub-#{stub_digest()}", "pull-stub"])

    unless File.exists?(out) do
      gocache = Path.join(System.tmp_dir!(), "pe-test-gocache")
      partial = "#{out}.#{System.unique_integer([:positive])}"
      AtlasE2E.Pull.Stub.build!(partial, env: [{"GOCACHE", gocache}])
      File.rename!(partial, out)
    end

    out
  end

  @doc "The sha256 (hex) of the stub's sources: each `*.go` file and `go.mod`, by name."
  def stub_digest(source \\ AtlasE2E.Pull.Stub.source()) do
    files = Enum.sort(Path.wildcard(Path.join(source, "*.go")) ++ [Path.join(source, "go.mod")])

    files
    |> Enum.map(&[Path.basename(&1), 0, File.read!(&1), 0])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def hub! do
    name = :"pull_hub_#{System.unique_integer([:positive])}"
    {:ok, _} = AtlasE2E.Pull.Hub.start_link(name: name)
    name
  end

  @doc """
  A liveness FIFO in `dir` and its watcher Port: `{fifo, watcher}`. The watcher is tethered:
  a `cat` still blocked opening a FIFO nobody writes holds no file and would outlive the
  test; the tether ends it with the test BEAM, however that ends.

  The test's own stop of what holds it (gatefix R1): on exit, passed or failed,
  `stop_holders/1` KILLs each `holding/2` child on this FIFO that is still there, so a
  child the tether's KILL did not reach (a regressed tether, a stale stub) does not outlive
  the test. A test BEAM that is itself killed runs no `on_exit`; that path is the tether's.
  """
  def liveness!(dir) do
    fifo = Path.join(dir, "alive-#{System.unique_integer([:positive])}.fifo")
    {_, 0} = System.cmd("mkfifo", [fifo])
    args = ["tether", "--", "/bin/cat", fifo]

    watcher =
      Port.open({:spawn_executable, stub!()}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args
      ])

    ExUnit.Callbacks.on_exit(fn -> stop_holders(fifo) end)
    {fifo, watcher}
  end

  @doc "Run `stub args` tethered (a probe that might block ends with the test BEAM)."
  def tethered(stub, args),
    do: System.cmd(stub, ["tether", "--", stub | args], stderr_to_stdout: true)

  @doc """
  A shell command that adds its pid to `fifo.pids` (`holders/1`; it stays the pid of `then`),
  holds `fifo` open for writing, says `up` through it (the watcher gets `{:data, "up\\n"}`:
  the child is there and its pid is written), then becomes `then`.
  """
  def holding(fifo, then),
    do: ["-c", ~s(echo "$$" >> "$0.pids"; exec 5>"$0"; echo up >&5; exec "$@"), fifo | then]

  @doc "The pids `holding/2` children on `fifo` wrote, oldest first."
  def holders(fifo) do
    case File.read(fifo <> ".pids") do
      {:ok, text} ->
        for line <- String.split(text, "\n", trim: true),
            {pid, ""} <- [Integer.parse(line)],
            do: pid

      {:error, _} ->
        []
    end
  end

  @doc """
  KILLs each `holders/1` pid that is still there, and its group if it leads one (a command
  the tether did not keep in its group); returns the pids it KILLed. A pid is only reused
  after the pid space wraps, which a test does not live to see.
  """
  def stop_holders(fifo) do
    kill =
      ~s(kill -0 "$0" 2>/dev/null || exit 1; kill -KILL -- "-$0" 2>/dev/null; kill -KILL "$0")

    for pid <- holders(fifo),
        {_, 0} <- [System.cmd("/bin/sh", ["-c", kill, "#{pid}"], stderr_to_stdout: true)],
        do: pid
  end

  @doc """
  Every external process a harness test starts goes through here (N1): a Port on
  `pull-stub tether -- command args`. When the test BEAM ends, however it ends (a failed
  assert, a test timeout, a SIGKILL), the tether sees its stdin end and KILLs the command's
  group, so nothing a test started outlives it. Signalling the Port's os pid (the tether)
  forwards TERM/INT to the command (its group would send them back to the tether).
  """
  def port!(command, args, opts \\ []) do
    env =
      Enum.map(opts[:env] || [], fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    Port.open({:spawn_executable, stub!()}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: ["tether", "--", command | args],
      env: env
    ])
  end

  @doc """
  `pull/run.sh` with a fake `mix` in `dir/fake` (tethered, `port!/3`): `--prepare` exits 0,
  `--reap` exits `reap_status`, `--run` logs and then `:exit0` or `:hold` (says `ready` through
  `dir/ready.fifo`, then blocks). With `alive:` the wrapper and its children hold that
  liveness FIFO. `%{port, reader, log}`; `reader` (tethered too) reads `ready.fifo` when `:hold`.
  """
  def wrapper!(dir, reap_status, run_mode, opts \\ []) do
    bin = Path.join(dir, "fake")
    File.mkdir_p!(bin)
    log = Path.join(dir, "trace.log")
    ready = Path.join(dir, "ready.fifo")
    hold = Path.join(dir, "hold.fifo")
    {_, 0} = System.cmd("mkfifo", [ready, hold])

    run_body =
      case run_mode do
        :hold -> "echo ready > '#{ready}'; exec 3<> '#{hold}'; read -r _ <&3"
        :exit0 -> "exit 0"
      end

    File.write!(Path.join(bin, "mix"), """
    #!/bin/sh
    case "$*" in
      *--prepare*) echo prepare >> '#{log}'; exit 0 ;;
      *--reap*) echo reap >> '#{log}'; exit #{reap_status} ;;
      *--run*) echo run >> '#{log}'; #{run_body} ;;
    esac
    """)

    File.chmod!(Path.join(bin, "mix"), 0o755)
    reader = if run_mode == :hold and opts[:reader] != false, do: port!("/bin/cat", [ready])
    run_sh = Path.expand("../../pull/run.sh", __DIR__)

    {command, args} =
      if alive = opts[:alive], do: {"/bin/sh", holding(alive, [run_sh])}, else: {run_sh, []}

    port =
      port!(command, args,
        env: [
          {"PATH", bin <> ":/usr/bin:/bin"},
          {"PULL_E2E_TRACE", log},
          {"PULL_E2E_RUN_PARENT", dir}
        ]
      )

    %{port: port, reader: reader, log: log}
  end
end

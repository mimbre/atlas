defmodule AtlasE2E.Pull.Stub do
  @moduledoc """
  The bench's side of the stub agent (`pull/stub/main.go`): building it, the Runtime's
  `codex` on PATH, the FIFO its events come through, and its gate.

  An agent reports `started` (token, pid, pgid, cwd, root, `base_sha256`, gate), `gated`
  (the command it read), `ended` (`how`) or `signalled` to `<run>/stub/events.fifo`. The
  FIFO's reader holds it open for writing too (`exec 3<>`), so it never sees an end of file
  between two agents. Each `started` agent is recorded in the registry (pid, its turn's
  pgid, its gate) for the reaper. It acts only on its gate's command (`gate/3`).
  """
  alias AtlasE2E.Pull.{Bench, Hub, Reader}

  @source Path.expand("../../../pull/stub", __DIR__)

  def source, do: @source

  @doc "Build the stub into `<run>/bin/pull-stub` (go, standard library only)."
  def build!(out, opts \\ []) do
    File.mkdir_p!(Path.dirname(out))

    env =
      [{"GOTELEMETRY", "off"}, {"GOTOOLCHAIN", "local"}, {"CGO_ENABLED", "0"}] ++
        (opts[:env] || [])

    case Bench.bounded("go", ["build", "-o", out, "."],
           cd: @source,
           env: env,
           within: opts[:within] || 120_000
         ) do
      {_, 0} -> out
      {text, status} -> raise "pull-stub does not build (#{inspect(status)}):\n#{text}"
    end
  end

  @doc "The `codex` (and `claude`) wrappers in `bin_dir` that exec the stub as the agent."
  def wrappers!(bin_dir, run, stub) do
    File.mkdir_p!(bin_dir)

    for name <- ["codex", "claude"] do
      file = Path.join(bin_dir, name)
      File.write!(file, "#!/bin/sh\nexec '#{stub}' agent '#{run}' \"$0\" \"$@\"\n")
      File.chmod!(file, 0o755)
    end

    :ok
  end

  @doc "The events FIFO and its reader (a `Reader` publishing `:stub` events)."
  def events!(run, opts \\ []) do
    dir = Path.join(run, "stub")
    File.mkdir_p!(Path.join(dir, "gates"))
    fifo = Path.join(dir, "events.fifo")

    unless File.exists?(fifo) do
      {_, 0} = System.cmd("mkfifo", [fifo])
    end

    stub = opts[:stub] || Path.join(run, "bin/pull-stub")
    hub = opts[:hub] || Hub

    {:ok, reader} =
      Reader.start_link(
        command: "/bin/sh",
        args: ["-c", ~s(exec 3<>"$0"; exec cat <&3), fifo],
        stub: stub,
        source: :stub,
        name: "stub-events",
        run: run,
        hub: hub,
        on_event: fn
          %{data: %{"event" => "started"} = e} ->
            Bench.record(run, "stub", %{
              pid: e["pid"],
              pgid: e["pgid"],
              gate: e["gate"],
              bin: stub,
              token: e["token"]
            })

          _ ->
            :ok
        end
      )

    reader
  end

  @doc """
  Give the agent of a `started` event its command, within the step's budget: `%{"cmd" =>
  "complete", "edits" => [...], "answer" => text}`, `%{"cmd" => "fail"}` or `%{"cmd" => "hang"}`.
  """
  def gate(run, %{"gate" => gate}, command, opts \\ []) do
    stub = opts[:stub] || Path.join(run, "bin/pull-stub")

    # Never blocks: the agent holds its gate open while it waits; exit 3 means none waits.
    case Bench.bounded(stub, ["gate", gate, JSON.encode!(command)], within: Bench.remaining()) do
      {_, 0} -> :ok
      {out, 3} -> raise "no agent waits at #{gate}: #{out}"
      {out, status} -> raise "the gate #{gate} refused its command (#{inspect(status)}): #{out}"
    end
  end

  @doc "A `complete` command."
  def complete(edits, answer \\ nil),
    do: %{"cmd" => "complete", "edits" => edits, "answer" => answer}

  def write(path, text), do: %{"op" => "write", "path" => path, "text" => text}

  def blob(path, size, seed),
    do: %{"op" => "blob", "path" => path, "size" => size, "seed" => seed}

  def delete(path), do: %{"op" => "delete", "path" => path}

  @doc "Whether a hub event is the stub event `event` (for `token`, when given)."
  def event?(event, name, token \\ nil)

  def event?(%{source: :stub, data: %{"event" => e} = d}, event, token),
    do: e == event and (token == nil or d["token"] == token)

  def event?(_, _, _), do: false
end

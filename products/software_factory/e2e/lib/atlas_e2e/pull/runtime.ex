defmodule AtlasE2E.Pull.Runtime do
  @moduledoc """
  A real Runtime for the pull-e2e, from a home of its own under `<run>/rt/<name>/h`, started
  with `atlas-runtime service start` (no Mix: `host/operations.go` runs the service on the
  build's ebin paths) in a session of its own.

  `prepare/3` writes the home (0700): `policy.json` (slots `s1`, `s2`; `deep_coding` with the
  one option codex/openai/gpt-test; the sources `local` and `flow-test`, the latter at the
  edge with its token and, D5, its `ca_file`), `sources/flow-test/token` (32 random bytes as
  hex, no newline, 0600) and `sources/flow-test/ca.pem`. Its `PATH` starts with
  `<run>/rt/<name>/bin`, where `codex` is the stub (`AtlasE2E.Pull.Stub.wrappers!/3`);
  `check_path/2` refuses a run where `codex` resolves anywhere else.

  Several can run at once (F2/F3), each keyed by `name` with its own registry rows; a
  second one on the same machine needs D7 (`runtime_id` in `policy.json`), which is F2/F3's.
  """
  alias AtlasE2E.Pull.{Bench, Reader, Stub}

  defstruct [
    :name,
    :run,
    :dir,
    :home,
    :cli,
    :bin,
    :path,
    :env,
    :token,
    :incarnation,
    :group,
    :events
  ]

  @doc """
  The Runtime CLI built from this checkout into `out` (before the timed run, `AtlasE2E.Pull.Prepare`).
  """
  def build_cli!(out, root, opts \\ []) do
    File.mkdir_p!(Path.dirname(out))

    args = [
      "-C",
      Path.join(root, "platform/atlas_runtime/host"),
      "build",
      "-ldflags",
      "-X main.repoRoot=#{root}",
      "-o",
      out,
      "."
    ]

    env = [{"GOTELEMETRY", "off"}, {"GOTOOLCHAIN", "local"}]

    case Bench.bounded("go", args, env: env, within: opts[:within] || 120_000, stub: opts[:stub]) do
      {_, 0} -> out
      {text, status} -> raise "atlas-runtime does not build (#{inspect(status)}):\n#{text}"
    end
  end

  @doc """
  The Runtime service's build, as `atlas-runtime service start` makes it (`host/main.go`,
  `serviceCommands`: `mix do deps.get + compile --warnings-as-errors` in
  products/software_factory, `MIX_ENV=test`, no `ATLAS_*`), into `build` (the warm cache).
  A home then starts from a copy of it (`prepare/3`, `build:`), so the CLI's own build is a no-op.
  """
  def build_service!(build, root, opts \\ []) do
    env =
      for({k, _} <- System.get_env(), String.starts_with?(k, "ATLAS_"), do: {k, nil}) ++
        [{"MIX_ENV", "test"}, {"MIX_BUILD_PATH", build}, {"ELIXIR_ERL_OPTIONS", "+S 2:2"}]

    case Bench.bounded("mix", ["do", "deps.get", "+", "compile", "--warnings-as-errors"],
           cd: Path.join(root, "products/software_factory"),
           env: env,
           within: opts[:within] || 900_000,
           stub: opts[:stub]
         ) do
      {_, 0} -> build
      {text, status} -> raise "the Runtime service does not build (#{inspect(status)}):\n#{text}"
    end
  end

  @doc """
  The Runtime home `name` in `<run>/rt/<name>/h`. Options: `edge_port`, `ca_pem`, `cli`,
  `stub`, `build` (the warm service build, copied to `<home>/build`), and the F2/F3 hooks'
  `policy` (a function on the policy map) and `path` (more folders after the stub's).
  """
  def prepare(run, name, opts) do
    dir = Path.join([run, "rt", to_string(name)])
    home = Path.join(dir, "h")
    bin = Path.join(dir, "bin")
    source = Path.join(home, "sources/flow-test")
    File.mkdir_p!(source)
    File.chmod!(home, 0o700)
    File.mkdir_p!(Path.join(dir, "codex-home"))

    token = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
    write_private!(Path.join(source, "token"), token)
    File.write!(Path.join(source, "ca.pem"), opts[:ca_pem])

    policy = (opts[:policy] || (& &1)).(policy(opts[:edge_port]))
    File.write!(Path.join(home, "policy.json"), JSON.encode!(policy))

    Stub.wrappers!(bin, run, opts[:stub] || Path.join(run, "bin/pull-stub"))

    # The warm build (Main's ruling): a copy, so a run never changes the cache it came from.
    if build = opts[:build] do
      {_, 0} = System.cmd("cp", ["-Rp", build, Path.join(home, "build")])
    end

    for tool <- ["git", "mkfifo"] do
      target = System.find_executable(tool) || raise "#{tool} is not on PATH"
      File.ln_s(target, Path.join(bin, tool))
    end

    path =
      Enum.join(
        [bin | opts[:path] || []] ++ toolchain() ++ ["/usr/bin", "/bin", "/usr/sbin", "/sbin"],
        ":"
      )

    cli = opts[:cli] || Path.join(run, "bin/atlas-runtime")

    env = [
      {"ATLAS_RUNTIME_HOME", home},
      {"PATH", path},
      {"CODEX_HOME", Path.join(dir, "codex-home")}
    ]

    :ok = check_path(path, Path.join(bin, "codex"))
    Bench.record(run, "runtime_home", %{name: to_string(name), home: home, cli: cli})

    %__MODULE__{
      name: name,
      run: run,
      dir: dir,
      home: home,
      cli: cli,
      bin: bin,
      path: path,
      env: env,
      token: token
    }
  end

  @doc "The policy the bench's Runtime runs with (edited by F2/F3's `policy/1` hook)."
  def policy(edge_port) do
    %{
      "version" => 1,
      "changed_by" => "pull-e2e",
      "slots" => ["s1", "s2"],
      "profiles" => %{
        "deep_coding" => %{
          "permissions" => [
            "dedicated-repository",
            "materialized-folder",
            "workspace-write",
            "read-only"
          ],
          "cost_classes" => ["low", "standard", "high"],
          "options" => [%{"provider" => "openai", "harness" => "codex", "model" => "gpt-test"}],
          "allow_after_check" => true
        }
      },
      "sources" => [
        %{
          "name" => "local",
          "kind" => "builtin",
          "priority" => 1,
          "max_slots" => 2,
          "max_store_bytes" => 2_147_483_648
        },
        %{
          "name" => "flow-test",
          "kind" => "remote",
          "url" => "https://localhost:#{edge_port}",
          "credential_file" => "sources/flow-test/token",
          "ca_file" => "sources/flow-test/ca.pem",
          "priority" => 2,
          "max_slots" => 2,
          "max_store_bytes" => 268_435_456
        }
      ]
    }
  end

  # Erlang's and Elixir's own bin folders (not asdf's shims, which need asdf's environment).
  defp toolchain do
    erl = Path.join(to_string(:code.root_dir()), "bin")
    elixir = :code.lib_dir(:elixir) |> to_string() |> Path.join("../../bin") |> Path.expand()
    Enum.uniq([elixir, erl])
  end

  @doc "`:ok` when `command -v codex` under `path` is `expected`; else `{:error, found}`."
  def check_path(path, expected) do
    {found, _} = System.cmd("/bin/sh", ["-c", "command -v codex || true"], env: [{"PATH", path}])

    case String.trim(found) do
      ^expected -> :ok
      other -> {:error, other}
    end
  end

  defp write_private!(file, bytes) do
    File.write!(file, "")
    File.chmod!(file, 0o600)
    File.write!(file, bytes)
  end

  @doc """
  `atlas-runtime service start`; returns the Runtime with its incarnation and its group
  (the CLI's own `Setsid` for the service BEAM: the `ps` line holding
  `host/service.exs <home>`), both recorded.
  """
  def start(%__MODULE__{} = rt, opts \\ []) do
    case Bench.session(rt.run, "runtime #{rt.name}", rt.cli, ["service", "start"], env: rt.env) do
      {out, 0} ->
        info = last_json(out)
        group = group(rt, opts[:ps] || (&Bench.ps/0))

        Bench.record(rt.run, "runtime_group", %{
          name: to_string(rt.name),
          pid: group.pid,
          pgid: group.pgid
        })

        %{rt | incarnation: info["incarnation"], group: group}

      {out, status} ->
        raise "atlas-runtime service start failed (#{status}):\n#{out}"
    end
  end

  @doc "`atlas-runtime service stop --force` (returns once `backend.sock` is gone, ≤ 60 s)."
  def stop(%__MODULE__{} = rt) do
    case Bench.session(rt.run, "runtime-stop #{rt.name}", rt.cli, ["service", "stop", "--force"],
           env: rt.env
         ) do
      {_, 0} -> :ok
      {out, status} -> raise "atlas-runtime service stop failed (#{status}):\n#{out}"
    end
  end

  @doc "A crash: KILL the service's group (its turns' groups survive, as in a real crash)."
  def crash(%__MODULE__{group: %{pgid: pgid}}, own_pgid) do
    {:ok, true} = Bench.kill_group(pgid, own_pgid)
    :ok
  end

  @doc "`service status`: the runtime info (`incarnation`, `mode`, …)."
  def status(%__MODULE__{} = rt) do
    {out, 0} =
      Bench.bounded(rt.cli, ["service", "status"],
        env: rt.env,
        stub: Path.join(rt.run, "bin/pull-stub")
      )

    last_json(out)
  end

  @doc "Follow the journal: `events --follow` as a `Reader` (`:rt` events)."
  def follow(%__MODULE__{} = rt, hub \\ AtlasE2E.Pull.Hub) do
    {:ok, reader} =
      Reader.start_link(
        command: rt.cli,
        args: ["events", "--follow"],
        env: rt.env,
        stub: Path.join(rt.run, "bin/pull-stub"),
        source: :rt,
        name: "rt-events-#{rt.name}",
        run: rt.run,
        hub: hub
      )

    %{rt | events: reader}
  end

  defp group(rt, ps) do
    marker = "host/service.exs #{rt.home}"

    case Enum.find(ps.(), &String.contains?(&1.command, marker)) do
      %{pid: pid, pgid: pgid} -> %{pid: pid, pgid: pgid}
      nil -> raise "no process runs #{marker} after service start"
    end
  end

  defp last_json(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find_value(%{}, fn line ->
      case JSON.decode(line) do
        {:ok, %{} = map} -> map
        _ -> nil
      end
    end)
  end
end

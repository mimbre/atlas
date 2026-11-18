defmodule AtlasE2E.Pull.Core do
  @moduledoc """
  rela and the core for the pull-e2e: a private `--env test` instance in `<run>/inst`
  (`AtlasE2E.Instance.prepare/2`) with Flow's work source on, started with `atlas-ops` in
  a session of its own (`AtlasE2E.Pull.Bench.session/5`).

  - `extra/1`: the settings the bench adds (plan rev 2 §4): Flow's work source on a free
    port, its credentials variable and result store, the test timing (D6: `lease_ttl` 180,
    `poll_max` 5, `sweep_ms` 1 000, `resync_ms` 5 000, `result_cap` 12 000 000; no `grace`),
    and `code_settings/1`.
  - `code_settings/1`: Code registered in the core (#342, merged as `code.home` and
    `code.sources`): its home `<run>/code-home`, the repository the package's input names
    (`github.com/mimbre/atlas`) read anonymously from the fixture remote. The one place that
    knows #342's shape; F2/F3's `code/1` hook adds to it (`AtlasE2E.Pull.Needs`).
  - `credentials/3`: `{"<runtime id>": {"holder", "token_sha256"}}`, the lower-case hex
    sha256 of the token file's exact bytes, in `ATLAS_E2E_FLOW_CREDENTIALS`.
  - rela is started first, alone (`start-bg.sh`, as `atlas-ops` does), so the seed
    (`AtlasE2E.Pull.Seed`) is in it before the core's first round.
  - `restart/3` and `stop/2` run `atlas-ops`; after every restart the core's pid is read
    again from `<run>/inst/core.pid` and recorded.
  """
  alias AtlasE2E.Instance
  alias AtlasE2E.Pull.Bench

  @credentials_env "ATLAS_E2E_FLOW_CREDENTIALS"
  @repository "github.com/mimbre/atlas"

  def repository, do: @repository

  def extra(%{run: run, ws_port: ws_port, remote_url: remote_url}) do
    %{
      "flow" => %{
        "tick_seconds" => 5,
        "work_source" => %{
          "port" => ws_port,
          "credentials_env" => @credentials_env,
          "results" => Path.join(run, "results"),
          "lease_ttl" => lease_ttl(),
          "poll_max" => 5,
          "sweep_ms" => 1_000,
          "resync_ms" => 5_000,
          "result_cap" => 12_000_000
        }
      }
    }
    |> Instance.deep_merge(code_settings(%{run: run, remote_url: remote_url}))
  end

  @doc "#342's settings fragment: Code's home and the repositories it reads bases from."
  def code_settings(%{run: run, remote_url: remote_url}) do
    %{
      "code" => %{
        "home" => Path.join(run, "code-home"),
        "sources" => %{@repository => %{"url" => remote_url, "credentials" => "none"}}
      }
    }
  end

  def credentials(runtime_id, holder, token) do
    JSON.encode!(%{runtime_id => %{"holder" => holder, "token_sha256" => sha(token)}})
  end

  def sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @doc "The instance in `<run>/inst` with `extra` merged (nothing started)."
  def prepare(run, extra) do
    instance = Instance.prepare(extra, dir: Path.join(run, "inst"))
    Bench.record(run, "instance", %{file: instance.file, root: instance.root})

    for {name, port} <- [
          {"rela", instance.settings["rela"]["port"]},
          {"control", instance.settings["control"]["port"]},
          {"work_source", get_in(instance.settings, ["flow", "work_source", "port"])}
        ],
        do: Bench.record(run, "listen", %{port: port, name: name})

    instance
  end

  @doc "Start rela alone (its own session, as `start-bg.sh` makes it) and record its pid."
  def start_rela(run, instance) do
    rela = instance.settings["rela"]

    env = [
      {"ATLAS_RELA_PORT", "#{rela["port"]}"},
      {"ATLAS_RELA_DATA", rela["data"]},
      {"ATLAS_RELA_BIN", rela["bin"]},
      {"ATLAS_TEST_ROOT", Path.dirname(rela["data"])}
    ]

    script = Path.join(instance.root, "platform/atlas_facts/rela/scripts/start-bg.sh")

    case Bench.session(run, "rela-start", script, [], env: env, cd: instance.root) do
      {_, 0} -> record_rela(run, instance)
      {out, status} -> raise "rela did not start (#{status}):\n#{out}"
    end
  end

  defp record_rela(run, instance) do
    file = Path.join(Path.dirname(instance.settings["rela"]["data"]), "rela-server.pid")
    pid = file |> File.read!() |> String.trim() |> String.to_integer()
    # perl's setsid made rela a session of its own: its pgid is its pid.
    Bench.record(run, "rela", %{pid: pid, pgid: pid})
    pid
  end

  @doc "`atlas-ops restart --env test` with `holder`'s credential; returns the core's pid."
  def restart(run, instance, credentials) do
    env = instance.env ++ [{@credentials_env, credentials}]

    case Bench.session(
           run,
           "core",
           Path.join(instance.root, "bin/atlas-ops"),
           ["restart", "--env", "test"],
           env: env,
           cd: instance.root
         ) do
      {_, 0} -> core_pid(run, instance)
      {out, status} -> raise "atlas-ops restart failed (#{status}):\n#{out}"
    end
  end

  @doc "`atlas-ops stop --env test`: the core only; rela keeps running."
  def stop(run, instance) do
    case Bench.session(
           run,
           "core-stop",
           Path.join(instance.root, "bin/atlas-ops"),
           ["stop", "--env", "test"],
           env: instance.env,
           cd: instance.root
         ) do
      {_, 0} -> :ok
      {out, status} -> raise "atlas-ops stop failed (#{status}):\n#{out}"
    end
  end

  @doc "Read `<run>/inst/core.pid` and record it (every restart has a new one)."
  def core_pid(run, instance) do
    pid =
      Path.join(instance.dir, "core.pid")
      |> File.read!()
      |> String.trim()
      |> String.to_integer()

    Bench.record(run, "core", %{pid: pid})
    pid
  end

  @doc "A person, through `atlas put person` (Control, as a script would), bounded by the step."
  def person!(run, instance, name) do
    args = ["put", "person", "--name", name, "--env", "test"]

    case Bench.session(run, "atlas-put-person", Path.join(instance.root, "bin/atlas"), args,
           env: instance.env,
           cd: instance.dir
         ) do
      {_, 0} -> :ok
      {out, status} -> raise "atlas put person #{name} failed (#{status}): #{out}"
    end
  end

  @doc """
  Rewrite the instance's settings with Flow's `lease_ttl` (D6, test only); it applies from the
  core's next start. S5 runs on the shortest one that keeps a lease renewed between two polls
  (`short_lease_ttl/0`), so it waits the product's timers for seconds, not minutes.
  """
  def retime!(instance, lease_ttl) do
    settings =
      instance.file
      |> File.read!()
      |> JSON.decode!()
      |> put_in(["flow", "work_source", "lease_ttl"], lease_ttl)

    File.write!(instance.file, JSON.encode!(settings))
    %{instance | settings: settings}
  end

  @doc """
  S5's `lease_ttl`: 15 s. The Runtime takes any 1..86 400 (`puller.ex`, `timing`) and has no
  clock to inject from outside its BEAM; it renews at each poll (`poll_max` 5 s) and fences
  when a lease's age reaches `lease_ttl` at its 5 s check, so 15 s (three polls) is the
  shortest with a margin. The grace (120 s) is not settable (O1).
  """
  def short_lease_ttl, do: 15

  @doc "The `lease_ttl` the rest of the run uses: S3's Flow downtime and S4's Runtime downtime stay under it."
  def lease_ttl, do: 180
end

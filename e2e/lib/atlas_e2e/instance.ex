defmodule AtlasE2E.Instance do
  @moduledoc """
  A private Atlas test instance for one run: a fresh, empty rela dataset on free ports,
  and the core, both started with the `atlas-ops` command through `ATLAS_ENV_FILE`, always
  with `--env test`, with a stand-in GitHub (`AtlasE2E.GitHub`). It never uses the ports or data of `env/test.json` or
  `env/prod.json` (Melle's instances) or the live store. Its Runtime node runs through
  `atlas-runtime node start|stop`, built from this tree into the run's folder.

  The TUIs open web addresses with a stand-in (`"browser"` in the settings) that only
  writes each address to `opened.txt` in the run's folder (`opened/1`), so a run never
  opens a browser.

  rela's binaries are shared between runs (`ATLAS_E2E_RELA_BIN`). `bin/atlas-dev e2e` sets it,
  when unset, to a per-user cache it installs the pinned rela into; a bare `mix atlas.e2e`
  falls back to the test instance's `~/.local/share/atlas/test/bin`, where
  `rela/scripts/start-test.sh` downloads the pinned version when it is missing.
  """

  defstruct [:root, :dir, :file, :settings, :env]

  @root Path.expand("../../..", __DIR__)

  def root, do: @root

  def start do
    dir = Path.join(System.tmp_dir!(), "atlas-e2e-#{System.os_time(:millisecond)}")
    File.mkdir_p!(dir)
    [rela_port, control_port, link_port] = free_ports(3)

    bin =
      System.get_env("ATLAS_E2E_RELA_BIN") ||
        Path.join(System.user_home!(), ".local/share/atlas/test/bin")

    browser = Path.join(dir, "browser")
    opened = Path.join(dir, "opened.txt")
    File.write!(browser, "#!/bin/sh\nprintf '%s\\n' \"$1\" >> '#{opened}'\n")
    File.chmod!(browser, 0o755)

    settings = %{
      "env" => "test",
      "bus_link" => %{"port" => link_port},
      "tui_user" => "melle",
      "browser" => browser,
      "control" => %{"host" => "127.0.0.1", "port" => control_port},
      "rela" => %{
        "url" => "http://127.0.0.1:#{rela_port}/api/v1",
        "port" => rela_port,
        "data" => Path.join(dir, "rela"),
        "bin" => bin,
        "extra" => "rela/atlas.json"
      },
      "facts" => %{"data" => Path.join(dir, "beam")},
      "reconcile_seconds" => 5,
      # GitHub is a stand-in (UC-Atlas-26), read every 2 seconds rather than 5 minutes.
      "connectors" => %{
        "github" => %{
          "api" => AtlasE2E.GitHub.start(),
          "token_command" => ["echo", AtlasE2E.GitHub.token()],
          "every_seconds" => 2
        }
      },
      # The planning agent is a scripted stand-in, so no model is needed (UC-Atlas-16).
      "agent" => %{
        "planner" => ["elixir", Path.join(@root, "e2e/fixtures/planner.exs")],
        "name" => "the e2e stand-in",
        # Long enough to see each step go, and to stop a run between two (UC-Atlas-18).
        "step_pause_ms" => 2_000
      },
      # Runtime (IS-Atlas-15) runs two stand-in agents, runner (UC-Atlas-07) and tester (its
      # failure actions, IS-Atlas-23, with a maximum to see an idle turn end), whose mode a
      # scenario sets in its file in stub_dir; no real agent runs. Only facts they own get
      # turns, so no other scenario meets them. Short numbers, to see them go.
      "runtime" => %{
        "machine" => "e2e",
        "agents" => %{
          "runner" => %{"port" => "stub"},
          "breaker" => %{"port" => "stub"},
          "tester" => %{"port" => "stub", "max_seconds" => 15}
        },
        "stub_dir" => Path.join(dir, "stub"),
        "silence_seconds" => 3,
        "leave_grace_seconds" => 4,
        "lease_seconds" => 1,
        "round_seconds" => 1
      },
      # A lone escape waits this long for the rest of its key (30 ms for a person): on a
      # loaded machine a key's bytes can reach the TUI further apart, and `\e[B` must not
      # turn into Escape and the text "[B".
      "escape_ms" => 250
    }

    File.mkdir_p!(Path.join(dir, "stub"))
    file = Path.join(dir, "test.json")
    runtime_file = Path.join(dir, "runtime.json")

    runtime_settings = %{
      "env" => "test",
      "runtime" => settings["runtime"],
      "bus_link" => %{
        "mode" => "client",
        "host" => "127.0.0.1",
        "port" => link_port,
        "machine" => "e2e"
      }
    }

    File.write!(runtime_file, JSON.encode!(runtime_settings))
    File.write!(file, JSON.encode!(Map.delete(settings, "runtime")))

    instance = %__MODULE__{
      root: @root,
      dir: dir,
      file: file,
      settings: settings,
      # The core runs as `atlas-ops up` runs it, in Mix's dev environment.
      env: [
        {"ATLAS_ENV_FILE", file},
        {"ATLAS_NO_UPDATE", "1"},
        {"MIX_ENV", "dev"},
        {"ATLAS_RUNTIME_HOME", Path.join(dir, "runtime-node")},
        {"ATLAS_RUNTIME_FILE", runtime_file},
        {"ATLAS_BUS_LINK_TOKEN", JSON.encode!(%{"e2e" => "e2e-private-link"})}
      ]
    }

    # `atlas-ops restart` starts rela when it does not answer, then the core, and waits for it.
    :ok = ops!(instance, ["restart", "--env", "test"])
    :ok = build_runtime_cli(instance)
    :ok = start_runtime(instance)
    instance
  end

  # The Runtime node runs through `atlas-runtime node`, built from this tree into the run's
  # folder, as integration/worker_control.exs builds it: never an installed binary.
  defp runtime_cli(instance), do: Path.join(instance.dir, "atlas-runtime")

  defp build_runtime_cli(instance) do
    case System.cmd("go", ["-C", "tools/runtime", "build", "-o", runtime_cli(instance), "."],
           cd: @root,
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {out, status} -> raise "building atlas-runtime failed (#{status}):\n#{out}"
    end
  end

  @doc "Stop the core, as `atlas-ops stop` does."
  def stop_core(instance), do: ops!(instance, ["stop", "--env", "test"])

  @doc "Start the core again, as `atlas-ops restart` does."
  def start_core(instance), do: ops!(instance, ["restart", "--env", "test"])

  def start_runtime(instance) do
    runtime = %{
      instance
      | env:
          List.keystore(
            instance.env,
            "ATLAS_BUS_LINK_TOKEN",
            0,
            {"ATLAS_BUS_LINK_TOKEN", "e2e-private-link"}
          )
    }

    node!(runtime, "start")
  end

  def stop_runtime(instance), do: node!(instance, "stop")

  def stop(instance) do
    stop_runtime(instance)
    run(instance, "bin/atlas-ops", ["stop", "--rela", "--env", "test"])
    :ok
  end

  @doc "The files worth keeping when a run fails: the core's log and rela's."
  def logs(instance),
    do: Path.wildcard(Path.join(instance.dir, "**/*.log"))

  @doc "The web addresses the TUIs opened, through the stand-in browser, in order."
  def opened(instance) do
    case File.read(Path.join(instance.dir, "opened.txt")) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, _} -> []
    end
  end

  @doc "GET from rela itself, to check what it stored."
  def rela_get(instance, path) do
    url = String.to_charlist(instance.settings["rela"]["url"] <> path)

    case :httpc.request(:get, {url, []}, [timeout: 5_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, body}} -> JSON.decode!(body)
      other -> raise "rela did not answer #{path}: #{inspect(other)}"
    end
  end

  @doc """
  Remove ended turn fixtures from this run's own disposable backend. Control has no
  authority to delete fenced system facts. This is fixture-owner teardown, not a
  Runtime impersonation or a production API. Stop the private Runtime before touching
  its history; restart only after successful teardown. Existing run directories remain.
  """
  def cleanup_turn_fixtures(instance, keys) do
    private_fixture!(instance)
    :ok = stop_runtime(instance)

    for key <- keys do
      path = "/turns/" <> URI.encode(key, &URI.char_unreserved?/1)
      fact = rela_get(instance, path)

      unless fact["properties"]["state"] == "ended" and
               fact["properties"]["machine"] == "e2e" do
        raise "refusing fixture teardown of an active or foreign turn: #{key}"
      end

      url = String.to_charlist(instance.settings["rela"]["url"] <> path)

      case :httpc.request(:delete, {url, []}, [timeout: 5_000], body_format: :binary) do
        {:ok, {{_, status, _}, _, _}} when status in [200, 204] -> :ok
        other -> raise "private fixture teardown failed for #{key}: #{inspect(other)}"
      end
    end

    start_runtime(instance)
  end

  defp private_fixture!(instance) do
    settings = instance.settings || %{}
    rela = settings["rela"] || %{}
    uri = URI.parse(rela["url"] || "")

    private =
      is_binary(instance.dir) and
        Path.dirname(Path.expand(instance.dir)) == Path.expand(System.tmp_dir!()) and
        String.starts_with?(Path.basename(instance.dir), "atlas-e2e-")

    unless private and settings["env"] == "test" and
             rela["data"] == Path.join(instance.dir, "rela") and
             uri.scheme == "http" and uri.host == "127.0.0.1" and uri.port == rela["port"] do
      raise ArgumentError, "fixture teardown requires this run's private test backend"
    end
  end

  defp ops!(instance, args), do: run!(instance, "bin/atlas-ops", args)

  defp node!(instance, op),
    do: run!(instance, runtime_cli(instance), ["node", op, "--env", "test", "--checkout", @root])

  defp run!(instance, command, args) do
    case run(instance, command, args) do
      {_, 0} ->
        :ok

      {out, status} ->
        raise "#{Path.basename(command)} #{Enum.join(args, " ")} failed (#{status}):\n#{out}"
    end
  end

  defp run(instance, command, args) do
    System.cmd(Path.expand(command, @root), args,
      env: instance.env,
      stderr_to_stdout: true
    )
  end

  defp free_ports(n) do
    sockets =
      for _ <- 1..n do
        {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, reuseaddr: true)
        socket
      end

    ports = Enum.map(sockets, fn s -> elem(:inet.port(s), 1) end)
    Enum.each(sockets, &:gen_tcp.close/1)
    ports
  end
end

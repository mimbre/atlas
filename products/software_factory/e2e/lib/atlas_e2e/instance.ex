defmodule AtlasE2E.Instance do
  @moduledoc """
  A private Atlas test instance for one run: a fresh, empty rela dataset on free ports,
  and the core, both started with the `atlas-ops` command through `ATLAS_ENV_FILE`, always
  with `--env test`, with a stand-in GitHub (`AtlasE2E.GitHub`). It never uses the ports or data of `products/software_factory/environments/test.json` or
  `products/software_factory/environments/prod.json` (Melle's instances) or the live store.

  The TUIs open web addresses with a stand-in (`"browser"` in the settings) that only
  writes each address to `opened.txt` in the run's folder (`opened/1`), so a run never
  opens a browser.

  rela's binaries are shared between runs; `rela_bin/1` finds them. `bin/atlas-dev e2e`
  installs the pinned rela into a per-user cache when none is found; a bare `mix atlas.e2e`
  falls back to the test instance's `~/.local/share/atlas/test/bin`, where
  `platform/atlas_facts/rela/scripts/start-test.sh` downloads the pinned version when it is missing.
  """

  defstruct [:root, :dir, :file, :settings, :env]

  @root Path.expand("../../../../..", __DIR__)

  def root, do: @root

  @doc """
  The folder with rela's binaries, the first of: `ATLAS_E2E_RELA_BIN`, `ATLAS_RELA_BIN`,
  and the `rela-bin` folder beside the checkout when it holds `rela-server-headless-sqlite` (a worker's
  folder, where the pinned rela is installed for it); else `default`. `bin/atlas-dev`,
  `platform/atlas_facts/rela/tests` and the umbrella's rela tests look in the same order.
  """
  def rela_bin(default \\ nil) do
    beside = Path.expand("../rela-bin", @root)

    Enum.find(
      [System.get_env("ATLAS_E2E_RELA_BIN"), System.get_env("ATLAS_RELA_BIN")],
      &(&1 not in [nil, ""])
    ) ||
      if(File.exists?(Path.join(beside, "rela-server-headless-sqlite")),
        do: beside,
        else: default
      )
  end

  @doc "`rela_bin/1`, else the test instance's own folder."
  def rela_bin!, do: rela_bin(Path.join(System.user_home!(), ".local/share/atlas/test/bin"))

  def start do
    instance = prepare()
    # `atlas-ops restart` starts rela when it does not answer, then the core, and waits for it.
    :ok = ops!(instance, ["restart", "--env", "test"])
    instance
  end

  @doc """
  The run's folder, free ports and settings files, and the environment the core, the TUIs
  and `atlas` run with; nothing started but the stand-in GitHub. `start/0` starts rela and
  the core on it; a proof that runs inside the core's node starts them itself.
  """
  def prepare, do: prepare(%{}, [])

  @doc """
  `prepare/0` with `extra` deep-merged into the settings (a map merges into a map, any other
  value replaces), in `dir:` when given (the pull-e2e's `<run>/inst`, so nothing of the run
  lies outside its folder) instead of a new folder under the system temp directory.
  """
  def prepare(extra, opts) when is_map(extra) and is_list(opts) do
    dir = opts[:dir] || Path.join(System.tmp_dir!(), "atlas-e2e-#{System.os_time(:millisecond)}")
    File.mkdir_p!(dir)
    [rela_port, control_port] = free_ports(2)

    bin = rela_bin!()

    browser = Path.join(dir, "browser")
    opened = Path.join(dir, "opened.txt")
    File.write!(browser, "#!/bin/sh\nprintf '%s\\n' \"$1\" >> '#{opened}'\n")
    File.chmod!(browser, 0o755)

    settings = %{
      "env" => "test",
      "tui_user" => "melle",
      # Who decides what a person decides (the model names the role, never a person): the
      # TUIs' user, as in test and prod.
      "actors" => %{"decider" => "melle"},
      "browser" => browser,
      "control" => %{"host" => "127.0.0.1", "port" => control_port},
      "rela" => %{
        "url" => "http://127.0.0.1:#{rela_port}/api/v1",
        "port" => rela_port,
        "data" => Path.join(dir, "rela"),
        "bin" => bin
      },
      "facts" => %{"data" => Path.join(dir, "beam")},
      # Code's receiver of the integrate effect, as on prod; it reaches GitHub (the stand-in
      # below) with the connector's settings, which refuses every write.
      "code" => code(dir),
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
        "planner" => [
          "elixir",
          Path.join(@root, "products/software_factory/e2e/fixtures/planner.exs")
        ],
        "name" => "the e2e stand-in",
        # Long enough to see each step go, and to stop a run between two (UC-Atlas-18).
        "step_pause_ms" => 2_000
      },
      # A lone escape waits this long for the rest of its key (30 ms for a person): on a
      # loaded machine a key's bytes can reach the TUI further apart, and `\e[B` must not
      # turn into Escape and the text "[B".
      "escape_ms" => 250
    }

    settings = deep_merge(settings, extra)
    file = Path.join(dir, "test.json")
    File.write!(file, JSON.encode!(settings))

    %__MODULE__{
      root: @root,
      dir: dir,
      file: file,
      settings: settings,
      # The core runs as `atlas-ops up` runs it, in Mix's dev environment.
      env: [
        {"ATLAS_ENV_FILE", file},
        {"ATLAS_NO_UPDATE", "1"},
        {"MIX_ENV", "dev"}
      ]
    }
  end

  @doc "Compile the core and the clients first, so starting the core or a TUI never waits for a compile."
  def compile do
    for dir <- ["products/software_factory", "platform/clients/tui", "platform/clients/agent"] do
      {out, status} =
        System.cmd("mix", ["compile"],
          cd: Path.join(@root, dir),
          env: [{"MIX_ENV", "dev"}],
          stderr_to_stdout: true
        )

      if status != 0, do: raise("#{dir} does not compile:\n#{out}")
    end

    :ok
  end

  @doc "Stop the core, as `atlas-ops stop` does."
  def stop_core(instance), do: ops!(instance, ["stop", "--env", "test"])

  @doc "Start the core again, as `atlas-ops restart` does."
  def start_core(instance), do: ops!(instance, ["restart", "--env", "test"])

  def stop(instance) do
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

  defp ops!(instance, args), do: run!(instance, "bin/atlas-ops", args)

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

  @doc """
  The instance's `code` settings: its journal under `dir` and the repositories it may
  integrate, the one prod integrates (checked by `AtlasE2E.RepositoryAllowlistTest`).
  """
  def code(dir), do: %{"data" => Path.join(dir, "code"), "repositories" => ["mimbre/atlas"]}

  @doc false
  def deep_merge(%{} = left, %{} = right),
    do: Map.merge(left, right, fn _key, l, r -> deep_merge(l, r) end)

  def deep_merge(_left, right), do: right

  @doc "`n` free loopback ports (each was bound once and released)."
  def free_ports(n) do
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

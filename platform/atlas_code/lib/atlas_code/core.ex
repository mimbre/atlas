defmodule AtlasCode.Core do
  @moduledoc """
  The Code service in the core: one registered instance (`AtlasCode.start/2` with
  `register: true`) on a home the core's settings name, so that callers in the core's BEAM
  (Flow's work source, through `AtlasCode.Boundary`) reach Code. `AtlasCode.Application`
  starts it only when the core configures it (`config :atlas_code, :service`, from the
  `code.home` and `code.sources` of the settings); otherwise there is no such child and no
  file is written.

  `settings`: `%{"home" => path, "repositories" => %{name => remote}}`, a remote as in the
  home's `config.json` (`AtlasCode`), e.g. `{"url": …, "credentials": "none"}`.

  At start it prepares the home: the directory (owner-only), `config.json` from the settings
  (`port: 0`, so the loopback listener takes any free port; callers in the BEAM need none),
  and `runtime.token` once, when absent: 32 random bytes, hex, in a file that is 0600 before
  it holds them. It comes from no secret and nothing outside this BEAM uses it.

  It owns the server's lifetime. A start that fails, and a server that goes down (its OS
  lock goes with it, so the next start recovers the home), are retried here, logged, while
  Code is unavailable to the core's callers; a failing Code never stops the core. When this
  process stops, it stops the server, which releases the home.
  """
  use GenServer
  require Logger

  @retry_ms 30_000

  def start_link(settings), do: GenServer.start_link(__MODULE__, settings, name: __MODULE__)

  @impl true
  def init(%{"home" => home, "repositories" => repositories} = settings)
      when is_binary(home) and is_map(repositories) do
    Process.flag(:trap_exit, true)

    state = %{
      home: Path.expand(home),
      repositories: repositories,
      ps: Map.get(settings, "ps", "ps"),
      retry_ms: Map.get(settings, "retry_ms", @retry_ms),
      server: nil,
      monitor: nil
    }

    {:ok, state, {:continue, :serve}}
  end

  @impl true
  def handle_continue(:serve, state), do: {:noreply, serve(state)}

  # A Code that cannot start (or whose server went down) is retried later, and meanwhile
  # Code is unavailable to the core's callers: it never takes the core down with it.
  defp serve(%{home: home, repositories: repositories} = state) do
    prepare!(home, repositories)
    {:ok, pid, _port} = AtlasCode.start(home, register: true, ps: state.ps)
    Logger.info("Code serves #{home} in the core (#{map_size(repositories)} repositories)")
    %{state | server: pid, monitor: Process.monitor(pid)}
  rescue
    error ->
      Logger.error(
        "Code in the core cannot start on #{home}; retrying in #{state.retry_ms} ms: #{Exception.message(error)}"
      )

      Process.send_after(self(), :serve, state.retry_ms)
      state
  end

  @doc false
  # The home's directory, config.json and runtime.token (see the moduledoc).
  def prepare!(home, repositories) do
    File.mkdir_p!(home)
    File.chmod!(home, 0o700)

    AtlasCode.write_atomic(
      Path.join(home, "config.json"),
      JSON.encode!(%{"port" => 0, "repositories" => repositories})
    )

    token!(Path.join(home, "runtime.token"))
  end

  # Created exclusively, so an existing token (and its mode, which start checks) is kept.
  defp token!(path) do
    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, file} ->
        try do
          File.chmod!(path, 0o600)
          token = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
          :ok = IO.binwrite(file, token <> "\n")
        after
          File.close(file)
        end

      {:error, :eexist} ->
        :ok
    end
  end

  @impl true
  def handle_info(:serve, state), do: {:noreply, serve(state)}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{monitor: ref} = state) do
    Logger.error("Code in the core went down (#{inspect(reason)}); restarting it")
    {:noreply, serve(%{state | server: nil, monitor: nil})}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{server: nil}), do: :ok

  def terminate(_reason, %{server: pid}) do
    case AtlasCode.stop(pid) do
      :ok -> :ok
      error -> Logger.warning("Code in the core did not stop cleanly: #{inspect(error)}")
    end
  end
end

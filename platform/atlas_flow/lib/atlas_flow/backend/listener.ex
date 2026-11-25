defmodule AtlasFlow.Backend.Listener do
  @moduledoc """
  Flow's private listener for the work source (plan m3 §3.6; decision 2026-11-17 §3
  protections 1–3, decision 3): Bandit on `127.0.0.1:<port>`, plain HTTP. TLS ends at the
  tailnet edge in front of it, as Control's ingress does; Flow speaks no TLS itself. Under
  pull the Runtime exposes nothing: this is the source's listener, on the core.

  - **Bind.** Loopback only: `127.0.0.1`. Any other address refuses to start
    (`{:error, :not_loopback}`). Without a port there is no listener at all
    (`AtlasFlow.Application` starts none).
  - **Credentials.** `Authorization: Bearer <token>` →
    `AtlasFlow.WorkSource.Credentials.lookup/2` (the sha256 of the token, compared in
    constant time) → the client `{runtime_id, holder}`, which goes to the router as
    `conn.assigns.client`. A missing, malformed or unknown token is answered
    `401 unauthenticated` here, **before the router runs**. The holder only ever comes
    from the credential. The credentials are read when the listener starts (the
    environment variable `config :atlas_flow, :work_source, credentials_env:` names);
    unset or invalid, the listener refuses to start (`{:error, :credentials}`). A token
    the secret does not know is then looked up among the credentials registered in Facts
    (`AtlasFlow.WorkSource.Registered`, IS-Atlas-116: a Runtime installed through
    Control), when that table runs; the secret's win for a token both know.
  - **Limits.** `AtlasFlow.Backend.Listener.Limits`, one per listener, keeps the request
    rate per credential and the blob streams per Runtime (see `AtlasFlow.Backend.Router`).
  - **Bodies.** Read only through `AtlasBodyLimit` (by the router), which keeps each
    route's cap whatever the transfer encoding; any answer that leaves a body unread,
    the 401 included, says `connection: close`.

  Options of `start_link/1`: `port` (required; 0 takes a free one), `ip` (default
  `{127, 0, 0, 1}`), `name` (default this module), `credentials` (a credentials map; by
  default `Credentials.load/0`), `registered` (the `AtlasFlow.WorkSource.Registered`
  table, default that module's; `nil`: none), `router` (options of `AtlasFlow.Backend.Router.init/1`)
  and `limits` (options of the limits server).
  """
  @behaviour Plug

  alias AtlasFlow.Backend.Router
  alias AtlasFlow.Backend.Listener.Limits
  alias AtlasFlow.WorkSource.{Credentials, Registered}

  @loopback {127, 0, 0, 1}

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc "Starts the limits server and Bandit under one supervisor, or refuses to."
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    with {:ok, ip} <- loopback(Keyword.get(opts, :ip, @loopback)),
         {:ok, port} <- port(Keyword.get(opts, :port)),
         {:ok, credentials} <- credentials(opts) do
      limits = Module.concat(name, Limits)
      router = Router.init(Keyword.put(Keyword.get(opts, :router, []), :limits, limits))

      children = [
        {Limits, Keyword.put(Keyword.get(opts, :limits, []), :name, limits)},
        {Bandit,
         plug:
           {__MODULE__,
            %{
              credentials: credentials,
              registered: Keyword.get(opts, :registered, Registered),
              router: router
            }},
         scheme: :http,
         ip: ip,
         port: port,
         startup_log: false}
      ]

      Supervisor.start_link(children, strategy: :rest_for_one, name: name)
    end
  end

  @doc "The address the listener `name` is bound to: `{:ok, {ip, port}}`."
  def address(name \\ __MODULE__) do
    name
    |> Supervisor.which_children()
    |> Enum.find_value(:error, fn
      {{Bandit, _}, pid, _, _} when is_pid(pid) -> ThousandIsland.listener_info(pid)
      {Bandit, pid, _, _} when is_pid(pid) -> ThousandIsland.listener_info(pid)
      _ -> nil
    end)
  end

  @doc "Whether `ip` is the one address the listener binds: 127.0.0.1."
  def loopback(ip) when is_binary(ip) do
    case :inet.parse_strict_address(String.to_charlist(ip)) do
      {:ok, parsed} -> loopback(parsed)
      _ -> {:error, :not_loopback}
    end
  end

  def loopback(@loopback), do: {:ok, @loopback}
  def loopback(_ip), do: {:error, :not_loopback}

  defp port(port) when is_integer(port) and port in 0..65_535, do: {:ok, port}
  defp port(_port), do: {:error, :port}

  defp credentials(opts) do
    case Keyword.fetch(opts, :credentials) do
      {:ok, %{} = credentials} -> {:ok, credentials}
      :error -> with {:error, _} <- Credentials.load(), do: {:error, :credentials}
      _ -> {:error, :credentials}
    end
  end

  ## Plug: the credential, before the router

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, %{credentials: credentials, router: router} = state) do
    # A 401 leaves the body unread: the answer closes the connection, so Bandit never drains
    # (reads whole) a body this listener did not take.
    conn = AtlasBodyLimit.guard(conn)

    with {:ok, token} <- bearer(conn),
         {:ok, client} <- lookup(credentials, state[:registered], token) do
      conn
      |> Plug.Conn.assign(:client, client)
      |> Router.call(router)
    else
      _ -> Router.error(conn, :unauthenticated)
    end
  end

  defp lookup(credentials, registered, token) do
    case Credentials.lookup(credentials, token) do
      :unauthenticated when is_atom(registered) and registered != nil ->
        Credentials.lookup(Registered.credentials(registered), token)

      found ->
        found
    end
  end

  defp bearer(conn) do
    with [value] <- Plug.Conn.get_req_header(conn, "authorization"),
         [scheme, token] <- String.split(value, " ", parts: 2),
         "bearer" <- String.downcase(scheme),
         token when token != "" <- String.trim(token) do
      {:ok, token}
    else
      _ -> :none
    end
  end
end

defmodule AtlasFlow.Backend.Listener.Limits do
  @moduledoc """
  The listener's limits (protection 5; plan m3 §3.6, Q9), one server per listener:

  - `admit/2`: how many ms a request of this credential waits before it is served, so
    that a credential gets at most `rate` requests a second (10) with bursts of `burst`
    (10) (a generic cell rate). Never a refusal: `routes.json` declares no 429.
  - `stream/3`: runs a blob stream once one of the Runtime's `streams` (4) is free;
    a fifth waits until one ends. A stream's holder that dies frees its slot.

  Options: `name`, `rate`, `burst`, `streams` and `now` (milliseconds, monotonic by
  default).
  """
  use GenServer

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "The ms a request of `key` waits before it is served (0 for none)."
  def admit(server, key), do: GenServer.call(server, {:admit, key})

  @doc "Runs `fun` while holding one of `key`'s blob streams; waits for one first."
  def stream(server, key, fun) do
    ref = GenServer.call(server, {:acquire, key}, :infinity)

    try do
      fun.()
    after
      GenServer.call(server, {:release, ref})
    end
  end

  @doc "The streams held and waiting per key."
  def status(server), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    rate = Keyword.get(opts, :rate, 10)

    {:ok,
     %{
       interval: 1000 / rate,
       burst: Keyword.get(opts, :burst, 10),
       streams: Keyword.get(opts, :streams, 4),
       now: Keyword.get(opts, :now, fn -> System.monotonic_time(:millisecond) end),
       tat: %{},
       held: %{},
       waiting: %{}
     }}
  end

  @impl true
  def handle_call({:admit, key}, _from, state) do
    now = state.now.()
    tat = max(Map.get(state.tat, key, now), now)
    wait = max(0, ceil(tat - state.interval * (state.burst - 1) - now))
    {:reply, wait, put_in(state.tat[key], tat + state.interval)}
  end

  def handle_call({:acquire, key}, {pid, _} = from, state) do
    if held(state, key) < state.streams do
      {ref, state} = hold(state, key, pid)
      {:reply, ref, state}
    else
      queue = Map.get(state.waiting, key, :queue.new())
      {:noreply, put_in(state.waiting[key], :queue.in(from, queue))}
    end
  end

  def handle_call({:release, ref}, _from, state), do: {:reply, :ok, free(state, ref)}

  def handle_call(:status, _from, state) do
    keys = Enum.uniq(Map.values(state.held) ++ Map.keys(state.waiting))

    {:reply,
     Map.new(keys, fn key ->
       {key,
        %{held: held(state, key), waiting: :queue.len(Map.get(state.waiting, key, :queue.new()))}}
     end), state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state), do: {:noreply, free(state, ref)}
  def handle_info(_message, state), do: {:noreply, state}

  defp held(state, key), do: Enum.count(state.held, fn {_ref, k} -> k == key end)

  defp hold(state, key, pid) do
    ref = Process.monitor(pid)
    {ref, put_in(state.held[ref], key)}
  end

  defp free(state, ref) do
    case Map.pop(state.held, ref) do
      {nil, _} ->
        state

      {key, held} ->
        Process.demonitor(ref, [:flush])
        next(%{state | held: held}, key)
    end
  end

  # The next waiter of `key` that is still alive gets the slot.
  defp next(state, key) do
    queue = Map.get(state.waiting, key, :queue.new())

    case :queue.out(queue) do
      {:empty, _} ->
        %{state | waiting: Map.delete(state.waiting, key)}

      {{:value, {pid, _} = from}, rest} ->
        state = put_in(state.waiting[key], rest)

        if Process.alive?(pid) do
          {ref, state} = hold(state, key, pid)
          GenServer.reply(from, ref)
          state
        else
          next(state, key)
        end
    end
  end
end

defmodule AtlasRuntime.ListenerCheck do
  @moduledoc """
  The Runtime service's ready-time check (`host/service.exs`): an agent machine runs no
  network listener (the pull design), so the service's VM must own no IP listen socket when
  it reports ready. Whatever brought one in, a dependency or the toolchain (Mix's PubSub
  under `mix run`), the start fails instead.

  Every way the VM opens a socket is counted, without Mix and without external tools:

  - `gen_tcp`/`gen_sctp`'s inet ports (`Port.list/0`, complete by construction).
  - Every `:socket` socket of domain `:inet` or `:inet6`, **whatever its protocol or type**
    (`:socket.open(:inet, :stream)` reports protocol `:ip`, not `:tcp`), and `gen_tcp`'s
    `inet_backend: :socket`. The socket registry is enumerated with a domain filter, never
    `:socket.which_sockets(:tcp)`.
  - A `:socket` opened outside the registry (`use_registry: false`, or the registry turned
    off) cannot be inspected, so its existence fails the start: the NIF's own count of open
    sockets must equal the registry's live ones.

  Unix-domain sockets (`runtime.sock`, `backend.sock`) are no network listeners and are not
  counted; nor are connected sockets, such as the Bus link's own connection out to a Server.
  """

  @type refusal ::
          %{reason: :ip_listener, ports: [:inet.port_number()]}
          | %{reason: :unregistered_socket, sockets: pos_integer()}

  @doc """
  The local port numbers of the IP listen sockets this VM owns, of either backend, sorted.
  """
  @spec ip_listeners() :: [:inet.port_number()]
  def ip_listeners do
    Enum.sort(inet_listeners() ++ socket_listeners())
  end

  @doc """
  How many open `:socket` sockets the registry does not hold (`use_registry: false`, or the
  registry turned off), so none of them can be looked at. 0 when the check sees them all.
  """
  @spec unregistered_sockets() :: non_neg_integer()
  def unregistered_sockets, do: unregistered_sockets(3)

  @doc """
  `:ok` when this VM owns no IP listen socket and no `:socket` the check cannot see.
  Otherwise the refusal: its reason with the listeners' local port numbers (or the number
  of unseen sockets), and nothing that was received on them.
  """
  @spec verify() :: :ok | {:error, refusal()}
  def verify do
    with {:ports, []} <- {:ports, ip_listeners()},
         {:unseen, 0} <- {:unseen, unregistered_sockets()} do
      :ok
    else
      {:ports, ports} -> {:error, %{reason: :ip_listener, ports: ports}}
      {:unseen, unseen} -> {:error, %{reason: :unregistered_socket, sockets: unseen}}
    end
  end

  # A port or socket that closes while it is looked at is no listener.
  defp inet_listeners do
    for port <- Port.list(),
        Port.info(port, :name) in [{:name, ~c"tcp_inet"}, {:name, ~c"sctp_inet"}],
        :listen in safely(fn -> :inet.info(port)[:states] end, []),
        {:ok, {address, number}} when is_tuple(address) <-
          [safely(fn -> :inet.sockname(port) end, :closed)],
        do: number
  end

  defp socket_listeners do
    for socket <- :socket.which_sockets(fn %{domain: domain} -> domain in [:inet, :inet6] end),
        %{rstates: states} <- [safely(fn -> :socket.info(socket) end, %{})],
        :listening in states,
        {:ok, %{port: number}} <- [safely(fn -> :socket.sockname(socket) end, :closed)],
        do: number
  end

  # The registry learns of a socket by a message from the NIF, so an open or close in
  # flight can briefly differ: looked at again before it counts.
  defp unregistered_sockets(tries) do
    case max(open_sockets() - length(registered_sockets()), 0) do
      unseen when unseen > 0 and tries > 1 ->
        Process.sleep(20)
        unregistered_sockets(tries - 1)

      unseen ->
        unseen
    end
  end

  defp open_sockets, do: :socket.info().counters.num_sockets

  defp registered_sockets do
    for socket <- :socket.which_sockets(fn _ -> true end),
        %{rstates: states} <- [safely(fn -> :socket.info(socket) end, %{})],
        :closed not in states,
        do: socket
  end

  defp safely(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    _, _ -> default
  end
end

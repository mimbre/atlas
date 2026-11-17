defmodule AtlasRuntime.ListenerCheck do
  @moduledoc """
  The Runtime service's ready-time check (`host/service.exs`): an agent machine runs no
  network listener (the pull design), so the service's VM must own no TCP listen socket
  when it reports ready. Whatever brought one in, a dependency or the toolchain (Mix's
  PubSub under `mix run`), the start fails instead.

  Both socket backends are counted: `gen_tcp`'s inet ports and `:socket` (also
  `gen_tcp`'s `inet_backend: :socket`). Unix-domain sockets (`runtime.sock`,
  `backend.sock`) are no network listeners and are not counted; nor are connected TCP
  sockets, such as the Bus link's own connection out to a Server.
  """

  @doc """
  The local port numbers of the TCP listen sockets this VM owns, sorted.
  """
  @spec tcp_listeners() :: [:inet.port_number()]
  def tcp_listeners do
    Enum.sort(inet_listeners() ++ socket_listeners())
  end

  @doc """
  `:ok` when this VM owns no TCP listen socket. Otherwise the refusal: its reason and the
  sockets' local port numbers, and nothing that was received on them.
  """
  @spec verify() :: :ok | {:error, %{reason: :tcp_listener, ports: [:inet.port_number()]}}
  def verify do
    case tcp_listeners() do
      [] -> :ok
      ports -> {:error, %{reason: :tcp_listener, ports: ports}}
    end
  end

  # A port that closes while it is looked at is no listener.
  defp inet_listeners do
    for port <- Port.list(),
        Port.info(port, :name) == {:name, ~c"tcp_inet"},
        :listen in safely(fn -> :inet.info(port)[:states] end, []),
        {:ok, {address, number}} when is_tuple(address) <-
          [safely(fn -> :inet.sockname(port) end, :closed)],
        do: number
  end

  defp socket_listeners do
    for socket <- :socket.which_sockets(:tcp),
        %{domain: domain, rstates: states} <- [safely(fn -> :socket.info(socket) end, %{})],
        domain in [:inet, :inet6] and :listening in states,
        {:ok, %{port: number}} <- [safely(fn -> :socket.sockname(socket) end, :closed)],
        do: number
  end

  defp safely(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    _, _ -> default
  end
end

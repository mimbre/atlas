defmodule AtlasTransport do
  @moduledoc "Authenticated remote sockets; plaintext is confined to literal loopback."

  def host(settings) do
    case settings["host_env"] do
      nil -> settings["host"]
      name -> System.get_env(name)
    end
  end

  def connect(settings, options, timeout) do
    host = host(settings)

    cond do
      not is_binary(host) or host == "" ->
        {:error, :missing_destination}

      is_map(settings["tls"]) and full_name?(host) ->
        tls = settings["tls"]

        trust =
          case tls["cacertfile"] do
            nil -> [cacerts: :public_key.cacerts_get()]
            file -> [cacertfile: String.to_charlist(file)]
          end

        :ssl.connect(
          String.to_charlist(host),
          settings["port"],
          options ++
            trust ++
            [
              verify: :verify_peer,
              server_name_indication: String.to_charlist(host),
              customize_hostname_check: [
                match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
              ],
              versions: [:"tlsv1.3", :"tlsv1.2"]
            ],
          timeout
        )

      is_nil(settings["tls"]) and loopback?(host) ->
        :gen_tcp.connect(String.to_charlist(host), settings["port"], options, timeout)

      true ->
        {:error, :authenticated_destination_required}
    end
  rescue
    _ -> {:error, :invalid_tls_configuration}
  end

  def listen(settings, options) do
    host = host(settings)

    with true <- is_binary(host),
         {:ok, ip} <- :inet.parse_address(String.to_charlist(host)) do
      options = [if(tuple_size(ip) == 8, do: :inet6, else: :inet), {:ip, ip} | options]

      case settings["tls"] do
        nil ->
          if loopback?(host),
            do: :gen_tcp.listen(settings["port"], options),
            else: {:error, :authenticated_listener_required}

        tls when is_map(tls) ->
          cert = file(tls, "certfile")
          key = file(tls, "keyfile")

          with {:ok, %{type: :regular, mode: mode}} <- File.stat(key),
               true <- Bitwise.band(mode, 0o077) == 0,
               {:ok, _} <- File.read(cert) do
            :ssl.listen(
              settings["port"],
              options ++
                [
                  certfile: String.to_charlist(cert),
                  keyfile: String.to_charlist(key),
                  versions: [:"tlsv1.3", :"tlsv1.2"]
                ]
            )
          else
            _ -> {:error, :invalid_tls_configuration}
          end

        _ ->
          {:error, :invalid_tls_configuration}
      end
    else
      _ -> {:error, :invalid_listener}
    end
  rescue
    _ -> {:error, :invalid_tls_configuration}
  end

  defp file(tls, key) do
    case tls[key <> "_env"] do
      nil -> Map.fetch!(tls, key)
      env -> System.fetch_env!(env)
    end
  end

  defp loopback?(host), do: host in ["127.0.0.1", "::1"]
  defp full_name?(host), do: Regex.match?(~r/\A[a-z0-9-]+(?:\.[a-z0-9-]+)+\.ts\.net\z/, host)

  # Only accepting the transport can report listener failure. TLS failure belongs
  # to the accepted peer, whose owner closes it independently of the listener.
  def accept_peer(socket) when is_port(socket), do: :gen_tcp.accept(socket)
  def accept_peer(socket), do: :ssl.transport_accept(socket)

  def handshake(socket) when is_port(socket), do: {:ok, socket}
  def handshake(socket), do: :ssl.handshake(socket, 5_000)

  def accept(socket) do
    with {:ok, peer} <- accept_peer(socket) do
      case handshake(peer) do
        {:ok, peer} ->
          {:ok, peer}

        error ->
          close(peer)
          {:error, {:handshake, error}}
      end
    end
  end

  @doc "Starts an owned peer under the listener's finite Task.Supervisor limit."
  def start_peer(supervisor, socket, serve) do
    result =
      Task.Supervisor.start_child(
        supervisor,
        fn ->
          receive do
            :socket ->
              try do
                with {:ok, peer} <- handshake(socket), do: serve.(peer)
              after
                close(socket)
              end
          after
            5_000 -> :ok
          end
        end,
        shutdown: :brutal_kill
      )

    with {:ok, pid} <- result,
         :ok <- controlling_process(socket, pid) do
      Kernel.send(pid, :socket)
      :ok
    else
      _ ->
        reject_peer(socket)
        if match?({:ok, _}, result), do: Process.exit(elem(result, 1), :kill)
        :ok
    end
  end

  defp reject_peer(socket) when is_port(socket), do: :gen_tcp.close(socket)

  defp reject_peer(socket) do
    # OTP does not support close on a transport_accept socket before handshake.
    # A zero-deadline handshake cancels it without waiting for any peer bytes;
    # close also covers the case where buffered TLS completed immediately.
    :ssl.handshake(socket, 0)
    :ssl.close(socket, 0)
  end

  def send(socket, data) when is_port(socket), do: :gen_tcp.send(socket, data)
  def send(socket, data), do: :ssl.send(socket, data)
  def recv(socket, size, timeout) when is_port(socket), do: :gen_tcp.recv(socket, size, timeout)
  def recv(socket, size, timeout), do: :ssl.recv(socket, size, timeout)
  def close(socket) when is_port(socket), do: :gen_tcp.close(socket)
  def close(socket), do: :ssl.close(socket)
  def setopts(socket, options) when is_port(socket), do: :inet.setopts(socket, options)
  def setopts(socket, options), do: :ssl.setopts(socket, options)

  def controlling_process(socket, pid) when is_port(socket),
    do: :gen_tcp.controlling_process(socket, pid)

  def controlling_process(socket, pid), do: :ssl.controlling_process(socket, pid)
  def port(socket) when is_port(socket), do: :inet.port(socket)

  def port(socket) do
    with {:ok, {_, port}} <- :ssl.sockname(socket), do: {:ok, port}
  end
end

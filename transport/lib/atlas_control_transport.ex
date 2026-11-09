defmodule AtlasControlTransport do
  @moduledoc "Optional verified TLS for Control clients; absent selection preserves settings TCP."

  def endpoint do
    case System.fetch_env("ATLAS_CONTROL_ENDPOINT") do
      :error -> {:ok, :settings}
      {:ok, value} -> parse(value)
    end
  end

  def parse(value) when is_binary(value) do
    case Regex.run(
           ~r/\Atls:\/\/([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.tail8263c4\.ts\.net):([0-9]{1,5})\z/,
           value
         ) do
      [_, host, port] ->
        port = String.to_integer(port)
        if port in 1..65_535, do: {:ok, {:tls, host, port}}, else: invalid()

      _ ->
        invalid()
    end
  end

  defp invalid, do: {:error, :invalid_control_endpoint}

  def connect(settings, options, timeout) do
    case endpoint() do
      {:ok, :settings} ->
        :gen_tcp.connect(String.to_charlist(settings["host"]), settings["port"], options, timeout)

      {:ok, {:tls, host, port}} ->
        with {:ok, _} <- Application.ensure_all_started(:ssl) do
          :ssl.connect(
            String.to_charlist(host),
            port,
            options ++
              [
                verify: :verify_peer,
                cacerts: :public_key.cacerts_get(),
                server_name_indication: String.to_charlist(host),
                customize_hostname_check: [
                  match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
                ],
                versions: [:"tlsv1.3", :"tlsv1.2"]
              ],
            timeout
          )
        end

      error ->
        error
    end
  rescue
    _ -> {:error, :invalid_control_tls_configuration}
  end

  # TCP ports and SSL socket records keep their native active-mode messages.
  def send(socket, bytes) when is_port(socket), do: :gen_tcp.send(socket, bytes)
  def send(socket, bytes), do: :ssl.send(socket, bytes)
  def recv(socket, size, timeout) when is_port(socket), do: :gen_tcp.recv(socket, size, timeout)
  def recv(socket, size, timeout), do: :ssl.recv(socket, size, timeout)
  def close(socket) when is_port(socket), do: :gen_tcp.close(socket)
  def close(socket), do: :ssl.close(socket)
  def setopts(socket, options) when is_port(socket), do: :inet.setopts(socket, options)
  def setopts(socket, options), do: :ssl.setopts(socket, options)
end

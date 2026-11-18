defmodule AtlasRuntime.TLSFixtures do
  @moduledoc """
  In-test stand-ins for a remote work source's TLS endpoint (M2 plan W3), all on loopback:

  - `pki/1`: a test CA and a server certificate for a host name (a DNS subjectAltName),
    from `:public_key.pkix_test_data/1`;
  - `cacertfile/2`: that CA written as a PEM file, as a test passes it to the transport;
  - `serve_spec/3`: a Bandit HTTPS server on `127.0.0.1:0` answering with a handler
    function, optionally limited to some TLS versions (`versions:`);
  - `http_spec/1`: the same in plain HTTP, to show nothing ever reaches it.
  """

  @doc """
  A fresh test PKI: `%{server: ssl options for the server, cacerts: [DER] a client trusts}`.
  The server's certificate names `host`.
  """
  def pki(host \\ "localhost") do
    san = {:Extension, {2, 5, 29, 17}, false, [{:dNSName, String.to_charlist(host)}]}
    rsa = {:rsa, 2048, 65_537}

    data =
      :public_key.pkix_test_data(%{
        server_chain: %{root: [key: rsa], peer: [key: rsa, extensions: [san]]},
        client_chain: %{root: [key: rsa], peer: [key: rsa]}
      })

    %{
      server: Keyword.take(data[:server_config], [:cert, :key, :cacerts]),
      cacerts: data[:client_config][:cacerts]
    }
  end

  @doc "Writes `pki`'s CA certificates as PEM into `dir`; answers the file's path."
  def cacertfile(pki, dir) do
    path = Path.join(dir, "ca-#{System.unique_integer([:positive])}.pem")
    pem = :public_key.pem_encode(for der <- pki.cacerts, do: {:Certificate, der, :not_encrypted})
    File.write!(path, pem)
    path
  end

  @doc """
  The child spec of an HTTPS server with `handler` (a `Plug.Conn` -> `Plug.Conn` function),
  for `start_supervised/1`. `opts`: `versions:` the TLS versions it speaks (default
  OTP's).
  """
  def serve_spec(handler, pki, opts \\ []) do
    tls = pki.server ++ Keyword.take(opts, [:versions])

    %{
      id: {__MODULE__, :serve, make_ref()},
      start:
        {Bandit, :start_link,
         [
           [
             plug: {__MODULE__.Serve, handler},
             scheme: :https,
             ip: {127, 0, 0, 1},
             port: 0,
             startup_log: false,
             thousand_island_options: [transport_options: tls]
           ]
         ]}
    }
  end

  @doc "The child spec of a plain HTTP server with `handler`."
  def http_spec(handler),
    do: %{
      id: {__MODULE__, :http, make_ref()},
      start:
        {Bandit, :start_link,
         [
           [
             plug: {__MODULE__.Serve, handler},
             scheme: :http,
             ip: {127, 0, 0, 1},
             port: 0,
             startup_log: false
           ]
         ]}
    }

  @doc "The port of a started server."
  def port(pid) do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end

  @doc "A port on `127.0.0.1` that nothing listens on."
  def closed_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defmodule Serve do
    @moduledoc false
    @behaviour Plug

    @impl true
    def init(handler), do: handler

    @impl true
    def call(conn, handler), do: handler.(conn)
  end
end

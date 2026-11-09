defmodule AtlasTransport.TLSPeer do
  @moduledoc false
  @host "core.security-fixture.ts.net"

  def fixtures do
    Application.ensure_all_started(:ssl)
    dir = Path.join(System.tmp_dir!(), "atlas-tls-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    for root <- ["trusted", "unknown"] do
      base = Path.join(dir, root)

      File.write!(base <> ".cnf", """
      [req]
      distinguished_name=dn
      x509_extensions=ca
      prompt=no
      [dn]
      CN=#{root} fixture CA
      [ca]
      basicConstraints=critical,CA:TRUE
      keyUsage=critical,keyCertSign,cRLSign
      subjectKeyIdentifier=hash
      """)

      {_, 0} =
        System.cmd(
          "openssl",
          [
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-days",
            "1",
            "-config",
            base <> ".cnf",
            "-keyout",
            base <> ".key",
            "-out",
            base <> ".crt"
          ],
          stderr_to_stdout: true
        )
    end

    for {kind, host} <- [
          {:valid, @host},
          {:wrong_name, "other.security-fixture.ts.net"},
          {:untrusted, @host}
        ] do
      base = Path.join(dir, Atom.to_string(kind))
      root = Path.join(dir, if(kind == :untrusted, do: "unknown", else: "trusted"))

      File.write!(base <> ".cnf", """
      [server]
      subjectAltName=DNS:#{host}
      basicConstraints=critical,CA:FALSE
      keyUsage=critical,digitalSignature,keyEncipherment
      extendedKeyUsage=serverAuth
      """)

      {_, 0} =
        System.cmd(
          "openssl",
          [
            "req",
            "-new",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-subj",
            "/CN=#{host}",
            "-keyout",
            base <> ".key",
            "-out",
            base <> ".csr"
          ],
          stderr_to_stdout: true
        )

      {_, 0} =
        System.cmd(
          "openssl",
          [
            "x509",
            "-req",
            "-days",
            "1",
            "-in",
            base <> ".csr",
            "-CA",
            root <> ".crt",
            "-CAkey",
            root <> ".key",
            "-CAcreateserial",
            "-extfile",
            base <> ".cnf",
            "-extensions",
            "server",
            "-out",
            base <> ".crt"
          ],
          stderr_to_stdout: true
        )

      File.chmod!(base <> ".key", 0o600)
    end

    previous = :inet_db.res_option(:lookup)
    :inet_db.set_lookup([:file])
    :inet_db.add_host({127, 0, 0, 1}, [String.to_charlist(@host)])

    ExUnit.Callbacks.on_exit(fn ->
      :inet_db.del_host({127, 0, 0, 1})
      :inet_db.set_lookup(previous)
      File.rm_rf!(dir)
    end)

    %{tls_dir: dir}
  end

  def peer(dir, kind, run, serve \\ fn socket -> AtlasTransport.recv(socket, 0, 1_000) end) do
    base = Path.join(dir, Atom.to_string(kind))

    {:ok, listener} =
      AtlasTransport.listen(
        %{
          "host" => "127.0.0.1",
          "port" => 0,
          "tls" => %{"certfile" => base <> ".crt", "keyfile" => base <> ".key"}
        },
        [:binary, packet: :line, active: false, reuseaddr: true]
      )

    {:ok, port} = AtlasTransport.port(listener)

    task =
      Task.async(fn ->
        case AtlasTransport.accept(listener) do
          {:ok, socket} ->
            try do
              serve.(socket)
            after
              AtlasTransport.close(socket)
            end

          {:error, _} ->
            :zero_application_bytes
        end
      end)

    trust = Path.join(dir, "trusted.crt")

    try do
      result = run.(%{"host" => @host, "port" => port, "tls" => %{"cacertfile" => trust}})
      {result, Task.await(task, 7_000)}
    after
      AtlasTransport.close(listener)
    end
  end
end

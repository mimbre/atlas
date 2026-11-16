defmodule AtlasControlTLSFixture do
  @host "fixture.tail8263c4.ts.net"
  def host, do: @host

  def without_tmpdir do
    original = Map.new(["TMPDIR", "TEMP", "TMP"], &{&1, System.get_env(&1)})
    parent = System.get_env("TMPDIR") || System.tmp_dir!()
    fallback = Path.join(parent, "tls-default-#{System.unique_integer([:positive])}")
    File.mkdir_p!(fallback)
    System.delete_env("TMPDIR")
    System.put_env("TEMP", fallback)
    System.put_env("TMP", fallback)

    ExUnit.Callbacks.on_exit(fn ->
      entries = File.ls!(fallback)

      Enum.each(original, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(fallback)

      ExUnit.Assertions.refute(
        Enum.any?(entries, &String.starts_with?(&1, "control-tls-")),
        "private TLS fixture left files: #{inspect(entries)}"
      )

      ExUnit.Assertions.refute(File.exists?(fallback), "private fallback directory remains")
    end)

    fallback
  end

  def setup do
    dir =
      Path.join(
        System.get_env("TMPDIR") || System.tmp_dir!(),
        "control-tls-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "ext"),
      "subjectAltName=DNS:#{@host}\nextendedKeyUsage=serverAuth\n"
    )

    openssl(dir, [
      "req",
      "-x509",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-keyout",
      "ca.key",
      "-out",
      "ca.pem",
      "-subj",
      "/CN=Private Control Test CA",
      "-days",
      "1"
    ])

    openssl(dir, [
      "req",
      "-x509",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-keyout",
      "other.key",
      "-out",
      "other.pem",
      "-subj",
      "/CN=Unrelated Private Test CA",
      "-days",
      "1"
    ])

    openssl(dir, [
      "req",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-keyout",
      "server.key",
      "-out",
      "server.csr",
      "-subj",
      "/CN=#{@host}"
    ])

    openssl(dir, [
      "x509",
      "-req",
      "-in",
      "server.csr",
      "-CA",
      "ca.pem",
      "-CAkey",
      "ca.key",
      "-CAcreateserial",
      "-out",
      "server.pem",
      "-days",
      "1",
      "-extfile",
      "ext"
    ])

    old_lookup = :inet_db.get_rc() |> Keyword.get(:lookup, [:native])
    :inet_db.set_lookup([:file])

    :inet_db.add_host(
      {127, 0, 0, 1},
      Enum.map([@host, "wrong.tail8263c4.ts.net"], &String.to_charlist/1)
    )

    old_endpoint = System.fetch_env("ATLAS_CONTROL_ENDPOINT")
    :public_key.cacerts_load(String.to_charlist(Path.join(dir, "ca.pem")))

    ExUnit.Callbacks.on_exit(fn ->
      case old_endpoint do
        :error -> System.delete_env("ATLAS_CONTROL_ENDPOINT")
        {:ok, value} -> System.put_env("ATLAS_CONTROL_ENDPOINT", value)
      end

      :public_key.cacerts_clear()
      :inet_db.del_host({127, 0, 0, 1})
      :inet_db.set_lookup(old_lookup)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp openssl(dir, args) do
    {output, status} = System.cmd("openssl", args, cd: dir, stderr_to_stdout: true)
    if status != 0, do: raise("private certificate fixture: #{output}")
  end

  def listener(dir) do
    :ssl.listen(0, [
      :binary,
      ip: {127, 0, 0, 1},
      active: false,
      packet: :line,
      certfile: String.to_charlist(Path.join(dir, "server.pem")),
      keyfile: String.to_charlist(Path.join(dir, "server.key"))
    ])
  end

  def select(listener, host \\ @host) do
    {:ok, {_, port}} = :ssl.sockname(listener)
    System.put_env("ATLAS_CONTROL_ENDPOINT", "tls://#{host}:#{port}")
    port
  end

  def page do
    %{
      "op" => "page",
      "reason" => "open",
      "path" => "/",
      "title" => "Private",
      "blocks" => [],
      "markup" => [],
      "count" => "",
      "back" => nil,
      "position" => nil
    }
  end

  def send_line(socket, map), do: :ssl.send(socket, [JSON.encode!(map), "\n"])

  def read(socket) do
    {:ok, bytes} = :ssl.recv(socket, 0, 2_000)
    JSON.decode!(bytes)
  end
end

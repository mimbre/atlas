defmodule AtlasRuntime.Sources.SupervisorTest do
  # pull-e2e D5: a remote entry's own `ca_file`. `Sources.Supervisor.init/1` is read as data
  # (no puller is started); the open it gives a remote puller is then run against an
  # in-test HTTPS server on loopback (AtlasRuntime.TLSFixtures). The :httpc profile is
  # global, so not async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AtlasRuntime.Sources.{Credential, HttpTarget, Puller, Transport}
  alias AtlasRuntime.Sources.Supervisor, as: Sources
  alias AtlasRuntime.TLSFixtures, as: F

  @name "flow-test"
  @ca_file "sources/flow-test/ca.pem"

  setup do
    home = Path.join(System.tmp_dir!(), "d5-sup-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([home, "sources", @name]))
    path = Credential.path(home, @name)
    File.write!(path, "t0k." <> Base.encode16(:crypto.strong_rand_bytes(24), case: :lower))
    File.chmod!(path, 0o600)
    on_exit(fn -> File.rm_rf!(home) end)
    %{home: home}
  end

  defp remote(changes \\ %{}) do
    Map.merge(
      %{
        "name" => @name,
        "kind" => "remote",
        "url" => "https://localhost:8443/work-source",
        "credential_file" => "sources/flow-test/token",
        "priority" => 2,
        "max_slots" => 2,
        "max_store_bytes" => 268_435_456
      },
      changes
    )
  end

  # The `open:` `{module, fun, args}` of the remote puller's child spec.
  defp open_of(home, source, opts) do
    assert {:ok, {_flags, children}} = Sources.init({home, [source], opts})
    assert [%{start: {Puller, :start_link, [puller]}}] = children
    Keyword.fetch!(puller, :open)
  end

  # Opens the remote puller's source the way the puller does, closed at the test's end.
  defp open(home, source, opts) do
    {module, fun, args} = open_of(home, source, opts)

    case apply(module, fun, args) do
      {:ok, ref} ->
        on_exit(fn -> HttpTarget.close(ref) end)
        {:ok, ref}

      other ->
        other
    end
  end

  # A directory outside the home, removed at the test's end.
  defp outside do
    dir = Path.join(System.tmp_dir!(), "d5-out-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp served do
    test = self()

    fn conn ->
      send(test, {:served, conn.request_path})
      Plug.Conn.send_resp(conn, 200, "{}")
    end
  end

  defp get, do: %{method: "GET", path: "/v1/poll", query: "", headers: [], body: nil}

  describe "init/1, the remote puller's open" do
    test "without a ca_file it is HttpTarget's, with the caller's target options as given",
         %{home: home} do
      url = remote()["url"]
      assert open_of(home, remote(), []) == {HttpTarget, :open, [@name, url, home, []]}

      assert open_of(home, remote(), target: [cacertfile: "/t/ca.pem", uid: 7]) ==
               {HttpTarget, :open, [@name, url, home, [cacertfile: "/t/ca.pem", uid: 7]]}
    end

    test "with a ca_file it is the checked open of that file", %{home: home} do
      url = remote()["url"]
      opts = [target: [cacertfile: "/t/ca.pem", uid: 7]]

      assert open_of(home, remote(%{"ca_file" => @ca_file}), opts) ==
               {Sources, :open, [@name, url, home, @ca_file, [cacertfile: "/t/ca.pem", uid: 7]]}
    end
  end

  describe "the open of a remote source" do
    setup %{home: home} do
      pki = F.pki("localhost")
      server = start_supervised!(F.serve_spec(served(), pki))
      url = "https://localhost:#{F.port(server)}/work-source"
      %{pki: pki, url: url, home: home}
    end

    # Behaviour without a ca_file is as before D5: the OS CA store as OTP holds it
    # (`:public_key.cacerts_get/0`, read at open), TLS 1.3 only, the peer and its host name
    # verified. OTP's store is set here to a known CA (and cleared after, so OTP loads the
    # real one again on demand): the host's own store differs per machine, and a sandbox
    # may not let OTP read macOS's keychain at all.
    test "without a ca_file it trusts the OS store, TLS 1.3 only", ctx do
      on_exit(fn -> :public_key.cacerts_clear() end)
      source = remote(%{"url" => ctx.url})

      :ok = :public_key.cacerts_load(F.cacertfile(ctx.pki, ctx.home))
      assert {:ok, %{conn: conn}} = open(ctx.home, source, [])
      assert conn.ssl[:cacerts] == :public_key.cacerts_get()

      assert Enum.sort(for {:cert, der, _otp} <- conn.ssl[:cacerts], do: der) ==
               Enum.sort(ctx.pki.cacerts)

      refute Keyword.has_key?(conn.ssl, :cacertfile)
      assert conn.ssl[:versions] == [:"tlsv1.3"]
      assert conn.ssl[:verify] == :verify_peer
      assert conn.ssl[:server_name_indication] == ~c"localhost"
      assert {:ok, %{status: 200}} = Transport.request(get(), conn: conn)
      assert_received {:served, "/work-source/v1/poll"}

      # A store without the test CA: the same peer is refused.
      :ok = :public_key.cacerts_load(F.cacertfile(F.pki("localhost"), ctx.home))
      assert {:ok, %{conn: conn}} = open(ctx.home, source, [])

      capture_log(fn ->
        assert {:error, {:failed_connect, {:tls, _}}} = Transport.request(get(), conn: conn)
      end)

      refute_received {:served, _}
    end

    test "with a ca_file it trusts the certificates read from it, TLS 1.3 only", ctx do
      ca = Path.join(ctx.home, @ca_file)
      File.rename!(F.cacertfile(ctx.pki, ctx.home), ca)
      source = remote(%{"url" => ctx.url, "ca_file" => @ca_file})

      # The entry's file replaces a caller's cacertfile:; other caller options are kept.
      assert {:ok, %{conn: conn}} = open(ctx.home, source, target: [cacertfile: "/t/ca.pem"])
      assert Enum.sort(conn.ssl[:cacerts]) == Enum.sort(ctx.pki.cacerts)
      refute Keyword.has_key?(conn.ssl, :cacertfile)
      assert conn.ssl[:versions] == [:"tlsv1.3"]
      assert conn.ssl[:verify] == :verify_peer
      assert conn.ssl[:server_name_indication] == ~c"localhost"
      assert Keyword.has_key?(conn.ssl[:customize_hostname_check], :match_fun)

      # Read once: a file changed or removed after the open is not read again.
      File.write!(ca, File.read!(F.cacertfile(F.pki("localhost"), ctx.home)))
      assert {:ok, %{status: 200}} = Transport.request(get(), conn: conn)
      assert_received {:served, "/work-source/v1/poll"}

      File.rm!(ca)
      assert {:ok, %{status: 200}} = Transport.request(get(), conn: conn)
      assert_received {:served, "/work-source/v1/poll"}
    end

    test "a deeper ca_file is trusted when every directory on its path is real", ctx do
      File.mkdir_p!(Path.join([ctx.home, "sources", @name, "tls"]))

      File.rename!(
        F.cacertfile(ctx.pki, ctx.home),
        Path.join(ctx.home, "sources/flow-test/tls/ca.pem")
      )

      source = remote(%{"url" => ctx.url, "ca_file" => "sources/flow-test/tls/ca.pem"})

      assert {:ok, %{conn: conn}} = open(ctx.home, source, [])
      assert {:ok, %{status: 200}} = Transport.request(get(), conn: conn)
      assert_received {:served, "/work-source/v1/poll"}
    end

    test "a ca_file that is a symbolic link out of the home is refused, with no fallback", ctx do
      File.ln_s!(F.cacertfile(ctx.pki, outside()), Path.join(ctx.home, @ca_file))
      source = remote(%{"url" => ctx.url, "ca_file" => @ca_file})

      assert open(ctx.home, source, []) == {:error, {:ca_file, :symlink}}
      refute_received {:served, _}
    end

    test "a ca_file under a symbolic link to a directory out of the home is refused", ctx do
      out = outside()
      File.rename!(F.cacertfile(ctx.pki, out), Path.join(out, "ca.pem"))
      File.ln_s!(out, Path.join([ctx.home, "sources", @name, "tls"]))
      source = remote(%{"url" => ctx.url, "ca_file" => "sources/flow-test/tls/ca.pem"})

      assert open(ctx.home, source, []) == {:error, {:ca_file, :symlink}}
      refute_received {:served, _}
    end

    test "a missing, non-regular or certificate-less ca_file fails the open", ctx do
      source = remote(%{"url" => ctx.url, "ca_file" => @ca_file})
      ca = Path.join(ctx.home, @ca_file)
      assert open(ctx.home, source, []) == {:error, {:ca_file, :missing}}

      File.write!(ca, "not a certificate\n")
      assert open(ctx.home, source, []) == {:error, {:ca_file, :no_certificates}}

      # Valid certificates past the size bound.
      pem = File.read!(F.cacertfile(ctx.pki, ctx.home))
      File.write!(ca, [pem, :binary.copy("\n", 1_048_576)])
      assert open(ctx.home, source, []) == {:error, {:ca_file, :too_large}}

      File.rm!(ca)
      File.mkdir_p!(ca)
      assert open(ctx.home, source, []) == {:error, {:ca_file, :not_regular}}

      # A file component where a directory belongs.
      deeper = remote(%{"url" => ctx.url, "ca_file" => "sources/flow-test/ca.pem/x.pem"})
      File.rm_rf!(ca)
      File.write!(ca, "")
      assert open(ctx.home, deeper, []) == {:error, {:ca_file, :directory}}
      refute_received {:served, _}
    end

    test "a file swapped in after the check is refused as changed", ctx do
      checked = Path.join(ctx.home, @ca_file)
      File.rename!(F.cacertfile(ctx.pki, ctx.home), checked)
      {:ok, stat} = File.lstat(checked)
      # Renamed over it between the check and the open: another inode.
      File.rename!(F.cacertfile(ctx.pki, ctx.home), checked)

      assert Sources.read_checked(checked, stat) == {:error, :changed}
      assert {:ok, _pem} = Sources.read_checked(checked, File.lstat!(checked))
    end

    test "open/5 itself refuses a ca_file outside sources/<name>/", ctx do
      for path <- [
            "sources/other/ca.pem",
            "sources/flow-test/../token",
            "/etc/ssl/cert.pem",
            "sources/flow-test"
          ] do
        assert Sources.open(@name, ctx.url, ctx.home, path, []) == {:error, {:ca_file, :outside}}
      end
    end
  end
end

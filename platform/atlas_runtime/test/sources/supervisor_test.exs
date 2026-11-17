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

  # The `{HttpTarget, :open, args}` of the remote puller's child spec.
  defp open_of(home, source, opts) do
    assert {:ok, {_flags, children}} = Sources.init({home, [source], opts})
    assert [%{start: {Puller, :start_link, [puller]}}] = children
    assert {HttpTarget, :open, [@name, url, ^home, target]} = Keyword.fetch!(puller, :open)
    assert url == source["url"]
    target
  end

  # Opens the remote puller's source the way the puller does, closed at the test's end.
  defp open(home, source, opts) do
    case HttpTarget.open(@name, source["url"], home, open_of(home, source, opts)) do
      {:ok, ref} ->
        on_exit(fn -> HttpTarget.close(ref) end)
        {:ok, ref}

      other ->
        other
    end
  end

  defp served do
    test = self()

    fn conn ->
      send(test, {:served, conn.request_path})
      Plug.Conn.send_resp(conn, 200, "{}")
    end
  end

  defp get, do: %{method: "GET", path: "/v1/poll", query: "", headers: [], body: nil}

  describe "init/1, the remote puller's open options" do
    test "without a ca_file they are the caller's target options as given", %{home: home} do
      assert open_of(home, remote(), []) == []

      assert open_of(home, remote(), target: [cacertfile: "/t/ca.pem", uid: 7]) ==
               [cacertfile: "/t/ca.pem", uid: 7]
    end

    test "a ca_file is trusted from the home, in place of the caller's", %{home: home} do
      ca = Path.join(home, @ca_file)
      assert open_of(home, remote(%{"ca_file" => @ca_file}), []) == [cacertfile: ca]

      target =
        open_of(home, remote(%{"ca_file" => @ca_file}), target: [cacertfile: "/t/ca.pem", uid: 7])

      assert Keyword.get_values(target, :cacertfile) == [ca]
      assert target[:uid] == 7
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

    test "with a ca_file it trusts that file only, TLS 1.3 only", ctx do
      ca = Path.join(ctx.home, @ca_file)
      File.rename!(F.cacertfile(ctx.pki, ctx.home), ca)
      source = remote(%{"url" => ctx.url, "ca_file" => @ca_file})

      assert {:ok, %{conn: conn}} = open(ctx.home, source, [])
      assert conn.ssl[:cacertfile] == String.to_charlist(ca)
      refute Keyword.has_key?(conn.ssl, :cacerts)
      assert conn.ssl[:versions] == [:"tlsv1.3"]
      assert conn.ssl[:verify] == :verify_peer

      assert {:ok, %{status: 200}} = Transport.request(get(), conn: conn)
      assert_received {:served, "/work-source/v1/poll"}
    end

    test "a missing or non-regular ca_file fails the open, with no fallback", ctx do
      source = remote(%{"url" => ctx.url, "ca_file" => @ca_file})
      assert open(ctx.home, source, []) == {:error, :no_cacerts}

      File.mkdir_p!(Path.join(ctx.home, @ca_file))
      assert open(ctx.home, source, []) == {:error, :no_cacerts}
    end
  end
end

defmodule AtlasRuntime.Remote.ConfigTest do
  # The OS environment and the :httpc profile are global.
  use ExUnit.Case, async: false

  alias AtlasRuntime.Remote.Config
  alias AtlasRuntime.RemoteFixtures, as: F

  @flag "ATLAS_RUNTIME_REMOTE"
  @url "ATLAS_RUNTIME_BACKEND_URL"
  @token "ATLAS_RUNTIME_BACKEND_TOKEN"

  setup do
    on_exit(fn ->
      System.delete_env(@url)
      System.delete_env(@token)
    end)

    token = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    %{token: token, opts: [proxy: {"localhost", F.closed_port()}, cacerts: F.pki().cacerts]}
  end

  defp reading(values) do
    test = self()

    fn name ->
      send(test, {:read, name})
      Map.get(values, name)
    end
  end

  defp read do
    receive do
      {:read, name} -> [name | read()]
    after
      0 -> []
    end
  end

  describe "the flag" do
    test "off: no child, and nothing but the flag is read" do
      for off <- [nil, "", "0"] do
        values = %{@flag => off, @url => "https://mini.tailnet.test:8443", @token => "secret"}
        assert Config.child_specs(reading(values)) == []
        assert read() == [@flag]
      end
    end

    test "on (1): the configuration process is the one child" do
      assert Config.child_specs(reading(%{@flag => "1"})) == [Config]
      assert read() == [@flag]
    end

    test "anything else stops the start" do
      for other <- ["2", "true", "yes", " 1"] do
        assert_raise ArgumentError, "#{@flag} must be 0 or 1", fn ->
          Config.child_specs(reading(%{@flag => other}))
        end
      end
    end
  end

  describe "the URL" do
    test "is https://<host>:<port>" do
      assert Config.parse_url("https://mini.tailnet.test:8443") ==
               {:ok,
                %{host: "mini.tailnet.test", port: 8443, base: "https://mini.tailnet.test:8443"}}
    end

    test "http:// is refused" do
      assert {:error, "ATLAS_RUNTIME_BACKEND_URL must be an https:// URL"} =
               Config.parse_url("http://mini.tailnet.test:8443")
    end

    test "a path, query, fragment, user or missing port is refused" do
      for url <- [
            "https://mini.tailnet.test",
            "https://mini.tailnet.test:8443/",
            "https://mini.tailnet.test:8443/v1",
            "https://mini.tailnet.test:8443?x=1",
            "https://mini.tailnet.test:8443#x",
            "https://core:secret@mini.tailnet.test:8443",
            "https://mini.tailnet.test:0",
            "https://mini.tailnet.test:70000",
            "https://:8443",
            "mini.tailnet.test:8443",
            ""
          ] do
        assert {:error, _why} = Config.parse_url(url), url
      end

      assert {:error, "ATLAS_RUNTIME_BACKEND_URL is not set"} = Config.parse_url(nil)
    end
  end

  describe "starting" do
    test "reads the token once and removes it from the OS environment", ctx do
      System.put_env(@url, "https://mini.tailnet.test:8443")
      System.put_env(@token, ctx.token)

      start_supervised!({Config, ctx.opts})

      assert System.get_env(@token) == nil
      assert {:ok, context} = Config.context()
      assert context.authorization.() == "Bearer " <> ctx.token
      assert context.base == "https://mini.tailnet.test:8443"
    end

    test "the TLS options verify the peer and its host name", ctx do
      System.put_env(@url, "https://mini.tailnet.test:8443")
      System.put_env(@token, ctx.token)
      start_supervised!({Config, ctx.opts})

      assert {:ok, %{ssl: ssl}} = Config.context()
      assert ssl[:verify] == :verify_peer
      assert ssl[:server_name_indication] == ~c"mini.tailnet.test"
      assert is_function(ssl[:customize_hostname_check][:match_fun], 2)
    end

    test "an http:// URL stops the start, and the token is still removed", ctx do
      System.put_env(@url, "http://mini.tailnet.test:8443")
      System.put_env(@token, ctx.token)

      assert {:error, {{:invalid_config, why}, _child}} = start_supervised({Config, ctx.opts})
      assert why =~ "https://"
      assert System.get_env(@token) == nil
      refute Config.configured?()
    end

    test "a missing or malformed token stops the start, and is never quoted", ctx do
      System.put_env(@url, "https://mini.tailnet.test:8443")

      assert {:error, {{:invalid_config, "ATLAS_RUNTIME_BACKEND_TOKEN is not set"}, _}} =
               start_supervised({Config, ctx.opts})

      bad = ctx.token <> " \r\nx-injected: 1"
      System.put_env(@token, bad)

      assert {:error, {{:invalid_config, why}, _}} = start_supervised({Config, ctx.opts})
      refute why =~ ctx.token
      assert System.get_env(@token) == nil
    end

    # P6 review M1: the token is gone from the env once read, so a restart could only fail,
    # and failing restarts would take the supervisor (in the release: AtlasRuntime.Root,
    # and with it the core) down.
    test "a crash never escalates: the child is temporary, and the client is then off", ctx do
      System.put_env(@url, "https://mini.tailnet.test:8443")
      System.put_env(@token, ctx.token)

      assert %{restart: :temporary} = Supervisor.child_spec(Config, [])
      {:ok, sup} = Supervisor.start_link([{Config, ctx.opts}], strategy: :one_for_one)
      Process.unlink(sup)
      watch = Process.monitor(sup)
      on_exit(fn -> if Process.alive?(sup), do: Supervisor.stop(sup) end)

      config = GenServer.whereis(Config)
      gone = Process.monitor(config)
      Process.exit(config, :kill)
      assert_receive {:DOWN, ^gone, :process, ^config, :killed}

      refute_receive {:DOWN, ^watch, :process, ^sup, _}, 500
      assert Supervisor.which_children(sup) == []
      refute Config.configured?()
      assert AtlasRuntime.Remote.probe() == {:error, :not_configured}
      assert System.get_env(@token) == nil
    end

    # P6 review S1: at the head, the filter sees each event before Elixir's translator (or
    # any other filter) formats it with inspect limits that could cut the token.
    test "the log filter is the first primary filter, ahead of any already there", ctx do
      :ok = :logger.add_primary_filter(:config_test_first, {fn event, _ -> event end, nil})
      on_exit(fn -> :logger.remove_primary_filter(:config_test_first) end)

      assert {:config_test_first, _} =
               List.keyfind(:logger.get_primary_config().filters, :config_test_first, 0)

      System.put_env(@url, "https://mini.tailnet.test:8443")
      System.put_env(@token, ctx.token)
      start_supervised!({Config, ctx.opts})

      assert [{:atlas_runtime_remote_token, _} | others] = :logger.get_primary_config().filters
      assert List.keymember?(others, :config_test_first, 0)
      refute List.keymember?(others, :atlas_runtime_remote_token, 0)
    end

    test ":sys.get_status shows no token", ctx do
      System.put_env(@url, "https://mini.tailnet.test:8443")
      System.put_env(@token, ctx.token)
      start_supervised!({Config, ctx.opts})

      status = inspect(:sys.get_status(Config), limit: :infinity, printable_limit: :infinity)
      refute status =~ ctx.token
      assert status =~ "[redacted]"
    end
  end
end

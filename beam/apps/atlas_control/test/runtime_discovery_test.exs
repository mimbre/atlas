defmodule AtlasControl.RuntimeDiscoveryTest do
  use ExUnit.Case, async: false

  setup do
    Application.put_env(:atlas_bus, :store, "discovery-#{System.unique_integer([:positive])}")
    start_supervised!(AtlasControl.FakeStore)

    start_supervised!(
      {AtlasControl.Gateway, port: 0, name: :discovery_gateway, model: AtlasControl.Shop}
    )

    prior = Application.get_env(:atlas_control, :runtime_read_token_env)
    Application.put_env(:atlas_control, :runtime_read_token_env, "ATLAS_PRIVATE_DISCOVERY_TEST")

    System.put_env(
      "ATLAS_PRIVATE_DISCOVERY_TEST",
      JSON.encode!(%{"fixture" => "private-read-grant"})
    )

    on_exit(fn ->
      System.delete_env("ATLAS_PRIVATE_DISCOVERY_TEST")

      if prior,
        do: Application.put_env(:atlas_control, :runtime_read_token_env, prior),
        else: Application.delete_env(:atlas_control, :runtime_read_token_env)

      for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasControl.Sessions),
          do: DynamicSupervisor.terminate_child(AtlasControl.Sessions, pid)
    end)

    %{port: AtlasControl.Gateway.port(:discovery_gateway)}
  end

  defp send_message(s, m), do: :gen_tcp.send(s, [JSON.encode!(m), "\n"])

  defp receive_message(s) do
    {:ok, b} = :gen_tcp.recv(s, 0, 1_000)
    JSON.decode!(b)
  end

  defp request(overrides \\ %{}) do
    Map.merge(
      %{
        "op" => "machine_discover",
        "channel" => "control",
        "version" => "0.1.0",
        "id" => "read-1",
        "target" => %{"environment" => "test", "machine" => "fixture"}
      },
      overrides
    )
  end

  defp connected(port, extra \\ %{}) do
    {:ok, s} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :line, active: false])
    on_exit(fn -> :gen_tcp.close(s) end)

    send_message(
      s,
      Map.merge(
        %{"op" => "hello", "env" => "test", "spec" => "0.16.0", "client" => "agent"},
        extra
      )
    )

    assert %{"op" => "welcome"} = receive_message(s)
    assert %{"op" => "page"} = receive_message(s)
    s
  end

  test "hello actor strings do not grant read authority", %{port: port} do
    :ok = AtlasBus.attach("runtime@fixture")

    for hello <- [%{"client" => "migration"}, %{"client" => "tui"}, %{"as" => "fixture"}] do
      s = connected(port, hello)
      send_message(s, request())

      assert %{"op" => "machine_discover_error", "error" => %{"code" => "unauthorized"}} =
               receive_message(s)
    end
  end

  test "read grant binds exact environment/machine and observes registry only", %{port: port} do
    s = connected(port)
    send_message(s, request(%{"grant" => "private-read-grant"}))
    assert %{"availability" => %{"registered" => false}} = receive_message(s)
    :ok = AtlasBus.attach("runtime@fixture/turn-only")
    send_message(s, request(%{"grant" => "private-read-grant"}))
    assert %{"availability" => %{"registered" => false}} = receive_message(s)
    :ok = AtlasBus.attach("runtime@fixture")
    send_message(s, request(%{"grant" => "private-read-grant"}))

    assert %{"availability" => %{"registered" => true, "basis" => "bus_endpoint_registry"} = a} =
             receive_message(s)

    refute Map.has_key?(a, "healthy")

    for target <- [
          %{"environment" => "prod", "machine" => "fixture"},
          %{"environment" => "test", "machine" => "fixture-other"}
        ] do
      send_message(s, request(%{"target" => target, "grant" => "private-read-grant"}))
      assert %{"error" => %{"code" => "unauthorized"}} = receive_message(s)
    end
  end

  test "default deny, bad grants and malformed shapes precede any registry access" do
    query = fn ->
      send(self(), :queried)
      ["runtime@fixture"]
    end

    for grant <- [nil, "wrong"] do
      assert %{"error" => %{"code" => "unauthorized"}} =
               AtlasControl.RuntimeDiscovery.read(request(%{"grant" => grant}), true, query)

      refute_received :queried
    end

    valid = request(%{"grant" => "private-read-grant"})

    assert %{"error" => %{"code" => "unauthorized"}} =
             AtlasControl.RuntimeDiscovery.read(valid, false, query)

    for data <- ["{}", "[]", "not-json", ~s({"fixture":1}), ~s({"*":"private-read-grant"})] do
      System.put_env("ATLAS_PRIVATE_DISCOVERY_TEST", data)

      assert %{"error" => %{"code" => "unauthorized"}} =
               AtlasControl.RuntimeDiscovery.read(valid, true, query)

      refute_received :queried
    end

    Application.delete_env(:atlas_control, :runtime_read_token_env)

    assert %{"error" => %{"code" => "unauthorized"}} =
             AtlasControl.RuntimeDiscovery.read(valid, true, query)

    for bad <- [
          put_in(valid, ["target"], []),
          Map.put(valid, "version", "future"),
          Map.put(valid, "as", "fixture")
        ] do
      assert %{"error" => %{"code" => "invalid_request"}} =
               AtlasControl.RuntimeDiscovery.read(bad, true, query)

      refute_received :queried
    end
  end

  test "revocation applies per request and registry timeout is not absence", %{port: port} do
    s = connected(port)
    System.put_env("ATLAS_PRIVATE_DISCOVERY_TEST", "{}")
    send_message(s, request(%{"grant" => "private-read-grant"}))
    assert %{"error" => %{"code" => "unauthorized"}} = receive_message(s)

    System.put_env(
      "ATLAS_PRIVATE_DISCOVERY_TEST",
      JSON.encode!(%{"fixture" => "private-read-grant"})
    )

    reply =
      AtlasControl.RuntimeDiscovery.read(request(%{"grant" => "private-read-grant"}), true, fn ->
        exit(:timeout)
      end)

    assert reply["error"]["code"] == "registry_unavailable"
    refute Map.has_key?(reply, "availability")
    refute JSON.encode!(reply) =~ "private-read-grant"
  end

  @tag timeout: 60_000
  test "existing atlas CLI proves granted read and denial through actual private Control", %{
    port: port
  } do
    root = Path.expand("../../../..", __DIR__)

    dir =
      Path.join(System.tmp_dir!(), "atlas-discovery-cli-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    file = Path.join(dir, "client.json")

    File.write!(
      file,
      JSON.encode!(%{"env" => "test", "control" => %{"host" => "127.0.0.1", "port" => port}})
    )

    env = [
      {"ATLAS_NO_UPDATE", "1"},
      {"ATLAS_ENV_FILE", file},
      {"MIX_ENV", "test"},
      {"ELIXIR_ERL_OPTIONS", "+S 1:1"},
      {"ATLAS_RUNTIME_READ_TOKEN", "private-read-grant"},
      {"ATLAS_RUNTIME_HOME", Path.join(dir, "never-created-runtime")}
    ]

    :ok = AtlasBus.attach("runtime@fixture")

    for {grant, expected} <- [{"private-read-grant", 0}, {"wrong-grant", 2}] do
      {output, code} =
        System.cmd(
          Path.join(root, "bin/atlas"),
          ["discover", "--env", "test", "--machine", "fixture", "--json"],
          env:
            List.keystore(env, "ATLAS_RUNTIME_READ_TOKEN", 0, {"ATLAS_RUNTIME_READ_TOKEN", grant})
        )

      assert code == expected, output
      frame = JSON.decode!(String.trim(output))

      if code == 0,
        do: assert(frame["availability"]["registered"]),
        else: assert(frame["error"]["code"] == "unauthorized")

      refute output =~ grant
      refute File.exists?(Path.join(dir, "never-created-runtime"))
    end
  end

  test "runtime configuration keeps live defaults denied and only reads an opt-in env name" do
    root = Path.expand("../../../..", __DIR__)

    dir =
      Path.join(System.tmp_dir!(), "atlas-discovery-config-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    file = Path.join(dir, "server.json")

    variables = %{
      "ATLAS_ROOT" => root,
      "ATLAS_ENV" => "test",
      "ATLAS_ENV_FILE" => file,
      "ATLAS_ROLE" => "core"
    }

    prior = Map.new(variables, fn {key, _} -> {key, System.get_env(key)} end)

    try do
      System.put_env(variables)

      for token_env <- [nil, "UNSET_PRIVATE_READ_TOKEN_NAME"] do
        settings = %{
          "env" => "test",
          "control" => %{
            "host" => "127.0.0.1",
            "port" => 1,
            "runtime_read_token_env" => token_env
          },
          "rela" => %{"url" => "http://127.0.0.1:1"},
          "facts" => %{"data" => Path.join(dir, "unused")}
        }

        File.write!(file, JSON.encode!(settings))
        config = Config.Reader.read!(Path.join(root, "beam/config/runtime.exs"), env: :dev)
        assert config[:atlas_control][:runtime_read_token_env] == token_env
        refute File.exists?(Path.join(dir, "unused"))
      end
    after
      for {key, value} <- prior do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end
  end

  test "even a correct read grant is refused before normal hello admission", %{port: port} do
    {:ok, s} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :line, active: false])
    on_exit(fn -> :gen_tcp.close(s) end)
    send_message(s, request(%{"grant" => "private-read-grant"}))
    assert %{"error" => %{"code" => "unauthorized"}} = receive_message(s)
  end

  test "invalid configured grant names deny on a surviving session without logging bearer bytes",
       %{port: port} do
    s = connected(port)
    secret = "PRIVATE_READ_SECRET_LOG_ASSERTION"

    for name <- ["BAD=NAME", "BAD" <> <<0>> <> "NAME", "BAD\n", "", "1INVALID"] do
      Application.put_env(:atlas_control, :runtime_read_token_env, name)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send_message(s, request(%{"grant" => secret}))
          send(self(), {:response, :gen_tcp.recv(s, 0, 1_000)})
        end)

      assert_receive {:response, {:ok, bytes}}
      assert %{"error" => %{"code" => "unauthorized"}} = JSON.decode!(bytes)
      refute log =~ secret
      query = fn -> flunk("invalid name must precede registry access") end

      assert %{"error" => %{"code" => "unauthorized"}} =
               AtlasControl.RuntimeDiscovery.read(request(%{"grant" => secret}), true, query)
    end

    Application.put_env(:atlas_control, :runtime_read_token_env, "ATLAS_PRIVATE_DISCOVERY_TEST")
    send_message(s, request(%{"grant" => "private-read-grant"}))
    assert %{"availability" => _} = receive_message(s)
  end
end

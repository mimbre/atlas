defmodule AtlasControl.ActorsTest do
  # The actors the model's owners name (`config: role`): the environment's settings fill
  # each role (`actors:` here). Control does not start without one; whether its fact
  # exists does not stop Control.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias AtlasControl.{FakeStore, Gateway, Shop}

  setup do
    Application.put_env(:atlas_bus, :store, "store-#{System.unique_integer([:positive])}")
    :ok
  end

  defp gateway(actors) do
    name = :"gateway_#{System.unique_integer([:positive])}"
    opts = [port: 0, name: name, model: Shop.Delegated, actors: actors]
    with {:ok, _} <- start_supervised({Gateway, opts}, id: name), do: {:ok, Gateway.port(name)}
  end

  # What Control answers a client's hello: the op of its first message, and its text.
  defp hello(port) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :line, active: false])

    hello = %{
      "op" => "hello",
      "env" => AtlasBus.environment(),
      "client" => "test",
      "spec" => AtlasControl.Blocks.version()
    }

    :ok = :gen_tcp.send(socket, [JSON.encode!(hello), "\n"])
    {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)
    Map.take(JSON.decode!(line), ["op", "text"])
  end

  test "the model's owners name the role; the settings fill it with someone who exists" do
    assert Shop.Delegated.actors() == [approver: "member"]
    start_supervised!({FakeStore, model: Shop.Delegated})
    FakeStore.put("ada", %{"name" => "Ada"}, "member")
    assert {:ok, port} = gateway(%{"approver" => "ada"})
    assert %{"op" => "welcome"} = hello(port)
  end

  test "Control does not start when the settings do not fill a role its owners name" do
    start_supervised!({FakeStore, model: Shop.Delegated})

    for actors <- [nil, %{}, %{"approver" => ""}] do
      assert {:error, {{%ArgumentError{message: why}, _}, _}} = gateway(actors)

      assert why =~
               "Control does not start: the environment's settings give no actors.approver"
    end
  end

  # A fresh environment: its first actors are made through Control, so Control serves
  # before they exist; what they are to own waits for them (Flow).
  test "Control serves while the configured actor does not exist yet" do
    start_supervised!({FakeStore, model: Shop.Delegated})
    assert {:ok, port} = gateway(%{"approver" => "zed"})
    assert %{"op" => "welcome"} = hello(port)
  end
end

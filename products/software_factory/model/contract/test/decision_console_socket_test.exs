defmodule Model.DecisionConsoleSocketTest do
  use ExUnit.Case, async: false

  alias AtlasBFFContract.Console
  alias AtlasFacts.FakeRela

  @moduletag :tmp_dir
  @moduletag :capture_log
  @model Model.AtlasEyra
  @options File.read!(Path.expand("../../../e2e/fixtures/decision-options.json", __DIR__))

  setup %{tmp_dir: dir} do
    environment = Application.get_env(:atlas_bus, :environment)
    store = Application.get_env(:atlas_bus, :store)
    Application.put_env(:atlas_bus, :environment, "test")

    Application.put_env(
      :atlas_bus,
      :store,
      "decision-console-#{System.unique_integer([:positive])}"
    )

    on_exit(fn ->
      restore(:environment, environment)
      restore(:store, store)
    end)

    {:ok, _} = Application.ensure_all_started(:atlas_bus)
    rela = FakeRela.start(@model)

    {:ok, _} =
      FakeRela.create(
        rela,
        "decisions",
        "D-legacy",
        %{
          "title" => "Legacy decision",
          "status" => "accepted",
          "decision" => "The recorded rule",
          "context" => "The recorded context",
          "consequences" => "The recorded consequences"
        },
        %{}
      )

    {:ok, _} =
      FakeRela.create(
        rela,
        "decisions",
        "D-offer",
        %{
          "title" => "Offered decision",
          "status" => "accepted",
          "decision" => "The offered rule",
          "context" => "The offered context",
          "options" => @options
        },
        %{}
      )

    start_supervised!({AtlasFacts.Server, rela: {FakeRela, rela}, data_dir: dir, model: @model})
    start_supervised!({DynamicSupervisor, name: AtlasControl.Sessions, strategy: :one_for_one})

    gateway =
      start_supervised!(
        {AtlasControl.Gateway,
         port: 0,
         name: :decision_console_gateway,
         model: @model,
         actors: %{"decider" => "someone"}}
      )

    %{port: AtlasControl.Gateway.port(gateway)}
  end

  defp restore(key, nil), do: Application.delete_env(:atlas_bus, key)
  defp restore(key, value), do: Application.put_env(:atlas_bus, key, value)

  defp send_message(socket, message),
    do: :ok = :gen_tcp.send(socket, [JSON.encode!(message), "\n"])

  defp read_message(socket) do
    {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)
    JSON.decode!(line)
  end

  defp open(socket, path) do
    send_message(socket, %{"op" => "open", "to" => path})
    page = read_message(socket)
    assert %{"op" => "page", "path" => ^path} = page
    assert :ok = AtlasBFF.Markup.check(Enum.map(page["blocks"], & &1["id"]), page["markup"])
    assert {:ok, _} = Console.compile(page)
    page
  end

  defp block(page, id), do: Enum.find(page["blocks"], &(&1["id"] == id))

  defp item_fields(page) do
    for block <- page["blocks"],
        block["type"] == "item",
        field <- block["props"]["fields"] || [],
        do: field
  end

  test "read-only legacy and offered decisions project over TCP and keep the connection usable",
       %{
         port: port
       } do
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", port, [
        :binary,
        packet: :line,
        active: false,
        buffer: 4_194_304
      ])

    on_exit(fn -> :gen_tcp.close(socket) end)

    send_message(socket, %{
      "op" => "hello",
      "env" => "test",
      "client" => "agent",
      "as" => "viewer",
      "surface" => "console",
      "spec" => AtlasControl.Blocks.version()
    })

    assert %{"op" => "welcome", "surface" => "console"} = read_message(socket)
    assert %{"op" => "page"} = read_message(socket)

    legacy = open(socket, "/k/decision/D-legacy")
    assert block(legacy, "header")["props"]["title"] == "Legacy decision"
    assert block(legacy, "decision-decision")["props"]["text"] == "The recorded rule"
    assert block(legacy, "decision-consequences")["props"]["text"] == "The recorded consequences"
    refute block(legacy, "option-1")
    assert Enum.count(legacy["blocks"], &(&1["id"] == "item")) <= 1
    assert Enum.any?(block(legacy, "actions")["props"]["actions"], &(&1["key"] == "u"))
    fields = item_fields(legacy)
    assert Enum.count(fields, &(&1["value"] == "The recorded context")) == 1
    refute Enum.any?(fields, &(&1["value"] in ["The recorded rule", "The recorded consequences"]))
    refute Enum.any?(fields, &(&1["value"] in [nil, "", "—"]))

    offered = open(socket, "/k/decision/D-offer")

    assert block(offered, "header")["props"]["title"] ==
             "How should the private example be stored?"

    assert block(offered, "option-1")["props"]["title"] == "1. Use files"
    assert block(offered, "option-2")["props"]["title"] == "2. Use memory"

    assert block(offered, "decision-raw-options")["props"]["fields"]
           |> hd()
           |> Map.fetch!("value") == @options

    assert Enum.count(offered["blocks"], &(&1["id"] == "item")) <= 1
    assert Enum.any?(block(offered, "actions")["props"]["actions"], &(&1["key"] == "u"))
    assert Enum.any?(item_fields(offered), &(&1["value"] == "The offered context"))
    refute Enum.any?(item_fields(offered), &(&1["value"] in [nil, "", "—"]))

    assert open(socket, "/k/decision/D-legacy")["path"] == "/k/decision/D-legacy"
  end
end

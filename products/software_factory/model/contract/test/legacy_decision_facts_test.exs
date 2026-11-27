defmodule Model.LegacyDecisionFactsTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir
  @moduletag :capture_log

  alias AtlasBus.Envelope
  alias AtlasFacts.FakeRela
  alias RelaDSL.DecisionOptions

  @legacy File.read!(Path.expand("../../generator/test/legacy_d0105.json", __DIR__))
  @model Model.AtlasEyra
  @rule @model.__rela__(:description).extension["entities"]["decision"]["decision_options"]

  setup %{tmp_dir: dir} do
    environment = Application.get_env(:atlas_bus, :environment)
    store = Application.get_env(:atlas_bus, :store)
    Application.put_env(:atlas_bus, :environment, "test")

    Application.put_env(
      :atlas_bus,
      :store,
      "legacy-decision-#{System.unique_integer([:positive])}"
    )

    on_exit(fn ->
      restore(:environment, environment)
      restore(:store, store)
    end)

    {:ok, _} = Application.ensure_all_started(:atlas_bus)
    rela = FakeRela.start(@model)
    {:ok, _} = FakeRela.create(rela, "people", "ada", %{}, %{})

    {:ok, _} =
      FakeRela.create(
        rela,
        "decisions",
        "D-0105",
        %{
          "title" => "Clients are tolerant; a contract version difference is a warning",
          "decision" => "A proposed example",
          "status" => "proposed",
          "options" => @legacy
        },
        %{}
      )

    server =
      start_supervised!({AtlasFacts.Server, rela: {FakeRela, rela}, data_dir: dir, model: @model})

    :ok = AtlasBus.attach("control/session-legacy-#{System.unique_integer([:positive])}")
    %{rela: rela, server: server}
  end

  defp restore(key, nil), do: Application.delete_env(:atlas_bus, key)
  defp restore(key, value), do: Application.put_env(:atlas_bus, key, value)

  defp request(class, content) do
    envelope = Envelope.new(class, "decision")
    :ok = AtlasBus.send(envelope, content)
    id = envelope.id
    assert_receive {:atlas_bus, %Envelope{id: ^id, class: class}, answer}, 2_000
    {class, answer}
  end

  test "Facts stores the derived legacy decline and its original revision atomically", %{
    rela: rela
  } do
    assert {"answer", %{"fact" => original}} = request("read", %{"key" => "D-0105"})
    revision = DecisionOptions.revision(@rule, @legacy, original)

    assert [%{"label" => "Tolerant clients; a version difference is a warning"}] =
             DecisionOptions.answers(@rule, original)

    assert {"refused", _} =
             request("fact", %{
               "op" => "change",
               "key" => "D-0105",
               "by" => "ada",
               "values" => %{"options" => @legacy}
             })

    assert {"stored", _} =
             request("fact", %{
               "op" => "change",
               "key" => "D-0105",
               "by" => "ada",
               "values" => %{"status" => "revising", "alternative" => "Another approach"},
               "links" => %{"decided_by" => ["ada"]}
             })

    assert {"answer", %{"fact" => revised}} = request("read", %{"key" => "D-0105"})
    values = revised["values"]
    assert values["status"] == "revising"
    assert values["alternative"] == "Another approach"

    assert [%{"definition" => @legacy, "revision" => ^revision}] =
             JSON.decode!(values["option_history"])

    assert %{
             "options" => [
               _,
               %{"id" => "gate", "effect" => "decline"},
               %{"id" => "alternative", "text" => "Another approach"}
             ]
           } = JSON.decode!(values["options"])

    assert {stored, _} = FakeRela.facts(rela)["D-0105"]
    assert stored["options"] == values["options"]
    assert stored["option_history"] == values["option_history"]
  end

  test "Facts refuses a derived alternative when the old history is malformed", %{
    rela: rela,
    server: server
  } do
    FakeRela.poke(rela, "D-0105", %{"option_history" => "not JSON"})
    :ok = AtlasFacts.Server.reload(server)
    {before, _} = FakeRela.facts(rela)["D-0105"]

    assert {"refused", %{"reasons" => reasons}} =
             request("fact", %{
               "op" => "change",
               "key" => "D-0105",
               "by" => "ada",
               "values" => %{"status" => "revising", "alternative" => "Another approach"},
               "links" => %{"decided_by" => ["ada"]}
             })

    assert Enum.any?(reasons, &String.contains?(&1, "stored offered option history is malformed"))
    assert {^before, _} = FakeRela.facts(rela)["D-0105"]
    assert FakeRela.links(rela)["D-0105"] in [nil, %{}]
  end
end

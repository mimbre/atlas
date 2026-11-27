defmodule AtlasFacts.RelationGuardTest do
  use ExUnit.Case, async: false

  alias AtlasBus.Envelope
  alias AtlasFacts.FakeRela
  alias AtlasFacts.Workshop.Description

  defmodule Model do
    use AtlasFacts.TestModel,
      description:
        Description.with(%{
          "entities" => %{
            "widget" => %{"properties" => %{
              "suggestions" => %{"type" => "string"},
              "designed" => %{"type" => "string"},
              "known" => %{"type" => "boolean"}
            }}
          },
          "relations" => %{"made_by" => %{"guard" => %{
            "kind" => "widget", "equal" => ["suggestions", "designed"],
            "not_false" => "known", "error" => "design is stale"
          }}}
        })
  end

  defmodule RacingRela do
    @behaviour AtlasFacts.Rela
    def description({pid, _}), do: FakeRela.description(pid)
    def list({pid, _}, plural), do: FakeRela.list(pid, plural)
    def get({pid, race}, plural, key) do
      if key == "W-1" and Agent.get(race, &(&1 == :read_error)),
        do: {:error, :unavailable},
        else: FakeRela.get(pid, plural, key)
    end
    def incoming({pid, _}, plural, key, relation), do: FakeRela.incoming(pid, plural, key, relation)
    def check_create({pid, _}, plural, key, values, targets), do: FakeRela.check_create(pid, plural, key, values, targets)
    def create({pid, _}, plural, key, values, targets), do: FakeRela.create(pid, plural, key, values, targets)
    def delete({pid, _}, plural, key, version), do: FakeRela.delete(pid, plural, key, version)
    def change({pid, race}, plural, key, values, version, targets) do
      if Agent.get_and_update(race, &{&1 == true, false}) do
        FakeRela.poke(pid, key, %{"suggestions" => "new"})
      end
      FakeRela.change(pid, plural, key, values, version, targets)
    end
  end

  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    Application.put_env(:atlas_bus, :store, "guard-#{System.unique_integer([:positive])}")
    rela = FakeRela.start(Model)
    {:ok, race} = Agent.start_link(fn -> false end)
    start_supervised!({AtlasFacts.Server, rela: {RacingRela, {rela, race}}, data_dir: dir, model: Model})
    :ok = AtlasBus.attach("guard-tester-#{System.unique_integer([:positive])}")
    assert {"stored", _} = put("maker", "create", "M-1", %{"title" => "Maker"})
    assert {"stored", _} = put("widget", "create", "W-1", %{"title" => "Widget"})
    %{rela: rela, race: race}
  end

  defp put(kind, op, key, values, links \\ %{}) do
    envelope = Envelope.new("fact", kind)
    :ok = AtlasBus.send(envelope, %{"op" => op, "key" => key, "values" => values, "links" => links, "version" => nil})
    id = envelope.id
    assert_receive {:atlas_bus, %Envelope{id: ^id} = reply, answer}, 1_000
    {reply.class, answer["reasons"]}
  end

  test "direct link writes require the latest proposed snapshot, but legacy nil is allowed" do
    link = %{"made_by" => ["M-1"]}
    assert {"stored", _} = put("widget", "change", "W-1", %{}, link)
    assert {"stored", _} = put("widget", "change", "W-1", %{}, %{"made_by" => []})
    assert {"stored", _} = put("widget", "change", "W-1", %{"suggestions" => "new"})
    assert {"refused", ["design is stale"]} = put("widget", "change", "W-1", %{}, link)
    assert {"refused", ["design is stale"]} = put("widget", "change", "W-1", %{"designed" => "new", "known" => false}, link)
    assert {"stored", _} = put("widget", "change", "W-1", %{"designed" => "new", "known" => true}, link)
    assert {"stored", _} = put("part", "create", "P-1", %{"title" => "Part"}, link)
  end

  test "a concurrent subject write cannot slip between guard and link mutation", %{rela: rela, race: race} do
    assert {"stored", _} = put("widget", "change", "W-1", %{"suggestions" => "old", "designed" => "old"})
    Agent.update(race, fn _ -> true end)
    assert {"refused", _} = put("widget", "change", "W-1", %{}, %{"made_by" => ["M-1"]})
    assert {:ok, fact} = FakeRela.get(rela, "widgets", "W-1")
    assert fact.properties["suggestions"] == "new"
    assert fact.links["made_by"] in [nil, []]
  end
  test "a failed subject read does not permit an acceptance", %{rela: rela, race: race} do
    Agent.update(race, fn _ -> :read_error end)
    assert {class, _} = put("widget", "change", "W-1", %{}, %{"made_by" => ["M-1"]})
    assert class != "stored"
    assert {:ok, fact} = FakeRela.get(rela, "widgets", "W-1")
    assert fact.links["made_by"] in [nil, []]
  end
end


defmodule AtlasPlan.LoadTest do
  # `load-plan` (UC-Atlas-05) against an in-process Control (AtlasAgent.FakeControl).
  use ExUnit.Case, async: true

  alias AtlasAgent.FakeControl

  @fixture Path.expand("../../../e2e/fixtures/scenes.md", __DIR__)

  @kinds [
    %{
      kind: "scene",
      title: "Scene",
      prefix: "SC-Atlas-",
      asks: ~w(title description),
      list_title: "Use cases"
    },
    %{
      kind: "use_case",
      title: "Use case",
      prefix: "UC-Atlas-",
      under: "scene",
      asks: ~w(title description),
      list_title: "Use cases"
    },
    %{
      kind: "issue",
      title: "Issue",
      prefix: "IS-Atlas-",
      under: "use_case",
      asks: ~w(title description stage),
      list_title: "Issues"
    }
  ]

  setup do
    control = FakeControl.start(@kinds)
    client = FakeControl.connect(control)
    on_exit(fn -> AtlasAgent.Client.close(client) end)
    %{control: control, client: client, scenes: File.read!(@fixture)}
  end

  defp load(client, scenes, opts \\ []) do
    test = self()
    result = AtlasPlan.run(client, scenes, %{}, [say: &send(test, {:say, &1})] ++ opts)
    {result, said()}
  end

  defp said do
    receive do
      {:say, line} -> [line | said()]
    after
      0 -> []
    end
  end

  defp tree(control) do
    for kind <- ~w(scene use_case issue),
        f <- FakeControl.facts(control, kind),
        do: {f.key, f.parent, f.values["title"]}
  end

  test "a dry run says what it would create and writes nothing", %{
    control: c,
    client: client,
    scenes: scenes
  } do
    {{:ok, %{dry_run: true, mapping: mapping}}, said} = load(client, scenes, dry_run: true)

    assert FakeControl.writes(c) == []
    assert mapping["SC-Atlas-01"] == "SC-Atlas-01"
    assert hd(said) =~ "To create: 5; already there: 0."
    assert "create  UC-Atlas-01 in SC-Atlas-01  A loaded use case" in said
    assert List.last(said) == "Mapping: every code is the file's own."
  end

  test "the run puts every item under its parent; codes taken are mapped", %{
    control: c,
    client: client,
    scenes: scenes
  } do
    # SC-Atlas-01 is taken by something of someone else's.
    FakeControl.put(c, "scene", %{"title" => "Melle's own"})

    {{:ok, %{created: 5, existing: 0, mapping: mapping}}, said} = load(client, scenes)

    assert mapping["SC-Atlas-01"] == "SC-Atlas-02"
    assert mapping["SC-Atlas-02"] == "SC-Atlas-03"

    assert "  SC-Atlas-01 → SC-Atlas-02" in String.split(
             Enum.find(said, &(&1 =~ "Mapping")),
             "\n"
           )

    assert tree(c) == [
             {"SC-Atlas-01", nil, "Melle's own"},
             {"SC-Atlas-02", nil, "A loaded scene"},
             {"SC-Atlas-03", nil, "A second loaded scene"},
             {"UC-Atlas-01", "SC-Atlas-02", "A loaded use case"},
             {"UC-Atlas-02", "SC-Atlas-03", "A use case in prose"},
             # The codes in its title follow the mapping.
             {"IS-Atlas-01", "UC-Atlas-01",
              "A loaded issue: it names SC-Atlas-03 and UC-Atlas-02, which the loader maps"}
           ]
  end

  test "an item already there is skipped and mapped to it", %{
    control: c,
    client: client,
    scenes: scenes
  } do
    scene = FakeControl.put(c, "scene", %{"title" => "A loaded scene"})
    FakeControl.put(c, "use_case", %{"title" => "A loaded use case"}, scene)

    {{:ok, %{created: 3, existing: 2}}, said} = load(client, scenes)

    assert "exists  SC-Atlas-01  A loaded scene" in said
    assert "exists  UC-Atlas-01 in SC-Atlas-01  A loaded use case" in said
    assert length(FakeControl.facts(c, "scene")) == 2
    assert [{"IS-Atlas-01", "UC-Atlas-01", _}] = for(t <- tree(c), elem(t, 0) =~ "IS-", do: t)
  end

  test "a second run creates nothing", %{control: c, client: client, scenes: scenes} do
    {{:ok, %{created: 5}}, _} = load(client, scenes)
    before = tree(c)
    writes = length(FakeControl.writes(c))

    {{:ok, %{created: 0, existing: 5}}, _} = load(client, scenes)
    assert tree(c) == before
    assert length(FakeControl.writes(c)) == writes
  end
end

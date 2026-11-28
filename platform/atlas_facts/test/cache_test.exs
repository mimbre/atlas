defmodule AtlasFacts.CacheTest do
  use ExUnit.Case, async: false
  alias AtlasBus.Envelope
  alias AtlasFacts.Cache
  alias AtlasFacts.CountingRela
  alias AtlasFacts.Rela
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:atlas_bus, :store, "cache-#{System.unique_integer([:positive])}")
    {:ok, backend} = CountingRela.start_link(300)

    start_supervised!(
      {AtlasFacts.Server,
       model: AtlasFacts.Counting, rela: {CountingRela, backend}, data_dir: dir}
    )

    :ok = AtlasBus.attach("control/cache-#{System.unique_integer([:positive])}")
    %{backend: backend}
  end

  defp request(class, kind, content) do
    envelope = Envelope.new(class, kind)
    :ok = AtlasBus.send(envelope, content)
    id = envelope.id
    assert_receive {:atlas_bus, %Envelope{id: ^id}, answer}, 1_000
    answer
  end

  defp read(kind, content \\ %{}), do: request("read", kind, content)

  # A list carries no versions (rela lists none): the first read of one fact reads its
  # version from rela, once (IS-Atlas-84); then no read of it reaches rela.
  test "every kind is listed once, at start; reads of all kinds then reach rela no more", c do
    lists = for {{:list, _}, n} <- CountingRela.calls(c.backend), do: n
    assert lists == List.duplicate(1, map_size(CountingRela.schema()["entities"]))
    kinds = Map.keys(CountingRela.schema()["entities"])
    CountingRela.reset(c.backend)

    for kind <- kinds, fact <- read(kind)["facts"] do
      assert %{"fact" => %{"version" => "v1"}} = read(kind, %{"key" => fact["key"]})
    end

    assert CountingRela.calls(c.backend) == %{get: 50 * length(kinds)}
    CountingRela.reset(c.backend)

    for kind <- kinds do
      answer = read(kind)
      assert length(answer["facts"]) == 50

      for fact <- answer["facts"] do
        assert %{"fact" => %{"key" => key}} = read(kind, %{"key" => fact["key"]})
        assert key == fact["key"]
      end
    end

    assert length(read("jar", %{"linked" => %{"in_box" => %{"tagged" => "tag-1"}}})["facts"]) == 1
    assert %{"answers" => [_, _]} = read("_page", %{"reads" => [["tag", %{}], ["box", %{}]]})
    assert CountingRela.calls(c.backend) == %{}
  end

  test "a write through Facts changes derived parent answers immediately", _c do
    assert hd(read("box")["facts"])["progress"]["value"] == "packing"

    answer =
      request("fact", "bead", %{
        "op" => "change",
        "key" => "bead-1",
        "values" => %{"phase" => "sealed"}
      })

    refute answer["reasons"]
    assert hd(read("box")["facts"])["progress"]["value"] == "sealed"
  end

  defp indexed_cache do
    backend = {AtlasFacts.FakeRela, AtlasFacts.FakeRela.start()}

    mapping = %{
      "kind" => "cursor",
      "fields" => %{"subject_kind" => "on_kind", "subject_key" => "on_key"}
    }

    description = %{
      "entities" => %{
        "cursor" => %{"plural" => "cursors"},
        "item" => %{"plural" => "items"}
      },
      "relations" => %{}
    }

    {Cache.open(backend, mapping), backend, description}
  end

  defp runs(cache, kind, key) do
    {:ok, facts} = Cache.subject_runs(cache, kind, key)
    Enum.sort(Enum.map(facts, & &1.key))
  end

  defp published_runs(cache, kind, key) do
    Task.async(fn -> Cache.consistently(cache, fn _ -> runs(cache, kind, key) end) end)
    |> Task.await()
  end

  test "run index follows staged creates, both subject fields, and deletes" do
    {cache, backend, description} = indexed_cache()

    assert {:ok, _} =
             Rela.create(backend, "cursors", "R-1", %{"on_kind" => "box", "on_key" => "B-1"}, %{})

    assert {:ok, _} =
             Rela.create(backend, "items", "I-1", %{"on_kind" => "box", "on_key" => "B-1"}, %{})

    assert :ok = Cache.load(cache, description)
    assert :ok = Cache.publish(cache, 1, description)
    Cache.stage(cache)

    assert runs(cache, "box", "B-1") == ["R-1"]

    assert {:ok,
            [%{key: "R-1", properties: %{"on_kind" => "box", "on_key" => "B-1"}, version: nil}]} =
             Cache.subject_runs(cache, "box", "B-1")

    assert runs(cache, "jar", "B-1") == []

    assert {:ok, _} =
             Rela.create(cache, "cursors", "R-2", %{"on_kind" => "box", "on_key" => "B-1"}, %{})

    assert {:ok, _} = Rela.change(cache, "cursors", "R-1", %{"on_kind" => "jar"}, nil, %{})
    assert {:ok, _} = Rela.change(cache, "cursors", "R-1", %{"on_key" => "J-1"}, nil, %{})
    assert runs(cache, "box", "B-1") == ["R-2"]
    assert runs(cache, "jar", "B-1") == []
    assert runs(cache, "jar", "J-1") == ["R-1"]
    assert {:ok, ["R-1"]} = published_runs(cache, "box", "B-1")
    assert {:ok, []} = published_runs(cache, "jar", "J-1")

    assert :ok = Cache.publish(cache, 2, description)
    assert {:ok, ["R-2"]} = published_runs(cache, "box", "B-1")
    assert {:ok, ["R-1"]} = published_runs(cache, "jar", "J-1")
    assert :ok = Rela.delete(cache, "cursors", "R-1", nil)
    assert runs(cache, "jar", "J-1") == []
    assert {:ok, ["R-1"]} = published_runs(cache, "jar", "J-1")
    assert :ok = Cache.publish(cache, 3, description)
    assert {:ok, []} = published_runs(cache, "jar", "J-1")
  end

  test "run index follows refresh and reload and open without a mapping remains usable" do
    {cache, backend, description} = indexed_cache()

    assert {:ok, _} =
             Rela.create(backend, "cursors", "R-1", %{"on_kind" => "box", "on_key" => "B-1"}, %{})

    assert :ok = Cache.load(cache, description)
    assert :ok = Cache.publish(cache, 1, description)
    Cache.stage(cache)

    assert {:ok, _} = Rela.change(backend, "cursors", "R-1", %{"on_key" => "B-2"}, nil, %{})

    assert {:ok, _} =
             Rela.create(backend, "cursors", "R-2", %{"on_kind" => "box", "on_key" => "B-1"}, %{})

    assert {:ok, _} = Cache.refresh(cache, "cursors")
    assert runs(cache, "box", "B-1") == ["R-2"]
    assert runs(cache, "box", "B-2") == ["R-1"]
    assert {:ok, ["R-1"]} = published_runs(cache, "box", "B-1")
    assert :ok = Cache.publish(cache, 2, description)

    assert :ok = Rela.delete(backend, "cursors", "R-1", nil)
    assert {:ok, _} = Cache.refresh(cache, "cursors")
    assert runs(cache, "box", "B-2") == []
    assert :ok = Cache.publish(cache, 3, description)
    assert {:ok, []} = published_runs(cache, "box", "B-2")

    assert {:ok, _} =
             Rela.change(
               backend,
               "cursors",
               "R-2",
               %{"on_kind" => "jar", "on_key" => "J-1"},
               nil,
               %{}
             )

    assert {:ok, _} =
             Rela.create(backend, "cursors", "R-3", %{"on_kind" => "jar", "on_key" => "J-1"}, %{})

    assert :ok = Cache.load(cache, description)
    assert runs(cache, "box", "B-1") == []
    assert runs(cache, "jar", "J-1") == ["R-2", "R-3"]
    assert :ok = Cache.publish(cache, 4, description)
    assert {:ok, ["R-2", "R-3"]} = published_runs(cache, "jar", "J-1")

    plain = Cache.open(backend)
    assert :ok = Cache.load(plain, description)
    assert :ok = Cache.publish(plain, 1, description)
    assert {:ok, []} = Cache.subject_runs(plain, "box", "B-1")
    assert {:ok, facts} = Rela.list(plain, "cursors")
    assert Enum.sort(Enum.map(facts, & &1.key)) == ["R-2", "R-3"]
  end

  defp linked_keys(cache, plural, relation, targets) do
    {:ok, facts} = Cache.linked(cache, plural, relation, targets)
    Enum.map(facts, & &1.key)
  end

  defp published_links(cache, plural, relation, targets) do
    Task.async(fn ->
      Cache.consistently(cache, fn _ -> linked_keys(cache, plural, relation, targets) end)
    end)
    |> Task.await()
  end

  test "linked index tracks staged writes, published reads, refresh and reload" do
    {cache, backend, description} = indexed_cache()

    for key <- ["A", "B", "C"] do
      assert {:ok, _} = Rela.create(backend, "items", key, %{}, %{})
    end

    assert {:ok, _} =
             Rela.create(backend, "cursors", "R-1", %{}, %{"of" => {"item", ["A"]}})

    assert {:ok, _} =
             Rela.create(backend, "items", "I-1", %{}, %{"of" => {"item", ["A"]}})

    assert :ok = Cache.load(cache, description)
    assert :ok = Cache.publish(cache, 1, description)
    Cache.stage(cache)

    assert linked_keys(cache, "cursors", "of", ["A"]) == ["R-1"]
    assert linked_keys(cache, "items", "of", ["A"]) == ["I-1"]
    assert linked_keys(cache, "cursors", "other", ["A"]) == []
    assert linked_keys(cache, "cursors", "of", []) == []

    assert {:ok, _} =
             Rela.change(cache, "cursors", "R-1", %{}, nil, %{"of" => {"item", ["B"]}})

    assert {:ok, _} =
             Rela.create(cache, "cursors", "R-2", %{}, %{"of" => {"item", ["A", "B"]}})

    assert linked_keys(cache, "cursors", "of", ["A", "B", "A"]) == ["R-1", "R-2"]
    assert linked_keys(cache, "cursors", "of", ["A"]) == ["R-2"]
    assert {:ok, ["R-1"]} = published_links(cache, "cursors", "of", ["A"])
    assert {:ok, []} = published_links(cache, "cursors", "of", ["B"])
    assert :ok = Cache.publish(cache, 2, description)
    assert {:ok, ["R-1", "R-2"]} = published_links(cache, "cursors", "of", ["B"])

    assert :ok = Rela.delete(cache, "cursors", "R-1", nil)
    assert linked_keys(cache, "cursors", "of", ["B"]) == ["R-2"]
    assert {:ok, ["R-1", "R-2"]} = published_links(cache, "cursors", "of", ["B"])
    assert :ok = Cache.publish(cache, 3, description)

    assert {:ok, _} =
             Rela.change(backend, "cursors", "R-2", %{}, nil, %{"of" => {"item", ["C"]}})

    assert {:ok, _} = Cache.refresh(cache, "cursors")
    assert linked_keys(cache, "cursors", "of", ["A", "B"]) == []
    assert linked_keys(cache, "cursors", "of", ["C"]) == ["R-2"]
    assert {:ok, ["R-2"]} = published_links(cache, "cursors", "of", ["A"])
    assert :ok = Cache.publish(cache, 4, description)

    assert {:ok, _} =
             Rela.change(backend, "cursors", "R-2", %{}, nil, %{"of" => {"item", ["A"]}})

    assert :ok = Cache.load(cache, description)
    assert linked_keys(cache, "cursors", "of", ["C"]) == []
    assert linked_keys(cache, "cursors", "of", ["A"]) == ["R-2"]
    assert :ok = Cache.publish(cache, 5, description)
    assert {:ok, ["R-2"]} = published_links(cache, "cursors", "of", ["A"])
  end
end

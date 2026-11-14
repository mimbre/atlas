defmodule AtlasFacts.WriteVisibilityTest do
  use ExUnit.Case, async: false
  alias AtlasBus.Envelope
  alias AtlasFacts.CountingRela
  @moduletag :tmp_dir

  defmodule Replacing do
    @moduledoc "The counting kinds, where a sealed stamp replaces the open stamps it supersedes."
    use AtlasFacts.TestModel,
      description:
        AtlasFacts.CountingRela.schema()
        |> put_in(["entities", "stamp", "replaces"], %{
          "relation" => "supersedes",
          "when" => %{"status" => ["sealed"]},
          "of" => %{"status" => ["open"]},
          "set" => %{"status" => "replaced"}
        })
        |> put_in(["relations", "supersedes"], %{"from" => ["stamp"], "to" => ["stamp"]})
  end

  setup %{tmp_dir: dir} do
    Application.put_env(:atlas_bus, :store, "visibility-#{System.unique_integer([:positive])}")
    {:ok, backend} = CountingRela.start_link(12, schema: Replacing.rela_schema())

    server =
      start_supervised!(
        {AtlasFacts.Server,
         rela: {CountingRela, backend},
         model: Replacing,
         data_dir: dir,
         collection_clock: fn -> CountingRela.clock(backend) end}
      )

    :ok = AtlasBus.attach("control/session-visibility-#{System.unique_integer([:positive])}")
    %{backend: backend, server: server}
  end

  defp request(class, kind, content) do
    e = Envelope.new(class, kind)
    :ok = AtlasBus.send(e, content)
    # Routing is asynchronous; visibility is checked after the correlated reply.
    assert_receive {:atlas_bus, %Envelope{id: id}, answer} when id == e.id, 1_000
    answer
  end

  defp read(kind), do: request("read", kind, %{})["facts"]
  defp point(kind, key), do: request("read", kind, %{"key" => key, "plain" => true})["fact"]

  defp write(kind, op, key, values \\ %{}, links \\ %{}),
    do: request("fact", kind, %{"op" => op, "key" => key, "values" => values, "links" => links})

  test "create and delete expose both the parent and its component before acknowledgement" do
    read("box")
    read("tag")
    refute write("box", "create", "box-new", %{"phase" => "packing"})["reasons"]
    assert point("box", "box-new")["links"]["tagged"] == ["T-box-new"]
    assert Enum.any?(read("tag"), &(&1["key"] == "T-box-new"))
    refute write("box", "delete", "box-new")["reasons"]
    assert point("box", "box-new") == nil
    assert point("tag", "T-box-new") == nil
    refute Enum.any?(read("tag"), &(&1["key"] == "T-box-new"))
  end

  test "partial component creation is rolled back before a failed parent reply", c do
    read("box")
    read("tag")
    Agent.update(c.backend, &Map.put(&1, :create_errors, %{{"boxes", "box-new"} => :unavailable}))
    assert write("box", "create", "box-new")["reasons"]
    assert point("box", "box-new") == nil
    assert point("tag", "T-box-new") == nil
    refute Enum.any?(read("tag"), &(&1["key"] == "T-box-new"))
  end

  test "replacement writes expose changes to both rows" do
    read("stamp")

    refute write("stamp", "create", "stamp-new", %{"status" => "sealed"}, %{
             "supersedes" => ["stamp-1"]
           })["reasons"]

    assert point("stamp", "stamp-1")["values"]["status"] == "replaced"
    assert Enum.find(read("stamp"), &(&1["key"] == "stamp-1"))["values"]["status"] == "replaced"
  end

  test "link replacement and removal expose the new derived owner answers" do
    read("jar")
    read("box")
    refute write("jar", "change", "jar-1", %{}, %{"in_box" => ["box-2"]})["reasons"]
    assert point("jar", "jar-1")["links"]["in_box"] == ["box-2"]
    refute write("jar", "change", "jar-1", %{}, %{"in_box" => []})["reasons"]
    assert point("jar", "jar-1")["links"]["in_box"] == []
    assert Enum.find(read("box"), &(&1["key"] == "box-1"))["progress"] == nil
  end

  test "delete exposes backend cleanup of incoming links in another collection" do
    read("bead")
    read("stamp")
    refute write("stamp", "delete", "stamp-1")["reasons"]
    assert point("bead", "bead-1")["links"]["sealed_by"] == []
    assert point("stamp", "stamp-1") == nil
  end

  test "committed warnings and lost responses cannot leave old answers", c do
    read("bead")

    for reply <- [{:ok, ["stored with warnings"]}, {:error, :unavailable}] do
      Agent.update(c.backend, &Map.put(&1, :write_reply, reply))
      write("bead", "change", "bead-1", %{"phase" => inspect(reply)})
      assert point("bead", "bead-1")["values"]["phase"] == inspect(reply)
      assert hd(read("bead"))["values"]["phase"] == inspect(reply)
    end
  end

  test "direct create, property/link changes and delete appear without advancing the clock", c do
    read("jar")
    read("box")

    assert {:ok, []} =
             CountingRela.create(c.backend, "jars", "outside", %{"phase" => "packing"}, %{})

    :ok = AtlasFacts.Server.flush_collections(c.server)

    assert point("jar", "outside")["key"] == "outside"
    assert Enum.any?(read("jar"), &(&1["key"] == "outside"))

    assert {:ok, []} =
             CountingRela.change(c.backend, "jars", "jar-1", %{"phase" => "sealed"}, nil, %{
               "in_box" => {"box", ["box-2"]}
             })

    :ok = AtlasFacts.Server.flush_collections(c.server)
    assert point("jar", "jar-1")["values"]["phase"] == "sealed"
    assert point("jar", "jar-1")["links"]["in_box"] == ["box-2"]
    assert :ok = CountingRela.delete(c.backend, "boxes", "box-2", nil)
    :ok = AtlasFacts.Server.flush_collections(c.server)
    assert point("jar", "jar-1")["links"]["in_box"] == []
    assert point("box", "box-2") == nil
    refute Enum.any?(read("box"), &(&1["key"] == "box-2"))
    assert CountingRela.clock(c.backend) == 0
  end

  test "backend errors after warming are visible to both point and collection reads", c do
    read("jar")
    Agent.update(c.backend, &%{&1 | down: true})
    :ok = AtlasFacts.Server.flush_collections(c.server)

    for content <- [%{}, %{"key" => "jar-1", "plain" => true}] do
      assert %{"error_kind" => "unreachable"} = request("read", "jar", content)
    end
  end

  test "a Facts write evicts unrelated copies and is visible in later requests", c do
    read("jar")
    read("clerk")
    CountingRela.reset(c.backend)
    refute write("jar", "change", "jar-1", %{"phase" => "sealed"})["reasons"]
    # One read of the fact as it was, for what the hint says changed (its links too).
    assert CountingRela.calls(c.backend) == %{get: 1, change: 1}
    assert hd(read("jar"))["values"]["phase"] == "sealed"
    read("clerk")
    assert CountingRela.calls(c.backend)[{:list, "clerks"}] == 1
    CountingRela.reset(c.backend)
    assert hd(read("jar"))["values"]["phase"] == "sealed"
    assert CountingRela.calls(c.backend) == %{}
  end

  test "point reads that need a version bypass a warmed collection", c do
    read("jar")
    CountingRela.reset(c.backend)
    assert point("jar", "jar-1")["version"] == "v1"
    assert request("read", "jar", %{"key" => "jar-1"})["fact"]["version"] == "v1"
    assert CountingRela.calls(c.backend)[:get] >= 2
  end
end

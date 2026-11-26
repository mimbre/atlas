defmodule AtlasPlan.ProducerTest do
  use ExUnit.Case, async: true

  alias AtlasPlan.Producer

  @people ["melle", "adrienne", "bob"]
  @assists %{"coordinator" => "melle", "breaker" => nil}

  defp entry(position, by, cause \\ nil),
    do: %{"position" => position, "by" => by, "cause" => cause, "since" => "2026-10-01T10:00:00Z"}

  describe "the write that made an item" do
    test "is the oldest entry of the links its create sets, not a later change" do
      history = %{
        "in_scene" => [
          entry(7, "flow", "For adrienne: proposed by TK-SC-Atlas-03-1"),
          entry(30, "bob")
        ],
        "assignment" => [entry(12, "migration", "owner introduced")],
        "accepted_by" => [entry(3, "bob")]
      }

      assert %{"position" => 7, "by" => "flow"} = Producer.made("use_case", history)
    end

    test "is nil when Facts records none of those links" do
      assert Producer.made("scene", %{"accepted_by" => [entry(3, "bob")]}) == nil
      assert Producer.made("issue", nil) == nil
    end
  end

  describe "whom it chooses" do
    test "an item Flow made: the supervisor its cause names" do
      made =
        entry(
          1,
          "flow",
          "For adrienne: proposed by TK-UC-Atlas-05-1 in the break-down of UC-Atlas-05"
        )

      assert Producer.choose(made, @people, @assists, "melle") == {"adrienne", :flow}

      review =
        entry(1, "flow", "For bob: proposed by TK-IS-Atlas-40-2 in the review of IS-Atlas-40")

      assert Producer.choose(review, @people, @assists, "melle") == {"bob", :flow}
    end

    test "an item made by hand: the person who created it" do
      assert Producer.choose(entry(1, "adrienne"), @people, @assists, "melle") ==
               {"adrienne", :by_hand}
    end

    test "an item an agent made: the person the agent assists, or whom its cause names" do
      assert Producer.choose(entry(1, "coordinator", "Wrap it"), @people, @assists, "bob") ==
               {"melle", :assisting}

      on_behalf = entry(1, "dev1", "Put in by dev1 on behalf of adrienne")

      assert Producer.choose(on_behalf, @people, @assists, "melle") ==
               {"adrienne", :on_behalf}
    end

    test "nothing known: the configured decider" do
      for made <- [
            nil,
            entry(1, "migration", "load plan"),
            entry(1, "connector/github"),
            entry(1, "breaker"),
            entry(1, "flow", "Flow Design: no one named"),
            entry(1, "flow", "For ghost: proposed by TK-1"),
            entry(1, nil)
          ] do
        assert Producer.choose(made, @people, @assists, "bob") == {"bob", :unknown},
               inspect(made)
      end
    end
  end

  test "each cause says it was backfilled and from what" do
    flow = entry(1, "flow", "For adrienne: proposed by TK-1")

    assert Producer.cause({"adrienne", :flow}, flow) ==
             ~s|backfilled (UC-Atlas-23): made by flow, "For adrienne: proposed by TK-1": adrienne|

    assert Producer.cause({"adrienne", :by_hand}, entry(1, "adrienne")) =~
             "backfilled (UC-Atlas-23): put in by adrienne by hand"

    assert Producer.cause({"melle", :assisting}, entry(1, "coordinator")) =~
             "put in by coordinator, who assists melle"

    assert Producer.cause({"bob", :unknown}, nil) =~
             "its history names nobody who made it: the configured decider, bob"

    assert Producer.cause({"bob", :unknown}, entry(1, "migration")) =~ "(made by migration)"
  end

  # Facts as the migration reads it through Control: a list per kind, a full read per fact.
  defp store(items) do
    store = Agent.start_link(fn -> items end) |> elem(1)

    read = fn
      "person", nil ->
        {:ok, %{"facts" => Enum.map(@people, &%{"key" => &1})}}

      kind, nil ->
        facts =
          for {{^kind, key}, item} <- Agent.get(store, & &1),
              do: %{"key" => key, "links" => item.links}

        {:ok, %{"facts" => facts}}

      kind, key ->
        item = Agent.get(store, &Map.fetch!(&1, {kind, key}))
        {:ok, %{"fact" => %{"key" => key, "links" => item.links}, "history" => item.history}}
    end

    write = fn key, links, cause ->
      Agent.update(store, fn all ->
        {{kind, ^key}, item} = Enum.find(all, fn {{_, k}, _} -> k == key end)

        Map.put(all, {kind, key}, %{
          item
          | links: Map.merge(item.links, Map.new(links, fn {r, p} -> {r, [p]} end)),
            history:
              Map.update(
                item.history,
                "produced_by",
                [%{"cause" => cause}],
                &(&1 ++ [%{"cause" => cause}])
              )
        })
      end)

      {:ok, key}
    end

    {store, read, write}
  end

  defp item(links, history), do: %{links: links, history: history}

  test "a run links each item without a producer; a second run changes nothing" do
    {store, read, write} =
      store(%{
        {"scene", "SC-Atlas-01"} => item(%{}, %{"assignment" => [entry(1, "adrienne")]}),
        {"scene", "SC-Atlas-02"} => item(%{"produced_by" => ["bob"]}, %{}),
        {"use_case", "UC-Atlas-03"} =>
          item(%{"in_scene" => ["SC-Atlas-01"]}, %{
            "in_scene" => [entry(5, "flow", "For bob: proposed by TK-SC-Atlas-01-1")]
          }),
        {"issue", "IS-Atlas-04"} =>
          item(%{"in_use_case" => ["UC-Atlas-03"]}, %{"in_use_case" => [entry(9, "coordinator")]}),
        {"issue", "IS-Atlas-05"} => item(%{}, %{})
      })

    lines = fn -> Process.get(:lines, []) end
    say = fn line -> Process.put(:lines, lines.() ++ [line]) end
    opts = [assists: @assists, decider: "melle", read: read, write: write, say: say]

    assert {:ok, %{steps: steps, written: 0}} = Producer.run(nil, [dry_run: true] ++ opts)
    assert length(steps) == 4
    assert Enum.any?(lines.(), &(&1 == "Dry run: nothing was written."))
    assert Agent.get(store, &get_in(&1, [{"scene", "SC-Atlas-01"}, Access.key(:links)])) == %{}

    assert {:ok, %{written: 4}} = Producer.run(nil, opts)

    producers =
      Agent.get(store, fn all ->
        Map.new(all, fn {{_, key}, item} -> {key, item.links["produced_by"]} end)
      end)

    assert producers == %{
             "SC-Atlas-01" => ["adrienne"],
             "SC-Atlas-02" => ["bob"],
             "UC-Atlas-03" => ["bob"],
             "IS-Atlas-04" => ["melle"],
             "IS-Atlas-05" => ["melle"]
           }

    # Every backfilled link's origin says so, and from what.
    for key <- ["SC-Atlas-01", "UC-Atlas-03", "IS-Atlas-04", "IS-Atlas-05"] do
      [%{"cause" => cause}] =
        Agent.get(store, fn all ->
          Enum.find_value(all, fn {{_, k}, i} -> k == key && i.history["produced_by"] end)
        end)

      assert cause =~ "backfilled (UC-Atlas-23)", key
    end

    assert {:ok, %{steps: [], written: 0}} = Producer.run(nil, opts)
  end

  test "it refuses to run without a decider who is a person" do
    {_store, read, write} = store(%{})
    opts = [read: read, write: write, say: fn _ -> :ok end]
    assert {:error, "no decider"} = Producer.run(nil, opts)

    assert {:error, "the configured decider ghost is no person"} =
             Producer.run(nil, [decider: "ghost"] ++ opts)
  end

  test "a refused write stops the run and says which" do
    {_store, read, _write} =
      store(%{{"scene", "SC-Atlas-01"} => item(%{}, %{})})

    write = fn _key, _links, _cause ->
      {:refused, ["only a flow or migration sets produced_by"]}
    end

    opts = [decider: "melle", read: read, write: write, say: fn _ -> :ok end]

    assert {:error, text} = Producer.run(nil, opts)
    assert text =~ "link SC-Atlas-01  produced_by melle"
    assert text =~ "refused: only a flow or migration sets produced_by"
  end
end

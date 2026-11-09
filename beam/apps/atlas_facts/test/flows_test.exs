defmodule AtlasFacts.FlowsTest do
  use ExUnit.Case, async: true

  alias AtlasFacts.Flows

  @root Path.expand("../../../..", __DIR__)

  # Made-up kinds: a box holds crates; a box is signed off.
  defp description(states, extra \\ %{}) do
    %{
      "entities" => %{
        "box" => %{"properties" => %{"todo" => %{"type" => "string"}}},
        "crate" => %{"properties" => %{}}
      },
      "relations" => %{"signed_by" => %{"from" => ["box"], "to" => ["clerk"]}},
      "flows" => %{
        "sign" => Map.merge(%{"kinds" => ["box"], "field" => "todo", "states" => states}, extra)
      }
    }
  end

  @sound [
    %{"name" => "done", "when" => %{"completed" => true}, "done" => true},
    %{
      "name" => "check",
      "when" => %{"progress" => "check"},
      "owner" => "ada",
      "next" => ["done"]
    },
    %{"name" => "work", "owner" => "bob", "next" => ["check"]}
  ]

  test "a sound definition has no problems" do
    assert Flows.check(description(@sound)) == %{"sign" => []}
  end

  test "every state that is not done has an owner and a way out to a state that exists" do
    states = [
      hd(@sound),
      %{"name" => "check", "when" => %{"progress" => "check"}, "next" => ["nowhere"]},
      %{"name" => "work", "owner" => "bob"}
    ]

    assert %{"sign" => problems} = Flows.check(description(states))
    assert "check has no owner" in problems
    assert ~s(check: its next "nowhere" is no state) in problems
    assert "work has no way out (next)" in problems
  end

  test "every state reaches done; there is a done state; the last holds when no other does" do
    loop = [
      hd(@sound),
      %{"name" => "a", "when" => %{"progress" => "x"}, "owner" => "ada", "next" => ["b"]},
      %{"name" => "b", "owner" => "bob", "next" => ["a"]}
    ]

    assert %{"sign" => problems} = Flows.check(description(loop))
    assert "a never reaches done" in problems
    assert "b never reaches done" in problems

    no_done = [
      %{"name" => "work", "when" => %{"progress" => "x"}, "owner" => "bob", "next" => ["work"]}
    ]

    assert %{"sign" => problems} = Flows.check(description(no_done))
    assert "has no done state" in problems
    assert "the last state, work, must hold when no other does (no when)" in problems
  end

  test "what a definition names must exist" do
    assert %{"sign" => problems} =
             Flows.check(
               description(@sound, %{
                 "kinds" => ["box", "crate", "lid"],
                 "owner_relation" => "signed_by"
               })
             )

    assert "crate has no todo to write what is expected" in problems
    assert "lid is not described" in problems
    assert "signed_by does not start at crate" in problems

    odd = [%{hd(@sound) | "when" => %{"colour" => "red"}} | tl(@sound)]
    assert %{"sign" => ["done: when knows no colour"]} = Flows.check(description(odd))
  end

  test "no state depends on what Flow writes: it passes over the hints of its own writes" do
    states = [
      hd(@sound),
      %{
        "name" => "check",
        "when" => %{"reopened" => "signed_by"},
        "owner" => "ada",
        "next" => ["done"]
      },
      %{"name" => "work", "owner" => "bob", "next" => ["check"]}
    ]

    description =
      description(states, %{"owner_relation" => "signed_by"})
      |> put_in(["entities", "box", "progress"], %{"own" => "todo"})

    assert %{"sign" => problems} = Flows.check(description)
    assert "check depends on signed_by, which Flow writes" in problems
    assert "box's progress or completion depends on todo, which Flow writes" in problems
  end

  # A box has a card, made with it; Flow writes on the card.
  defp on_card(description) do
    description
    |> put_in(["entities", "card"], %{"properties" => %{"todo" => %{"type" => "string"}}})
    |> update_in(["entities", "box", "properties"], &Map.delete(&1, "todo"))
    |> put_in(["relations", "card"], %{"from" => ["box"], "to" => ["card"], "max_outgoing" => 1})
    |> put_in(["relations", "signed_by", "from"], ["card"])
  end

  # With an owner relation, each owner names its kind.
  defp owned(states, kind) do
    for state <- states,
        do:
          if(state["owner"],
            do: %{state | "owner" => %{"kind" => kind, "key" => state["owner"]}},
            else: state
          )
  end

  test "with on, Flow writes on the fact that relation points at, and is checked there" do
    description =
      on_card(
        description(owned(@sound, "clerk"), %{"on" => "card", "owner_relation" => "signed_by"})
      )

    assert Flows.check(description) == %{"sign" => []}

    # Without on, the box has no todo, and signed_by does not start at it.
    plain = put_in(description, ["flows", "sign", "on"], nil)
    assert %{"sign" => problems} = Flows.check(plain)
    assert "box has no todo to write what is expected" in problems
    assert "signed_by does not start at box" in problems

    many =
      put_in(description, ["relations", "card"], %{"from" => ["crate"], "to" => ["card", "box"]})

    assert %{"sign" => problems} = Flows.check(many)
    assert "card does not start at box" in problems
    assert "card must point at one kind" in problems
    assert "card must allow one link" in problems

    # A rule of the card that reads what Flow writes there, or of the box through card.
    carded = put_in(description, ["entities", "card", "progress"], %{"own" => "todo"})
    assert %{"sign" => [problem]} = Flows.check(carded)
    assert problem == "card's progress or completion depends on todo, which Flow writes"

    through = %{"through" => "card", "field" => "todo", "value" => "x"}
    boxed = put_in(description, ["entities", "box", "completion"], through)
    assert %{"sign" => [problem]} = Flows.check(boxed)
    assert problem == "box's progress or completion depends on todo, which Flow writes"
  end

  # Resolve the selected native include closure instead of scraping a flat YAML file.
  # Only this repository test reads local configuration; the running layers use the Bus.
  defp rela_half(_extra) do
    python = System.get_env("ATLAS_CONFIG_PYTHON") || "python3"

    {json, code} =
      System.cmd(python, [Path.join(@root, "rela/scripts/config.py"), "resolved"],
        stderr_to_stdout: true
      )

    assert code == 0, json
    JSON.decode!(json)
  end

  test "with an owner relation, each owner names its kind, one the relation allows" do
    description = description(owned(@sound, "clerk"), %{"owner_relation" => "signed_by"})
    description = put_in(description, ["relations", "signed_by", "from"], ["box"])
    assert Flows.check(description) == %{"sign" => []}

    wrong = description(owned(@sound, "robot"), %{"owner_relation" => "signed_by"})
    assert %{"sign" => problems} = Flows.check(wrong)
    assert "check: signed_by does not allow its owner's kind, robot" in problems

    bare = description(@sound, %{"owner_relation" => "signed_by"})
    assert %{"sign" => problems} = Flows.check(bare)
    assert "work: its owner names no kind (owner: {kind, key})" in problems
  end

  test "values: a condition on a property's values, never on one Flow writes" do
    states = [
      %{
        "name" => "done",
        "when" => %{"values" => %{"state" => ["merged", "closed"]}},
        "done" => true
      },
      %{"name" => "open", "owner" => "bob", "next" => ["done"]}
    ]

    assert Flows.check(description(states)) == %{"sign" => []}

    on_todo = [%{hd(states) | "when" => %{"values" => %{"todo" => ["x"]}}} | tl(states)]

    assert %{"sign" => ["done depends on todo, which Flow writes"]} =
             Flows.check(description(on_todo))
  end

  test "empty names a parent relation that puts something under the flow's kinds" do
    split = fn relation ->
      [
        hd(@sound),
        %{
          "name" => "split",
          "when" => %{"empty" => relation},
          "owner" => "ada",
          "next" => ["work"]
        }
        | tl(@sound)
      ]
    end

    parented = %{"in_box" => %{"from" => ["crate"], "to" => ["box"], "parent" => true}}
    good = put_in(description(split.("in_box")), ["relations"], parented)
    assert Flows.check(good) == %{"sign" => []}

    for relation <- ["signed_by", "in_nothing"] do
      assert %{"sign" => [problem]} =
               Flows.check(
                 put_in(
                   description(split.(relation)),
                   ["relations", "in_box"],
                   parented["in_box"]
                 )
               )

      assert problem == "split: empty names #{relation}, which puts nothing under its kinds"
    end
  end

  # Resolves the native schema with rela/scripts/config.py (Python with PyYAML).
  @tag :integration
  test "the definitions in rela/atlas.json are sound" do
    extra = @root |> Path.join("rela/atlas.json") |> File.read!() |> JSON.decode!()
    assert map_size(extra["flows"]) > 0
    description = AtlasFacts.Description.merge(rela_half(extra), extra)

    assert Enum.all?(Flows.check(description), fn {_name, problems} -> problems == [] end),
           inspect(Flows.check(description))
  end
end

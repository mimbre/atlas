defmodule RelaDSL.Facts.DeciderTest do
  use ExUnit.Case, async: true
  alias RelaDSL.Facts.Writes

  @fingerprint %{"fields" => ["title", "weight"], "relations" => ["overturns"]}
  @config %{
    "gate" => "allocate",
    "relation" => "about",
    "kind" => "ruling",
    "fingerprint" => @fingerprint
  }
  @authority %{
    "when" => %{"state" => ["final"]},
    "writes" => %{"state" => ["final", "dropped"]},
    "by" => "ruled_by",
    "kind" => "judge",
    "agent_kind" => "clerk",
    "decider" => @config
  }

  # A subject's fingerprint, as a store gives the rules one: its deciding fields and
  # relation keys, digested.
  defp fingerprint(fact, spec) do
    :erlang.phash2({
      Map.new(spec["fields"] || [], &{&1, get_in(fact, ["values", &1])}),
      Map.new(spec["relations"] || [], &{&1, Enum.sort(List.wrap(get_in(fact, ["links", &1])))})
    })
  end

  defp check(outcome, actor, changes, opts \\ []) do
    current = %{
      "values" => %{"title" => "A", "weight" => "light", "state" => "draft"},
      "links" => %{"ruled_by" => [actor], "overturns" => ["R-0"]}
    }

    verdict =
      if outcome,
        do: %{"verdict" => outcome, "fingerprint" => fingerprint(current, @fingerprint)}

    env = %{
      "writer" => Keyword.get(opts, :writer, actor),
      "kind_of" => fn _, key -> if(key == "J", do: "judge", else: "clerk") end,
      "verdict" => fn "allocate", "R-1" -> verdict end,
      "fingerprint" => &fingerprint/2
    }

    Writes.check_rules(
      %{"authority" => @authority},
      "change",
      "R-1",
      current,
      Map.merge(%{"state" => Keyword.get(opts, :state, "final")}, changes),
      Keyword.get(opts, :links, %{}),
      env
    )
  end

  test "every authority row admits the primary kind; only the two agent verdicts admit an agent" do
    for outcome <- [nil, "person_always", "ask", "agent", "agent_unverified", "unknown"] do
      for state <- ["final", "dropped"] do
        assert check(outcome, "J", %{}, state: state) == :ok

        if outcome in ["agent", "agent_unverified"] do
          assert check(outcome, "C", %{}, state: state) == :ok
        else
          assert {:refused, _} = check(outcome, "C", %{}, state: state)
        end
      end
    end
  end

  test "editing deciding fields or relation keys in the acceptance makes authority stale" do
    assert {:refused, _} = check("agent", "C", %{"title" => "Edited"})
    assert {:refused, _} = check("agent", "C", %{}, links: %{"overturns" => ["R-2"]})
    assert check("agent", "J", %{"title" => "Edited"}) == :ok
    assert {:refused, _} = check("agent", "C", %{}, writer: "J")
  end

  test "lookup binds gate, purpose, subject and relation, then selects newest deterministically" do
    row = fn key, values, links ->
      %{
        key: key,
        properties:
          Map.merge(
            %{
              "gate" => "allocate",
              "purpose" => "decider",
              "subject" => "R-1",
              "decided_at" => "2026-11-12T00:00:00Z",
              "verdict" => "agent"
            },
            values
          ),
        links: links
      }
    end

    about = %{"about" => ["R-1"]}
    valid = row.("V-1", %{}, about)
    newest = row.("V-2", %{"verdict" => "ask"}, about)

    irrelevant = [
      row.("V-9", %{"gate" => "other"}, about),
      row.("V-8", %{"purpose" => "flow"}, about),
      row.("V-7", %{"subject" => "R-2"}, about),
      row.("V-6", %{}, %{})
    ]

    assert Writes.newest([valid, newest | irrelevant], "allocate", "R-1", "about") ==
             newest.properties

    assert Writes.newest(irrelevant, "allocate", "R-1", "about") == nil

    assert Writes.newest(
             [valid, row.("V-3", %{"fingerprint" => "stale"}, about)],
             "allocate",
             "R-1",
             "about"
           )["fingerprint"] == "stale"
  end
end

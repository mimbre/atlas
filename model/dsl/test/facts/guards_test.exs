defmodule RelaDSL.Facts.GuardsTest do
  use ExUnit.Case, async: true

  alias RelaDSL.Facts.Writes

  # Made-up kinds and rules: a ruling, decided by a judge or a clerk, that a newer one
  # overturns. Facts must not care what they are called.
  @rules %{
    "requires" => [
      %{"when" => %{"weight" => ["heavy"]}, "fields" => ["check"], "error" => "needs check"}
    ],
    "authority" => %{
      "when" => %{"state" => ["final"]},
      "by" => "ruled_by",
      "kind" => "judge",
      "only_kind_when" => [%{"weight" => ["heavy"]}, %{"area" => ["money"]}],
      "delegated_by" => "under",
      "error" => "not this one's to decide",
      "writes" => %{"state" => ["final", "dropped"]},
      "writer_error" => "only who rules it decides it"
    },
    "layering" => %{
      "relation" => "rests_on",
      "field" => "level",
      "not" => %{"top" => ["middle", "bottom"], "middle" => ["bottom"]},
      "error" => "{key} ({value}) may not rest on {other} ({other_value})"
    },
    "frozen" => %{
      "when" => %{"state" => ["final", "overturned"]},
      "only" => %{"state" => ["overturned"]},
      "tallied" => ["cited"],
      "error" => "{key} is {value}"
    },
    "replaces" => %{
      "relation" => "overturns",
      "when" => %{"state" => ["final"]},
      "of" => %{"state" => ["final", "overturned"]},
      "set" => %{"state" => "overturned"},
      "error" => "{key} is not final"
    }
  }

  @kinds %{"J-1" => "judge", "C-1" => "clerk"}
  defp kind_of(_relation, key), do: @kinds[key]

  # A subject's fingerprint, as a store gives the rules one: its deciding fields and
  # relation keys, digested.
  defp fingerprint(fact, spec) do
    :erlang.phash2({
      Map.new(spec["fields"] || [], &{&1, get_in(fact, ["values", &1])}),
      Map.new(spec["relations"] || [], &{&1, Enum.sort(List.wrap(get_in(fact, ["links", &1])))})
    })
  end

  # Who writes: the judge, unless a test says otherwise; it is the one rulings name.
  defp check(op, current, values, links \\ %{}, others \\ %{}, env \\ %{}) do
    writer =
      Enum.at(List.wrap(links["ruled_by"] || get_in(current || %{}, ["links", "ruled_by"])), 0)

    env = Map.merge(%{"writer" => writer, "kind_of" => &kind_of/2, "fetch" => &others[&1]}, env)
    Writes.check_rules(@rules, op, "R-2", current, values, links, env)
  end

  defp final(extra \\ %{}),
    do: %{"values" => Map.merge(%{"title" => "T", "state" => "final"}, extra), "links" => %{}}

  test "the rules of a kind are read from its description; a kind without any has none" do
    description = %{"entities" => %{"ruling" => Map.put(@rules, "plural", "rulings")}}
    assert Writes.rules(description, "ruling") == @rules
    assert Writes.rules(description, "other") == %{}
    assert Writes.check_rules(%{}, "delete", "X", final(), %{}, %{}, %{}) == :ok
  end

  test "a final fact is never deleted, and a change may only overturn it" do
    assert {:refused, ["R-2 is final"]} = check("delete", final(), %{})
    assert {:refused, ["R-2 is final"]} = check("change", final(), %{"title" => "Other"})
    assert {:refused, _} = check("change", final(), %{"state" => "open"})
    assert {:refused, _} = check("change", final(), %{}, %{"ruled_by" => ["C-1"]})
    assert :ok = check("change", final(), %{"state" => "overturned"})
    # Sending what is there already changes nothing, so it is no edit.
    assert :ok = check("change", final(), %{"state" => "overturned", "title" => "T"})

    overturned = %{"values" => %{"title" => "T", "state" => "overturned"}, "links" => %{}}
    assert {:refused, ["R-2 is overturned"]} = check("change", overturned, %{"title" => "New"})
  end

  test "a frozen fact still takes any value of a tallied field, and nothing else with it" do
    overturned = %{"values" => %{"title" => "T", "state" => "overturned"}, "links" => %{}}
    assert :ok = check("change", overturned, %{"cited" => 3})
    assert :ok = check("change", overturned, %{"cited" => 0, "state" => "overturned"})

    assert {:refused, ["R-2 is overturned"]} =
             check("change", overturned, %{"cited" => 1, "title" => "X"})

    assert {:refused, ["R-2 is overturned"]} = check("delete", overturned, %{})
  end

  test "a frozen tally is written through the full guard by Flow alone" do
    description = %{
      "entities" => %{
        "ruling" => %{
          "frozen" => @rules["frozen"],
          "properties" => %{"cited" => %{"set_by" => ["flow"]}}
        }
      },
      "flow_runtime" => %{"writer" => %{"by" => "flow", "sender" => "flow"}}
    }

    current = final(%{"cited" => 2})
    lookup = %{"current" => fn -> current end}
    flow = %{"by" => "flow", "sender" => "flow"}
    human = %{"by" => "human", "sender" => "control/session"}
    spoofed = %{"by" => "flow", "sender" => "control/session"}

    for count <- [0, 3] do
      change = %{"op" => "change", "key" => "R-2", "values" => %{"cited" => count}}
      assert :ok = Writes.check(description, "ruling", change, flow, lookup)

      for actor <- [human, spoofed] do
        assert {:refuse, [_ | _]} = Writes.check(description, "ruling", change, actor, lookup)
      end

      edit = put_in(change, ["values", "title"], "Other")
      assert {:refuse, [_ | _]} = Writes.check(description, "ruling", edit, flow, lookup)
    end
  end

  test "only_target rules come from every outgoing relation and protect old and new targets" do
    only = %{"error" => "only the delegator sets under, to themselves", "also" => ["importer"]}

    description = %{
      "entities" => %{"ruling" => @rules},
      "relations" => %{
        "under" => %{"from" => ["ruling"], "only_target" => only},
        "ruled_by" => %{"from" => ["ruling"], "only_target" => only},
        "unrelated" => %{"from" => ["other"], "only_target" => only}
      }
    }

    rules = Writes.rules(description, "ruling")
    assert rules["only_target"] == %{"under" => only, "ruled_by" => only}
    assert Writes.rules(description, "absent") == %{}

    for relation <- ["under", "ruled_by"] do
      check = fn current, keys, writer ->
        Writes.check_rules(rules, "change", "R-2", current, %{}, %{relation => keys}, %{
          "writer" => writer
        })
      end

      assert {:refused, ["only the delegator sets under, to themselves"]} =
               check.(nil, ["J-1"], "C-1")

      assert {:refused, [_]} = check.(nil, ["J-1"], nil)
      assert :ok = check.(nil, ["J-1"], "J-1")
      assert {:refused, [_]} = check.(nil, ["J-2"], "J-1")
      assert :ok = check.(nil, ["J-1"], "importer")

      delegated = %{"values" => %{}, "links" => %{relation => ["J-1"]}}
      assert {:refused, [_]} = check.(delegated, [], "C-1")
      assert {:refused, [_]} = check.(delegated, ["J-2"], "C-1")
      assert {:refused, [_]} = check.(delegated, ["J-2"], "J-2")
      assert :ok = check.(delegated, [], "J-1")
      assert :ok = check.(delegated, ["J-2"], "importer")
      assert :ok = check.(delegated, ["J-1"], "C-1")
    end
  end

  test "an open fact is changed and deleted freely" do
    open = %{"values" => %{"title" => "T", "state" => "open"}, "links" => %{}}
    assert :ok = check("change", open, %{"title" => "Other"})
    assert :ok = check("delete", open, %{})
  end

  test "a condition requires its fields, on the fact as it is after the write" do
    assert {:refused, ["needs check"]} = check("create", nil, %{"weight" => "heavy"})
    assert :ok = check("create", nil, %{"weight" => "heavy", "check" => "a test"})

    open = %{"values" => %{"weight" => "heavy", "check" => "a test"}, "links" => %{}}
    assert {:refused, ["needs check"]} = check("change", open, %{"check" => ""})
    assert :ok = check("change", open, %{"title" => "x"})
  end

  test "who may make it final: the named kind always, another only when delegated" do
    final = %{"state" => "final"}
    # A write that makes it final is also a choice its writer makes (the next test); this one
    # is about the fact alone.
    no = "not this one's to decide"

    assert {:refused, [^no | _]} = check("create", nil, final)
    assert :ok = check("create", nil, final, %{"ruled_by" => ["J-1"]})
    assert {:refused, [^no | _]} = check("create", nil, final, %{"ruled_by" => ["C-1"]})
    assert :ok = check("create", nil, final, %{"ruled_by" => ["C-1"], "under" => ["J-1"]})

    # Any condition of only_kind_when leaves it to the named kind, delegated or not.
    for extra <- [%{"weight" => "heavy", "check" => "c"}, %{"area" => "money"}] do
      values = Map.merge(final, extra)
      links = %{"ruled_by" => ["C-1"], "under" => ["J-1"]}
      assert {:refused, [^no | _]} = check("create", nil, values, links)
      assert :ok = check("create", nil, values, %{"ruled_by" => ["J-1"]})
    end

    # On a change, the links already there count; an unknown linked fact never decides.
    open = %{"values" => %{"state" => "open"}, "links" => %{"ruled_by" => ["C-1"]}}
    assert {:refused, [^no | _]} = check("change", open, final)
    assert :ok = check("change", open, final, %{"under" => ["J-1"]})

    assert {:refused, [^no | _]} =
             check("create", nil, final, %{"ruled_by" => ["X-9"], "under" => ["J-1"]})
  end

  test "only a final or overturned fact is overturned, never itself" do
    values = %{"state" => "final"}
    links = %{"ruled_by" => ["J-1"], "overturns" => ["R-1"]}

    assert :ok = check("create", nil, values, links, %{"R-1" => %{"state" => "final"}})
    assert :ok = check("create", nil, values, links, %{"R-1" => %{"state" => "overturned"}})

    assert {:refused, ["R-1 is not final"]} =
             check("create", nil, values, links, %{"R-1" => %{"state" => "open"}})

    assert {:refused, ["R-1 is not final"]} = check("create", nil, values, links, %{})

    assert {:refused, ["R-2 is not final"]} =
             check("create", nil, values, %{"ruled_by" => ["J-1"], "overturns" => ["R-2"]})

    # While it is not final itself, what it names is not checked yet.
    assert :ok = check("create", nil, %{"state" => "open"}, %{"overturns" => ["R-9"]})
  end

  test "a stored final fact names what is to be overturned, once" do
    others = %{"R-1" => %{"state" => "final"}, "R-0" => %{"state" => "overturned"}}
    stored = %{"values" => %{"state" => "final"}, "links" => %{"overturns" => ["R-1", "R-0"]}}

    assert Writes.replaced(@rules, stored, &others[&1]) == ["R-1"]
    assert Writes.replaced(@rules, put_in(stored, ["values", "state"], "open"), & &1) == []
    assert Writes.replaced(%{}, stored, &others[&1]) == []
  end

  test "a write that decides is the decider's own: no one else's, and an agent's only when delegated" do
    final = %{"state" => "final"}
    no = "only who rules it decides it"
    by = fn writer -> %{"writer" => writer} end

    assert :ok = check("create", nil, final, %{"ruled_by" => ["J-1"]}, %{}, by.("J-1"))

    assert {:refused, [^no]} =
             check("create", nil, final, %{"ruled_by" => ["J-1"]}, %{}, by.("C-1"))

    assert {:refused, [^no]} =
             check("create", nil, final, %{"ruled_by" => ["J-1"]}, %{}, by.(nil))

    # A clerk decides its own ruling only under delegation, and never a heavy one.
    clerk = %{"ruled_by" => ["C-1"], "under" => ["J-1"]}
    assert :ok = check("create", nil, final, clerk, %{}, by.("C-1"))
    assert {:refused, [^no]} = check("create", nil, final, clerk, %{}, by.("J-1"))

    # Dropping it decides it too, under the same rules, though only final needs a ruler.
    open = %{"values" => %{"state" => "open"}, "links" => %{"ruled_by" => ["C-1"]}}
    assert {:refused, [^no]} = check("change", open, %{"state" => "dropped"})
    assert :ok = check("change", open, %{"state" => "dropped"}, %{"under" => ["J-1"]})

    heavy = %{"state" => "dropped", "weight" => "heavy", "check" => "c"}
    assert {:refused, [^no]} = check("change", open, heavy, %{"under" => ["J-1"]})

    # Writes that decide nothing need no decider; sending the same state again decides nothing.
    assert :ok = check("change", open, %{"title" => "x"}, %{}, %{}, by.("anyone"))
    dropped = put_in(open, ["values", "state"], "dropped")
    assert :ok = check("change", dropped, %{"state" => "dropped"}, %{}, %{}, by.("anyone"))

    # `also` lets a named writer decide (as a migration may, when the description says so).
    rules = put_in(@rules, ["authority", "also"], ["importer"])
    env = %{"writer" => "importer", "kind_of" => &kind_of/2, "fetch" => fn _ -> nil end}

    assert :ok =
             Writes.check_rules(rules, "create", "R-2", nil, final, %{"ruled_by" => ["J-1"]}, env)
  end

  test "a fact never rests on one at a level it may not depend on" do
    others = %{
      "R-1" => %{"level" => "bottom"},
      "R-3" => %{"level" => "middle"},
      "R-4" => %{"level" => "top"}
    }

    top = %{"level" => "top"}

    assert {:refused, ["R-2 (top) may not rest on R-1 (bottom)"]} =
             check("create", nil, top, %{"rests_on" => ["R-1"]}, others)

    assert {:refused, [_]} = check("create", nil, top, %{"rests_on" => ["R-3", "R-4"]}, others)
    assert :ok = check("create", nil, top, %{"rests_on" => ["R-4"]}, others)
    assert :ok = check("create", nil, %{"level" => "bottom"}, %{"rests_on" => ["R-4"]}, others)
    assert :ok = check("create", nil, %{}, %{"rests_on" => ["R-1"]}, others)

    # A change to its links, or to its own level, counts the links it then has.
    open = %{"values" => %{"level" => "bottom"}, "links" => %{"rests_on" => ["R-1"]}}
    assert {:refused, [_]} = check("change", open, top, %{}, others)

    # Moving down is refused while a fact above rests on it.
    incoming = %{"incoming" => fn "rests_on" -> ["R-4"] end}
    middle = %{"values" => %{"level" => "middle"}, "links" => %{}}

    assert {:refused, ["R-4 (top) may not rest on R-2 (bottom)"]} =
             check("change", middle, %{"level" => "bottom"}, %{}, others, incoming)

    assert :ok = check("change", middle, %{"title" => "x"}, %{}, others, incoming)
    assert :ok = check("change", middle, %{"level" => "top"}, %{}, others, incoming)
  end

  # A made-up record: a reading of a meter, immutable once taken, with what an inspector
  # finds afterwards set once each.
  @sealed %{
    "sealed" => %{
      "once" => ["finding", "checked_by"],
      "error" => "{key} is a reading; {field} is never changed",
      "once_error" => "{key}: {field} is set once"
    }
  }

  defp seal(op, current, values, links \\ %{}),
    do: Writes.check_rules(@sealed, op, "M-1", current, values, links, %{})

  defp reading(values \\ %{}, links \\ %{}),
    do: %{
      "values" => Map.merge(%{"meter" => "a", "level" => 3}, values),
      "links" => Map.merge(%{"on" => ["X-1"]}, links)
    }

  test "a sealed rule is read from the description" do
    assert Writes.rules(%{"entities" => %{"reading" => @sealed}}, "reading") == @sealed
  end

  test "a sealed record is written freely, then never changed, deleted or relinked" do
    assert :ok = seal("create", nil, %{"meter" => "a", "level" => 3}, %{"on" => ["X-1"]})

    assert {:refused, ["M-1 is a reading; level is never changed"]} =
             seal("change", reading(), %{"level" => 4})

    assert {:refused, ["M-1 is a reading; level is never changed"]} =
             seal("change", reading(), %{"level" => nil})

    assert {:refused, ["M-1 is a reading; note is never changed"]} =
             seal("change", reading(), %{"note" => "added later"})

    assert {:refused, ["M-1 is a reading; on is never changed"]} =
             seal("change", reading(), %{}, %{"on" => ["X-2"]})

    assert {:refused, ["M-1 is a reading; on is never changed"]} =
             seal("change", reading(), %{}, %{"on" => []})

    assert {:refused, [_]} = seal("delete", reading(), %{})

    # Sending what is there already is no change; a number compares with its text.
    assert :ok = seal("change", reading(), %{"meter" => "a", "level" => "3"}, %{"on" => ["X-1"]})
  end

  test "a once field or link of a sealed record is set while empty, then kept" do
    assert :ok = seal("change", reading(), %{"finding" => "leaks"})
    assert :ok = seal("change", reading(), %{}, %{"checked_by" => ["P-1"]})
    assert :ok = seal("change", reading(), %{"finding" => "leaks", "meter" => "a"})
    # Leaving it empty sets nothing.
    assert :ok = seal("change", reading(), %{"finding" => ""}, %{"checked_by" => []})

    found = reading(%{"finding" => "leaks"}, %{"checked_by" => ["P-1"]})
    assert :ok = seal("change", found, %{"finding" => "leaks"}, %{"checked_by" => ["P-1"]})

    assert {:refused, ["M-1: finding is set once"]} =
             seal("change", found, %{"finding" => "dry"})

    assert {:refused, ["M-1: finding is set once"]} = seal("change", found, %{"finding" => nil})

    assert {:refused, ["M-1: checked_by is set once"]} =
             seal("change", found, %{}, %{"checked_by" => ["P-2"]})

    # A once field does not open the rest.
    assert {:refused, ["M-1 is a reading; level is never changed"]} =
             seal("change", reading(), %{"finding" => "leaks", "level" => 9})
  end

  test "a sealed record's other rules still hold, and without its own error it still says why" do
    rules =
      Map.put(@sealed, "requires", [
        %{"when" => %{"meter" => ["a"]}, "fields" => ["level"], "error" => "needs level"}
      ])

    assert {:refused, ["needs level"]} =
             Writes.check_rules(rules, "create", "M-1", nil, %{"meter" => "a"}, %{}, %{})

    bare = %{"sealed" => %{"once" => ["finding"]}}

    assert {:refused, [why]} =
             Writes.check_rules(bare, "change", "M-1", reading(), %{"level" => 1}, %{}, %{})

    assert why =~ "level"
    assert {:refused, [_]} = Writes.check_rules(bare, "delete", "M-1", reading(), %{}, %{}, %{})
  end

  test "with links once, every relation of a sealed record is set while empty, then kept" do
    rules = %{
      "sealed" => %{"once" => ["finding"], "links" => "once", "once_error" => "{field} is set"}
    }

    check = fn current, links ->
      Writes.check_rules(rules, "change", "M-1", current, %{}, links, %{})
    end

    bare = %{"values" => %{"meter" => "a"}, "links" => %{}}

    assert :ok = check.(bare, %{"on" => ["X-1"], "next_to" => ["M-0"]})
    assert {:refused, ["on is set"]} = check.(reading(), %{"on" => ["X-2"]})
    assert {:refused, ["on is set"]} = check.(reading(), %{"on" => []})
    assert :ok = check.(reading(), %{"on" => ["X-1"], "next_to" => ["M-0"]})

    # Its properties stay sealed.
    assert {:refused, [_]} =
             Writes.check_rules(rules, "change", "M-1", bare, %{"meter" => "b"}, %{}, %{})
  end

  test "machine records require both the configured Bus sender and writer, for all operations" do
    description = %{
      "entities" => %{"cursor" => %{}},
      "flow_runtime" => %{"kind" => "cursor", "writer" => %{"sender" => "flow", "by" => "flow"}}
    }

    rules = Writes.rules(description, "cursor")

    for op <- ["create", "change", "delete"] do
      for env <- [
            %{"writer" => "flow", "sender" => "client"},
            %{"writer" => "client", "sender" => "flow"},
            %{}
          ] do
        assert {:refused, _} = Writes.check_rules(rules, op, "C-1", nil, %{}, %{}, env)
      end

      assert :ok =
               Writes.check_rules(rules, op, "C-1", nil, %{}, %{}, %{
                 "writer" => "flow",
                 "sender" => "flow"
               })
    end
  end

  test "an owner's answer (the state and the writer as decider, in one change) passes the decider gate only as it allows" do
    fingerprint = %{"fields" => ["title"], "relations" => []}

    rules = %{
      "authority" => %{
        "when" => %{"state" => ["final"]},
        "writes" => %{"state" => ["final", "dropped"]},
        "by" => "ruled_by",
        "kind" => "judge",
        "agent_kind" => "clerk",
        "error" => "a judge decides unless a fresh verdict permits a clerk",
        "writer_error" => "only who rules it decides it",
        "decider" => %{"gate" => "allow", "fingerprint" => fingerprint}
      }
    }

    open = %{"values" => %{"title" => "T", "state" => "open"}, "links" => %{}}

    answer = fn writer, state, verdict ->
      values = %{"state" => state, "signed_at" => "2026-11-12T00:00:00Z"}
      fact = %{"values" => Map.merge(open["values"], values), "links" => %{}}

      newest =
        if verdict,
          do: %{
            "verdict" => verdict,
            "fingerprint" => fingerprint(fact, fingerprint)
          }

      Writes.check_rules(rules, "change", "R-2", open, values, %{"ruled_by" => [writer]}, %{
        "writer" => writer,
        "kind_of" => &kind_of/2,
        "verdict" => fn "allow", "R-2" -> newest end,
        "fingerprint" => &fingerprint/2
      })
    end

    # The named kind always may: accept and reject alike, with no verdict at all.
    for state <- ["final", "dropped"], do: assert(:ok = answer.("J-1", state, nil))

    # Another kind may not without a fresh verdict that permits it: neither accept nor reject.
    for state <- ["final", "dropped"], verdict <- [nil, "judge_only"] do
      assert {:refused, reasons} = answer.("C-1", state, verdict)
      assert "only who rules it decides it" in reasons
    end

    for state <- ["final", "dropped"], do: assert(:ok = answer.("C-1", state, "agent"))
  end

  test "a ledger refuses deletion even with no children or verdict records" do
    rules =
      Writes.rules(
        %{"entities" => %{"bead" => %{"delete_error" => "Append-only ledger"}}},
        "bead"
      )

    assert {:refused, ["Append-only ledger"]} =
             Writes.check_rules(
               rules,
               "delete",
               "B-1",
               %{"values" => %{}, "links" => %{}},
               %{},
               %{},
               %{}
             )

    assert :ok = Writes.check_rules(rules, "change", "B-1", nil, %{"color" => "blue"}, %{}, %{})
  end
end

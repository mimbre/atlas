defmodule RelaDSL.Facts.CapacityTest do
  use ExUnit.Case, async: true
  alias RelaDSL.Facts.Writes

  @turn %{
    "kind" => "run",
    "state" => "state",
    "running" => "running",
    "ended" => "ended",
    "lease" => "lease",
    "ended_at" => "ended_at",
    "why" => "why",
    "lease_margin" => 120,
    "on" => "task",
    "pick" => "pick",
    "attempt" => "attempt",
    "quiescent" => "quiescent"
  }
  @fields %{
    "entry" => "entry",
    "picked_entry" => "picked_entry",
    "pick" => "pick",
    "backend" => "backend",
    "model" => "model",
    "at" => "at"
  }
  @description %{
    "entities" => %{"run" => %{}, "ticket" => %{}},
    "relations" => %{"task" => %{"from" => ["run"], "to" => ["ticket"]}},
    "runtime" => %{"turn" => @turn, "capacity" => @fields},
    "flow_runtime" => %{
      "kind" => "job",
      "fields" => %{"generation" => "generation", "entry" => "entry", "status" => "status"}
    }
  }

  test "Flow may end only a running turn beyond its stored lease plus margin" do
    current = %{
      properties: %{"state" => "running", "lease" => "2026-11-14T00:00:00Z"},
      links: %{}
    }

    values = %{
      "state" => "ended",
      "lease" => "",
      "why" => "expired",
      "ended_at" => "2026-11-14T00:02:00Z"
    }

    change = %{"op" => "change", "key" => "R-1", "values" => values}
    actor = %{"sender" => "flow", "by" => "flow"}

    for {now, value, expected} <- [
          {~U[2026-11-14 00:01:59.999Z], values, :refused},
          {~U[2026-11-14 00:02:00Z], values, :refused},
          {~U[2026-11-14 00:02:01Z], Map.put(values, "model", "different"), :refused},
          {~U[2026-11-14 00:02:01Z], Map.put(values, "lease", "later"), :refused}
        ] do
      lookup = %{"current" => fn -> current end, "now" => fn -> now end}
      result = Writes.check(@description, "run", %{change | "values" => value}, actor, lookup)

      if expected == :ok,
        do: assert(result == :ok),
        else: assert(match?({:refuse, [_ | _]}, result))
    end
  end

  test "a stale projection cannot pick after its run has advanced" do
    change = %{
      "op" => "change",
      "key" => "T-1",
      "values" => %{"pick" => "p"},
      "was" => %{"entry" => "J-1:1:1", "pick" => nil}
    }

    lookup = %{
      "current" => fn -> %{properties: %{"entry" => "J-1:1:1"}, links: %{}} end,
      "fact" => fn "job", "J-1" ->
        %{properties: %{"generation" => 1, "entry" => 2, "status" => "active"}}
      end
    }

    assert {:refuse, [_ | _]} =
             Writes.check(
               @description,
               "ticket",
               change,
               %{"sender" => "flow/capacity", "by" => "flow"},
               lookup
             )
  end

  test "a new hand-assignee makes a conditional release fail" do
    change = %{
      "op" => "change",
      "key" => "T-1",
      "values" => %{"pick" => ""},
      "links" => %{"owner" => []},
      "was" => %{"owner" => ["W-1"], "pick" => "p"}
    }

    lookup = %{
      "current" => fn ->
        %{properties: %{"pick" => "p"}, links: %{"owner" => ["W-2"]}}
      end
    }

    assert {:refuse, [_ | _]} =
             Writes.check(
               @description,
               "ticket",
               change,
               %{"sender" => "flow/capacity", "by" => "flow"},
               lookup
             )
  end

  test "a late end cannot change a reused turn key belonging to a newer allocation" do
    current = %{
      properties: %{"state" => "running", "pick" => "new", "attempt" => "a2"},
      links: %{}
    }

    change = %{
      "op" => "change",
      "key" => "R-1",
      "values" => %{"state" => "ended", "quiescent" => true},
      "was" => %{"pick" => "old", "attempt" => "a1"}
    }

    lookup = %{"current" => fn -> current end}
    actor = %{"sender" => "runtime@host/R-1", "by" => "runtime"}
    assert {:refuse, [_ | _]} = Writes.check(@description, "run", change, actor, lookup)

    assert :ok =
             Writes.check(
               @description,
               "run",
               %{change | "was" => %{"pick" => "new", "attempt" => "a2"}},
               actor,
               lookup
             )
  end
end

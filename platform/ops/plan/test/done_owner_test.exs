defmodule AtlasPlan.DoneOwnerTest do
  use ExUnit.Case, async: true

  alias AtlasPlan.DoneOwner

  defp part(key, owner, expected),
    do: %{
      "id" => key,
      "properties" => %{"of" => String.replace_prefix(key, "AS-", ""), "expected" => expected},
      "relations" => if(owner, do: %{"assigned_to" => [owner]}, else: %{})
    }

  test "only an owner a migration set, on an Assignment Flow expects nothing of" do
    parts = [
      part("AS-IS-1", "coordinator", nil),
      part("AS-IS-2", "coordinator", "Build it"),
      part("AS-IS-3", "coordinator", ""),
      part("AS-IS-4", nil, nil),
      part("AS-PR-5", "melle", nil)
    ]

    assert Enum.map(DoneOwner.candidates(parts), & &1["id"]) == ["AS-IS-1", "AS-IS-3", "AS-PR-5"]

    origins = %{
      "AS-IS-1" => %{"by" => "migration"},
      "AS-IS-2" => %{"by" => "migration"},
      "AS-IS-3" => %{"by" => "flow"},
      "AS-PR-5" => %{"by" => "melle"}
    }

    assert DoneOwner.steps(parts, origins) == [{:unassign, "AS-IS-1", "coordinator", "IS-1"}]

    assert DoneOwner.line({:unassign, "AS-IS-1", "coordinator", "IS-1"}) ==
             "unassign AS-IS-1  assigned_to coordinator  (IS-1 is done)"
  end

  test "nothing left to do once the owners are gone" do
    assert DoneOwner.steps([part("AS-IS-1", nil, nil)], %{}) == []
  end

  test "an owner the IS-Atlas-78 migration moved counts as set by whoever set it before" do
    moved = fn by ->
      %{
        "by" => "migration",
        "cause" =>
          "assignment introduced (IS-Atlas-78); moved from IS-1, set 2026-11-03T18:03:13Z by #{by}: owner introduced"
      }
    end

    assert DoneOwner.set_by(moved.("migration")) == "migration"
    assert DoneOwner.set_by(moved.("agent")) == "agent"
    assert DoneOwner.set_by(%{"by" => "migration", "cause" => "owner introduced"}) == "migration"

    unsaid = %{
      "by" => "migration",
      "cause" =>
        "assignment introduced (IS-Atlas-78); moved from IS-1, which did not say who set it"
    }

    assert DoneOwner.set_by(unsaid) == nil
    assert DoneOwner.set_by(%{"by" => "flow"}) == "flow"

    parts = [part("AS-IS-1", "coordinator", nil), part("AS-IS-2", "coordinator", nil)]
    origins = %{"AS-IS-1" => moved.("agent"), "AS-IS-2" => unsaid}
    assert DoneOwner.steps(parts, origins) == []
    assert DoneOwner.unknown(parts, origins) == ["AS-IS-2"]
  end
end

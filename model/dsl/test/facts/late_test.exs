defmodule RelaDSL.Facts.LateTest do
  use ExUnit.Case, async: true

  alias RelaDSL.Facts.Derived

  @d %{
    "entities" => %{
      "ticket" => %{"late" => %{"after" => "due", "while" => "todo", "label" => "late"}},
      "note" => %{}
    }
  }

  @now ~U[2026-11-04 12:00:00Z]

  test "late while the time has passed and something is still to do" do
    assert Derived.late(
             @d,
             "ticket",
             %{"due" => "2026-11-04T11:00:00Z", "todo" => "Fix it"},
             @now
           )

    refute Derived.late(
             @d,
             "ticket",
             %{"due" => "2026-11-04T13:00:00Z", "todo" => "Fix it"},
             @now
           )

    # Done: nothing to do any more, so never late.
    refute Derived.late(@d, "ticket", %{"due" => "2026-11-04T11:00:00Z", "todo" => ""}, @now)
    refute Derived.late(@d, "ticket", %{"due" => "2026-11-04T11:00:00Z"}, @now)
    # An offset counts as the instant it is.
    assert Derived.late(
             @d,
             "ticket",
             %{"due" => "2026-11-04T12:30:00+01:00", "todo" => "x"},
             @now
           )
  end

  test "nothing to say without a time, without a rule, or with a time that is none" do
    assert Derived.late(@d, "ticket", %{"todo" => "Fix it"}, @now) == nil
    assert Derived.late(@d, "ticket", %{"due" => "", "todo" => "Fix it"}, @now) == nil
    assert Derived.late(@d, "ticket", %{"due" => "tomorrow", "todo" => "Fix it"}, @now) == nil
    assert Derived.late(@d, "note", %{"due" => "2026-11-04T11:00:00Z"}, @now) == nil
  end
end

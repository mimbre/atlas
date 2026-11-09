defmodule AtlasFacts.LateTest do
  use ExUnit.Case, async: true

  alias AtlasFacts.Late

  @d %{
    "entities" => %{
      "ticket" => %{"late" => %{"after" => "due", "while" => "todo", "label" => "late"}},
      "note" => %{}
    }
  }

  @now ~U[2026-11-04 12:00:00Z]

  test "late while the time has passed and something is still to do" do
    assert Late.of(@d, "ticket", %{"due" => "2026-11-04T11:00:00Z", "todo" => "Fix it"}, @now)
    refute Late.of(@d, "ticket", %{"due" => "2026-11-04T13:00:00Z", "todo" => "Fix it"}, @now)
    # Done: nothing to do any more, so never late.
    refute Late.of(@d, "ticket", %{"due" => "2026-11-04T11:00:00Z", "todo" => ""}, @now)
    refute Late.of(@d, "ticket", %{"due" => "2026-11-04T11:00:00Z"}, @now)
    # An offset counts as the instant it is.
    assert Late.of(@d, "ticket", %{"due" => "2026-11-04T12:30:00+01:00", "todo" => "x"}, @now)
  end

  test "nothing to say without a time, without a rule, or with a time that is none" do
    assert Late.of(@d, "ticket", %{"todo" => "Fix it"}, @now) == nil
    assert Late.of(@d, "ticket", %{"due" => "", "todo" => "Fix it"}, @now) == nil
    assert Late.of(@d, "ticket", %{"due" => "tomorrow", "todo" => "Fix it"}, @now) == nil
    assert Late.of(@d, "note", %{"due" => "2026-11-04T11:00:00Z"}, @now) == nil
  end

  test "a datetime field takes an RFC 3339 instant or nothing; rela would store anything" do
    spec = %{"properties" => %{"due" => %{"type" => "datetime"}}}
    assert AtlasFacts.Description.check(spec, %{"due" => "2026-11-04T17:00:00Z"}, :change) == :ok
    assert AtlasFacts.Description.check(spec, %{"due" => nil}, :change) == :ok

    assert AtlasFacts.Description.check(spec, %{"due" => "tomorrow"}, :change) ==
             {:error, ["due must be a date and time, e.g. 2026-11-04T17:00:00Z"]}
  end
end

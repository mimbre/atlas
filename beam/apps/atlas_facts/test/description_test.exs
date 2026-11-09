defmodule AtlasFacts.DescriptionTest do
  use ExUnit.Case, async: true

  test "a datetime field takes an RFC 3339 instant or nothing; rela would store anything" do
    spec = %{"properties" => %{"due" => %{"type" => "datetime"}}}
    assert AtlasFacts.Description.check(spec, %{"due" => "2026-11-04T17:00:00Z"}, :change) == :ok
    assert AtlasFacts.Description.check(spec, %{"due" => nil}, :change) == :ok

    assert AtlasFacts.Description.check(spec, %{"due" => "tomorrow"}, :change) ==
             {:error, ["due must be a date and time, e.g. 2026-11-04T17:00:00Z"]}
  end
end

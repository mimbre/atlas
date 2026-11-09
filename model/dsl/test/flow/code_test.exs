defmodule RelaDSL.Flow.CodeTest do
  use ExUnit.Case, async: true
  alias RelaDSL.Flow.{Code, Subflow}

  defp fill(text, vars), do: Code.fill(Subflow.parts(text), vars)

  test "a text names values in braces; each is filled from the vars" do
    assert fill("Label it: {notes} ({note})", %{"notes" => "fragile", "note" => "torn"}) ==
             "Label it: fragile (torn)"

    assert fill("Weigh {count} crates", %{"count" => 3}) == "Weigh 3 crates"
    assert fill("Pack it", %{"notes" => "x"}) == "Pack it"
  end

  test "a name with no plain value leaves its place empty, and a trailing colon goes" do
    # The name in braces never shows, whether the field is missing, empty or no text.
    for vars <- [%{}, %{"notes" => ""}, %{"notes" => nil}, %{"notes" => %{"a" => 1}}],
        do: assert(fill("Label it: {notes}", vars) == "Label it", inspect(vars))
  end

  test "braces that name no field stay text" do
    assert fill("Key {1} of {key", %{"1" => "x"}) == "Key {1} of {key"
  end
end

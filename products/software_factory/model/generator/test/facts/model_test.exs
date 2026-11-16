defmodule RelaDSL.Facts.ModelTest do
  @moduledoc """
  What a composition compiles for the store (`RelaDSL.Facts.Model`), on the neutral office:
  the schema rela must serve, the kind's rules, what a write brings along, what a read
  works out and the run mapping, from the macros alone.
  """
  use ExUnit.Case, async: true

  alias RelaDSL.Office

  # The store's reader: for a write (`current`, `fact`, `list`, `incoming`) and for what
  # a read works out (`linked`, `facts`: `RelaDSL.Facts.Reads`), over the same facts.
  defp lookup(current \\ nil, facts \\ %{}) do
    list = fn kind -> {:ok, for({{^kind, _}, f} <- facts, do: f)} end

    Map.merge(RelaDSL.Facts.Reads.of(list), %{
      "current" => fn -> current end,
      "fact" => fn kind, key -> facts[{kind, key}] end,
      "list" => list,
      "incoming" => fn _kind, _key, _relation -> [] end,
      "fingerprint" => fn _fact, _spec -> "f" end
    })
  end

  defp change(op, key, values \\ %{}, links \\ %{}),
    do: %{"op" => op, "key" => key, "values" => values, "links" => links, "by" => "ada"}

  test "the schema rela must serve: as written, with what rela adds and drops" do
    schema = Office.rela_schema()
    letter = schema["entities"]["letter"]
    refute Map.has_key?(letter, "aliases")
    assert letter["id_prefixes"] == ["LE-"]
    assert letter["properties"]["urgent"]["default"] == "false"
    assert letter["properties"]["body"]["required"] == false
    refute Map.has_key?(letter["properties"]["code"], "unique")
    assert letter["properties"]["state"]["values"] == ["draft", "sent", "lost"]
    refute Map.has_key?(schema["types"]["post_code"], "validations")
    # The model's additions are no part of it.
    refute Map.has_key?(letter, "frozen")
    assert Map.keys(schema) == ["entities", "relations", "types"]

    assert RelaDSL.Facts.Served.of(%{"entities" => %{}, "relations" => %{}}) ==
             %{"entities" => %{}, "relations" => %{}}
  end

  test "the kind's rules are compiled in: refusals with the model's words" do
    assert {:refuse, ["a letter is kept"]} =
             Office.check("letter", change("delete", "LE-01"), %{"by" => "ada"}, lookup())

    assert {:refuse, ["a sent letter has a code"]} =
             Office.check(
               "letter",
               change("create", "LE-01", %{"title" => "T", "state" => "sent"}),
               %{"by" => "ada"},
               lookup()
             )

    sent = %{"values" => %{"title" => "T", "state" => "sent", "code" => "1234"}, "links" => %{}}

    assert {:refuse, ["LE-01 is sent"]} =
             Office.check(
               "letter",
               change("change", "LE-01", %{"title" => "Other"}),
               %{"by" => "ada"},
               lookup(sent)
             )

    assert :ok = Office.check("clerk", change("create", "ada"), %{"by" => "ada"}, lookup())
  end

  test "a write brings its component along, and marks what it replaces" do
    assert [
             %{"as" => "component", "kind" => "desk", "key" => "DK-LE-01", "relation" => "desk"},
             %{"as" => "fact", "key" => "LE-01"}
           ] = Office.with_change("letter", change("create", "LE-01"), lookup())

    assert [%{"as" => "fact"}, %{"as" => "component", "op" => "delete", "key" => "DK-LE-01"}] =
             Office.with_change("letter", change("delete", "LE-01"), lookup())

    old = %{key: "LE-00", properties: %{"state" => "sent"}, links: %{}}

    assert [
             _desk,
             %{"as" => "fact"},
             %{"as" => "replaced", "key" => "LE-00", "values" => %{"state" => "lost"}}
           ] =
             Office.with_change(
               "letter",
               change("create", "LE-01", %{"state" => "sent"}, %{"replies_to" => ["LE-00"]}),
               lookup(nil, %{{"letter", "LE-00"} => old})
             )
  end

  test "a read works out reviews and flags; the run mapping is compiled in" do
    urgent = %{key: "LE-01", properties: %{"urgent" => true}, links: %{}}

    assert {:ok, [%{"review" => %{"label" => "Urgent letter", "key" => "LE-01"}}]} =
             Office.derived("letter", [urgent], lookup())

    assert {:ok, [%{}]} =
             Office.derived("clerk", [%{key: "ada", properties: %{}, links: %{}}], %{})

    assert %{"kind" => "run", "writer" => %{"by" => "flow", "sender" => "flow"}} =
             Office.run_mapping()

    assert Office.connector("letter") == nil
  end
end

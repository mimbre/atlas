defmodule RelaDSL.AtlasTest do
  use ExUnit.Case, async: true

  alias RelaDSL.{Atlas, Example}

  defp json(flows \\ Example.__flows__(), gates \\ Example.Gates.__gates__()),
    do: Atlas.flows_json(flows, gates)

  test "states carry their mechanism as kind and spec; gates are data, named or not" do
    data = JSON.decode!(json())
    states = data["flows"]["letter"]["states"]

    assert Map.take(states["proofread"], ~w(final kind spec)) == %{
             "final" => false,
             "kind" => "gate",
             "spec" => %{"gate" => "proofread", "version" => 2}
           }

    refute Map.has_key?(states["draft"], "kind")
    assert states["draft"]["waiting_for"] == ["writer"]
    assert states["dropped"]["final"] == true
    assert states["dropped"]["branches"] == []
    assert states["dropped"]["set"] == []

    assert states["draft"]["timers"] == [
             %{
               "name" => "slow",
               "period" => "1d",
               "to" => "stuck",
               "label" => "The writer did not finish"
             }
           ]

    assert data["flows"]["letter"]["start"] == [
             %{"on" => "create"},
             %{"on" => "predicate", "when" => "entity.kind == 'reply'"}
           ]

    assert data["flows"]["letter"]["initial"] == "draft"

    # size_limit is named by no subflow; it is written all the same, rule included.
    assert data["gates"]["size_limit"]["rule"] == %{
             "all" => [["equals", "pages", 1], ["same", "envelope", "format"]]
           }

    assert data["gates"]["size_limit"]["decide"]["uncertain"] == "person"
    assert data["gates"]["proofread"]["policy"] == %{"max_rounds" => 2}
    assert {data["format"], data["writer"]} == {2, "system:atlas-flow"}
  end

  test "a state presents to its owner as expected, why and todo; the owner has a default" do
    letter = JSON.decode!(json())["flows"]["letter"]

    assert letter["owner"] == %{
             "via" => "desk",
             "relation" => "held_by",
             "default" => %{"kind" => "team", "key" => "post_room"}
           }

    assert letter["states"]["stuck"]["present"] == %{
             "expected" => "Decide on it: {reason}",
             "why" => "it could not go out",
             "todo" => %{
               "instructions" =>
                 "Read what went wrong, then send it back to the writer or drop it.",
               "section" => %{"field" => "notes", "heading" => "What went wrong"},
               "answers" => [
                 %{"key" => "r", "label" => "Retry", "set" => "retried_by"},
                 %{"key" => "d", "label" => "Drop", "remove" => "retried_by"}
               ]
             }
           }

    # A state's own owner is written as the subflow's is; the others have none of their own.
    assert letter["states"]["stuck"]["owner"] == %{
             "default" => %{"kind" => "team", "key" => "editors"}
           }

    refute Map.has_key?(letter["states"]["draft"], "owner")

    # No why and no todo: nothing empty is written.
    assert letter["states"]["draft"]["present"] == %{"expected" => "Write it"}
    refute Map.has_key?(letter["states"]["proofread"], "present")
  end

  test "a state that names a gate the gates do not hold, or in another version, is refused" do
    [smart, rule] = Example.Gates.__gates__()

    assert_raise ArgumentError, ~r/state proofread: names gate proofread version 2/, fn ->
      json(Example.__flows__(), [rule])
    end

    assert_raise ArgumentError, ~r/names gate proofread version 2/, fn ->
      json(Example.__flows__(), [%{smart | version: 3}, rule])
    end
  end

  test "format 2 carries every execution list and no source positions" do
    letter = JSON.decode!(json())["flows"]["letter"]
    assert letter["run_as"] == "system:post"
    assert letter["per_subject"] == "one"

    for {_name, state} <- letter["states"] do
      for field <- ~w(waiting_for awaits set creates branches timers),
          do: assert(is_list(state[field]))

      refute Map.has_key?(state, "line")
    end

    assert letter["states"]["answered"]["set"] == [%{"field" => "archived", "value" => true}]
    assert letter["states"]["sent"]["awaits"] == ["reply"]

    assert letter["states"]["post"]["creates"] == [
             %{
               "type" => "receipt",
               "properties" => %{"title" => "Receipt"},
               "relate" => "receipt_of"
             }
           ]

    assert Enum.map(letter["states"]["sent"]["branches"], & &1["to"]) == [
             "answered",
             "answered",
             "stuck"
           ]
  end

  test "typed choices stay distinct from snapshot branches; starts and resets survive generation" do
    letter = JSON.decode!(json())["flows"]["letter"]

    assert letter["start"] == [
             %{"on" => "create"},
             %{"on" => "predicate", "when" => "entity.kind == 'reply'"}
           ]

    assert letter["states"]["stuck"]["waiting_for"] == ["editor"]
    assert letter["states"]["stuck"]["set"] == [%{"field" => "choice", "value" => "none"}]
    assert Enum.any?(letter["states"]["stuck"]["branches"], &(&1["roles"] == ["editor"]))
    assert letter["states"]["answered"]["set"] == [%{"field" => "archived", "value" => true}]
    [flow] = Example.__flows__()
    [first | rest] = flow.states

    first = %{
      first
      | timers: [%{name: :due, period: "5m", to: :stuck, since: :opened_at, label: nil}]
    }

    generated = JSON.decode!(json([%{flow | states: [first | rest]}]))

    assert generated["flows"]["letter"]["states"]["draft"]["timers"] == [
             %{"name" => "due", "period" => "5m", "to" => "stuck", "since" => "opened_at"}
           ]
  end

  # Small maps with atom keys iterate in atom-table order (OTP 26+), which differs
  # between two VMs that created their atoms in another order. A second VM creates
  # every word of the file first, in reverse order, then writes the file again.
  @tag :tmp_dir
  test "two builds give the same bytes, whatever order the atoms were made in", %{tmp_dir: dir} do
    here = json()

    words =
      Regex.scan(~r/"([a-z_]+)"/, here, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.sort(:desc)

    File.write!(Path.join(dir, "words"), Enum.join(words, "\n"))
    out = Path.join(dir, "flows.json")

    script = """
    [words, out] = System.argv()
    for w <- String.split(File.read!(words)), do: String.to_atom(w)
    alias RelaDSL.{Atlas, Example}
    File.write!(out, Atlas.flows_json(Example.__flows__(), Example.Gates.__gates__()))
    """

    ebin = Path.join(:code.lib_dir(:rela_dsl), "ebin")
    args = ["-pa", ebin, "-e", script, Path.join(dir, "words"), out]

    assert {_, 0} =
             System.cmd(System.find_executable("elixir"), args, stderr_to_stdout: true)

    assert File.read!(out) == here
  end
end

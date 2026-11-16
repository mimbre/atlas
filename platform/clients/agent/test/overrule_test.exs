defmodule AtlasAgent.OverruleTest do
  use ExUnit.Case, async: true

  alias AtlasAgent.Overrule

  # A step's record, as its page holds it; the keys are made up.
  defp step(values), do: Map.merge(%{"n" => "2", "state" => "stored", "made" => "T-07"}, values)

  test "a step that made a fact is undone by deleting it" do
    {[delete], summary} = Overrule.reverse(step(%{"tool" => "put"}), "S-03")
    assert %{"tool" => "delete", "key" => "T-07", "values" => %{}} = delete
    assert delete["why"] =~ "Step 2 (S-03) made T-07"
    assert summary == "Undoes S-03: deletes T-07, which it made."
  end

  test "a step that changed a fact is undone by setting back what it replaced" do
    was = JSON.encode!(%{"title" => "Old"})
    {[set], summary} = Overrule.reverse(step(%{"tool" => "set", "was" => was}), "S-03")
    assert %{"tool" => "set", "key" => "T-07", "values" => %{"title" => "Old"}} = set
    assert summary =~ "puts back the values of T-07"
  end

  test "what cannot be undone from the record says why, with no steps" do
    assert {[], text} = Overrule.reverse(step(%{"tool" => "delete"}), "S-03")
    assert text =~ "does not keep what was deleted"

    assert {[], text} = Overrule.reverse(step(%{"tool" => "set", "was" => ""}), "S-03")
    assert text =~ "kept no values"

    assert {[], text} = Overrule.reverse(step(%{"tool" => "put", "state" => "dropped"}), "S-03")
    assert text =~ "stored nothing"
  end
end

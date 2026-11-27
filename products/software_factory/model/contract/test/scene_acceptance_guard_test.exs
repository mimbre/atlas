defmodule Model.SceneAcceptanceGuardTest do
  use ExUnit.Case, async: true

  alias Model.AtlasEyra

  defp lookup(values, guard? \\ true) do
    fact = %{"values" => values, "links" => %{}}
    lookup = %{
      "current" => fn -> fact end,
      "fact" => fn _, _ -> nil end,
      "list" => fn _ -> {:ok, []} end,
      "incoming" => fn _, _, _ -> [] end,
      "fingerprint" => &AtlasBus.SubjectFingerprint.of/2
    }
    if guard?, do: Map.put(lookup, "guard_current", fn -> fact end), else: lookup
  end

  defp accept(values, proposed \\ %{}, guard? \\ true) do
    AtlasEyra.check(
      "scene",
      %{"op" => "change", "key" => "SC-Atlas-1", "values" => proposed,
        "links" => %{"accepted_by" => ["person-1"]}},
      %{"by" => "person-1", "sender" => "control/session-1"},
      lookup(values, guard?)
    )
  end

  test "the actual composition requires the considered suggestions before acceptance" do
    guard = get_in(AtlasEyra.__rela__(:description).extension, ["relations", "accepted_by", "guard"])
    assert guard["kind"] == "scene"
    assert guard["equal"] == ["suggestions", "designed_suggestions"]
    assert guard["not_false"] == "design_snapshot_known"

    assert :ok = accept(%{})
    assert {:refuse, reasons} = accept(%{"suggestions" => "new", "designed_suggestions" => "old"})
    assert guard["error"] in reasons
    assert {:refuse, reasons} = accept(%{"design_snapshot_known" => false})
    assert guard["error"] in reasons
    assert :ok = accept(%{"suggestions" => "new"}, %{"designed_suggestions" => "new", "design_snapshot_known" => true})
  end

  test "direct model callers without the version-fenced reader are refused" do
    assert {:refuse, reasons} = accept(%{}, %{}, false)
    assert Enum.any?(reasons, &String.contains?(&1, "Design"))
  end
end

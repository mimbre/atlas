defmodule AtlasLearn.Observations.CodeChangesTest do
  use ExUnit.Case, async: true
  alias AtlasLearn.Fixtures
  alias AtlasLearn.Observations.CodeChanges

  test "Code's records changed in the window are records; earlier ones are context" do
    observation = CodeChanges.observe(Fixtures.window(), code_home: Fixtures.code_home())

    assert observation.status == :read
    ids = Enum.map(observation.records, & &1.id)
    assert "review aaaaaaaa-0000-4000-8000-000000000002" in ids
    assert "integration bbbbbbbb-0000-4000-8000-000000000001" in ids
    refute "review aaaaaaaa-0000-4000-8000-000000000001" in ids

    assert Enum.map(observation.context, & &1.id) |> Enum.sort() ==
             [
               "change 11111111-1111-4111-8111-111111111111",
               "review aaaaaaaa-0000-4000-8000-000000000001"
             ]
  end

  test "a review carries its work and phase; a change whether it is sealed" do
    observation = CodeChanges.observe(Fixtures.window(), code_home: Fixtures.code_home())
    by_id = Map.new(observation.records, &{&1.id, &1})

    assert %{title: "Rename the export flag", phase: "failed", target: "main"} =
             by_id["review aaaaaaaa-0000-4000-8000-000000000003"]

    assert by_id["change 33333333-3333-4333-8333-333333333333"].phase == "open"
    assert by_id["change 22222222-2222-4222-8222-222222222222"].phase == "sealed"
  end

  test "an unreadable record is named, the token is never read, a missing home is reported" do
    home = Fixtures.code_home()
    observation = CodeChanges.observe(Fixtures.window(), code_home: home)

    assert Enum.any?(observation.notes, &String.ends_with?(&1, "integrations/broken.json"))
    refute inspect(observation) =~ "never-read-token"

    assert {:unavailable, "no such folder"} =
             CodeChanges.observe(Fixtures.window(), code_home: Path.join(home, "absent")).status
  end
end

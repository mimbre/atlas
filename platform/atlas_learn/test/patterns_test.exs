defmodule AtlasLearn.PatternsTest do
  use ExUnit.Case, async: true
  alias AtlasLearn.{Fixtures, Patterns}

  setup do
    window = Fixtures.window()

    observations =
      AtlasLearn.observe(window,
        worker_passes: [read: Fixtures.runtime_read()],
        code_changes: [code_home: Fixtures.code_home()],
        decisions: [kind: "ledger", env: "test", client: Fixtures.atlas_client()]
      )

    patterns = Map.new(Patterns.find(observations, window), &{&1.title, &1})
    %{patterns: patterns}
  end

  defp findings(patterns, title), do: patterns[title].findings

  # Runtime's history gives no continued turn or error (RQ1): no chains, and failures are
  # grouped by their state alone.
  test "no follow-up chains without the continued turn", %{patterns: patterns} do
    assert patterns["Passes that needed follow-up turns"].status == :read
    assert findings(patterns, "Passes that needed follow-up turns") == []
  end

  test "failed turns grouped by state, most frequent first", %{patterns: patterns} do
    assert [failed, unknown] = findings(patterns, "Failed turns and their reasons")
    assert failed.text == "2 × failed (worker alpha, gamma)"
    assert failed.evidence == ["turn-00000000000000a3", "turn-00000000000000a6"]
    assert unknown.text == "1 × unknown (worker beta)"
    assert unknown.evidence == ["turn-00000000000000a5"]
  end

  test "work reviewed twice, a retried integration and refusals", %{patterns: patterns} do
    [reviewed, integrated | refusals] =
      findings(patterns, "Changes that needed more than one review, or were refused")

    assert reviewed.text =~ ~s{reviewed 2 times (2 changes): "Add widget export"}
    assert "review aaaaaaaa-0000-4000-8000-000000000001" in reviewed.evidence
    assert "change 22222222-2222-4222-8222-222222222222" in reviewed.evidence

    assert integrated.text =~ "integrated 2 times"
    assert hd(integrated.evidence) == "review aaaaaaaa-0000-4000-8000-000000000002"

    assert Enum.map(refusals, & &1.text) == [
             "1 × integration refused: the target moved",
             "1 × review refused: its location was already taken"
           ]
  end

  test "decisions decided in the window, what they replaced, what is open", %{patterns: patterns} do
    assert Enum.map(findings(patterns, "Decisions in the window"), &{&1.text, &1.evidence}) == [
             {"accepted: 1", ["D-0030"]},
             {"rejected: 1", ["D-0032"]},
             {"D-0030 (accepted): supersedes D-0003", ["D-0030", "D-0003"]},
             {"not decided yet, proposed: 1 (date unknown)", ["D-0031"]}
           ]
  end

  test "a source that was not read yields no findings, only its status" do
    window = Fixtures.window()
    observations = AtlasLearn.observe(window, code_changes: [code_home: "/nonexistent/code"])
    patterns = Map.new(Patterns.find(observations, window), &{&1.title, &1})

    assert patterns["Passes that needed follow-up turns"].status == :not_asked

    assert {:unavailable, _} =
             patterns["Changes that needed more than one review, or were refused"].status

    assert patterns["Decisions in the window"].findings == []
  end
end

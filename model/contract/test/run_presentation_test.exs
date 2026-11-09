defmodule Model.RunPresentationTest do
  @moduledoc """
  How Atlas's work is presented from its runs (slice 13), as Facts derives it
  (`AtlasFacts.Presentation`) from the composition's presenters and Control shows it:
  the accepted decision's follow-through, a reopened use case, and Accept on a use case
  page that ends its run as the decider's own Accept does.
  """
  use ExUnit.Case, async: true

  alias AtlasControl.Pages

  @m AtlasControl.Model.catalog(Model.AtlasEyra)

  defp presenter(kind),
    do: Enum.find(Model.AtlasEyra.presentation(), &(&1["subject"] == kind))

  defp present(kind, assignment, fact, runs, completed? \\ false) do
    shown =
      AtlasFacts.Presentation.view(presenter(kind), assignment, fact, runs, fn -> completed? end)

    Map.put(assignment, "presentation", shown)
  end

  defp run(flow, status, state),
    do: %{"key" => "R-1", "flow" => flow, "generation" => 1, "status" => status, "state" => state}

  defp assignment(key, values, owners),
    do: %{"key" => "AS-" <> key, "values" => values, "links" => %{"assigned_to" => owners}}

  defp subflow(name), do: Enum.find(Model.AtlasEyra.subflows(:prod), &(&1.name() == name))

  test "an accepted decision stays its coordinator's until work is based on it (follow-through)" do
    decision = %{
      "key" => "D-0001",
      "values" => %{"status" => "accepted", "consequences" => "the ledger changes"},
      "links" => %{"assignment" => ["AS-D-0001"]}
    }

    waiting =
      assignment(
        "D-0001",
        %{"flow_state" => "waiting", "expected" => "Carry it out: the ledger changes"},
        ["coordinator"]
      )

    done = [run("decide", "completed", "accepted")]
    a = present("decision", waiting, decision, done)

    assert %{"follow_through" => true, "actionable" => true, "state" => "waiting"} =
             a["presentation"]

    viewer = %{key: "coordinator", kind: "agent"}

    assert %{expected: "Carry it out: the ledger changes", instructions: how} =
             Model.AtlasEyra.todo("decision", decision, %{"assignment" => a}, viewer)

    assert how =~ "no_work"

    # Once work is based on it Flow clears it, and nothing is left to do.
    cleared = present("decision", assignment("D-0001", %{}, []), decision, done)
    assert %{"actionable" => false, "follow_through" => false} = cleared["presentation"]
    assert Model.AtlasEyra.todo("decision", decision, %{"assignment" => cleared}, viewer) == nil
  end

  test "a reopened use case says so to anyone until its run is restarted; a completed one does not" do
    use_case = %{
      "key" => "UC-Atlas-01",
      "values" => %{"design_status" => "accepted"},
      "links" => %{"assignment" => ["AS-UC-Atlas-01"]}
    }

    ended = [run("test_and_accept_use_case", "completed", "accepted")]
    a = present("use_case", assignment("UC-Atlas-01", %{}, []), use_case, ended)

    assert %{
             "reopened" => true,
             "actionable" => false,
             "owner" => [],
             "flow" => "test_and_accept_use_case"
           } =
             a["presentation"]

    for viewer <- [%{key: "someone", kind: "person"}, %{key: nil, kind: nil}] do
      assert %{expected: expected, answers: []} =
               Model.AtlasEyra.todo("use_case", use_case, %{"assignment" => a}, viewer)

      assert expected != ""
    end

    done = present("use_case", assignment("UC-Atlas-01", %{}, []), use_case, ended, true)
    assert done["presentation"]["reopened"] == false

    assert Model.AtlasEyra.todo("use_case", use_case, %{"assignment" => done}, %{
             key: "x",
             kind: "person"
           }) ==
             nil
  end

  test "Accept on the page of a use case in test writes the verdict the run ends on" do
    use_case = %{
      "key" => "UC-Atlas-01",
      "values" => %{"design_status" => "accepted", "verdict" => "none"},
      "links" => %{"assignment" => ["AS-UC-Atlas-01"]}
    }

    tested =
      present(
        "use_case",
        assignment("UC-Atlas-01", %{"flow_state" => "to_test", "expected" => "Test it"}, ["melle"]),
        use_case,
        [run("test_and_accept_use_case", "active", "to_test")]
      )

    answers =
      for {kind, read} <- Pages.reads({:set, "use_case", "UC-Atlas-01", "accepted_by"}, @m) do
        case {kind, read} do
          {"use_case", %{"key" => _}} -> %{"fact" => use_case}
          {"assignment", %{"key" => _}} -> %{"fact" => tested}
          _ -> %{"facts" => []}
        end
      end

    assert %{"self" => "accepted_by", "values" => values} =
             Pages.self_answer(@m, "use_case", "accepted_by", answers)

    # What it writes is what the decider's Accept writes: the run goes to accepted.
    assert values == %{"verdict" => "accept"}
    build = subflow("test_and_accept_use_case")
    assert build.next("to_test", Map.merge(use_case["values"], values), nil) == {:to, "accepted"}

    # Outside that state, Accept sets the link alone.
    building =
      present(
        "use_case",
        assignment("UC-Atlas-01", %{"flow_state" => "building", "expected" => "Build it"}, [
          "coordinator"
        ]),
        use_case,
        [run("test_and_accept_use_case", "active", "building")]
      )

    answers =
      Enum.map(answers, fn
        %{"fact" => %{"key" => "AS-UC-Atlas-01"}} -> %{"fact" => building}
        other -> other
      end)

    assert Pages.self_answer(@m, "use_case", "accepted_by", answers) == nil
  end
end

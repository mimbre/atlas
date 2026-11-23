defmodule Model.RunPresentationTest do
  @moduledoc """
  How Atlas's work is presented from its runs (slice 13), as Facts derives it
  (`AtlasFacts.Presentation`) from the composition's presenters and Control shows it:
  an accepted decision's follow-through, a reopened use case, and Accept on a scene page
  that ends its run as its producer's own Accept does.
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

  test "an accepted decision stays its coordinator's while its follow-through waits for work" do
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

    # decide ended at acceptance; follow_through waits, one presenter for both.
    runs = [run("decide", "completed", "accepted"), run("follow_through", "active", "waiting")]
    a = present("decision", waiting, decision, runs)

    assert %{"flow" => "follow_through", "actionable" => true, "state" => "waiting"} =
             a["presentation"]

    viewer = %{key: "coordinator", kind: "agent"}

    assert %{expected: "Carry it out: the ledger changes", instructions: how} =
             Model.AtlasEyra.todo("decision", decision, %{"assignment" => a}, viewer)

    assert is_binary(how) and how != ""

    # Once work is based on it the run completes, and nothing is left to do, whatever was
    # still written.
    ended = [
      run("decide", "completed", "accepted"),
      run("follow_through", "completed", "carried_out")
    ]

    cleared = present("decision", waiting, decision, ended)
    assert %{"actionable" => false, "status" => "completed"} = cleared["presentation"]
    assert Model.AtlasEyra.todo("decision", decision, %{"assignment" => cleared}, viewer) == nil
  end

  test "a reopened use case says so to anyone until its run is restarted; a completed one does not" do
    use_case = %{
      "key" => "UC-Atlas-01",
      "values" => %{"design_status" => "accepted"},
      "links" => %{"assignment" => ["AS-UC-Atlas-01"]}
    }

    ended = [run("accept_use_case", "completed", "accepted")]
    a = present("use_case", assignment("UC-Atlas-01", %{}, []), use_case, ended)

    assert %{
             "reopened" => true,
             "actionable" => false,
             "owner" => [],
             "flow" => "accept_use_case"
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

  test "Accept on the page of a scene to accept writes the verdict the run ends on" do
    scene = %{
      "key" => "SC-Atlas-01",
      "values" => %{"phase" => "accept", "verdict" => "none"},
      "links" => %{"assignment" => ["AS-SC-Atlas-01"]}
    }

    tested =
      present(
        "scene",
        assignment(
          "SC-Atlas-01",
          %{"flow_state" => "to_accept", "expected" => "Accept the scene"},
          [
            "melle"
          ]
        ),
        scene,
        [run("accept_scene", "active", "to_accept")]
      )

    answers =
      for {kind, read} <- Pages.reads({:set, "scene", "SC-Atlas-01", "accepted_by"}, @m) do
        case {kind, read} do
          {"scene", %{"key" => _}} -> %{"fact" => scene}
          {"assignment", %{"key" => _}} -> %{"fact" => tested}
          _ -> %{"facts" => []}
        end
      end

    assert %{"self" => "accepted_by", "values" => values} =
             Pages.self_answer(@m, "scene", "accepted_by", answers)

    # What it writes is what the decider's Accept writes: the run goes to accepted.
    assert values == %{"verdict" => "accept"}
    accept = subflow("accept_scene")
    assert accept.next("to_accept", Map.merge(scene["values"], values), nil) == {:to, "accepted"}

    # Outside that state, Accept sets the link alone.
    building =
      present(
        "scene",
        assignment("SC-Atlas-01", %{"flow_state" => "building", "expected" => "Build it"}, [
          "coordinator"
        ]),
        scene,
        [run("accept_scene", "active", "building")]
      )

    answers =
      Enum.map(answers, fn
        %{"fact" => %{"key" => "AS-SC-Atlas-01"}} -> %{"fact" => building}
        other -> other
      end)

    assert Pages.self_answer(@m, "scene", "accepted_by", answers) == nil
  end
end

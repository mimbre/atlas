defmodule Model.ToDoRunsTest do
  @moduledoc """
  The To-Do on Flow's durable runs: its owner closes it, Done or Won't do, each with a
  note; nobody else does, and nothing closes it without the note. Its owner is the one
  its Assignment names, a person or an agent; an agent's Runtime works on it as on any
  assigned item. Created like any fact, with the decisions it is based on.
  """
  use ExUnit.Case, async: true

  alias AtlasFlow.Runs.Run

  @now ~U[2026-11-13 00:00:00Z]
  @envs [:prod, :test]
  @name "to_do"

  defp flow(env), do: Enum.find(Model.AtlasEyra.subflows(env), &(&1.name() == @name))
  defp selection, do: Model.AtlasEyra.selection(@name)

  defp subject(values, version \\ "v1"),
    do: %{"key" => "TD-01", "version" => version, "values" => values}

  defp new(env, values),
    do: Run.new(@name, flow(env), subject(values), selection()["imports"], @now)

  # A choice as Facts keeps it once applied: who made it is in its roles.
  defp choice(run, changed, roles),
    do: %{
      "key" => "I-#{run["entry"]}-#{Enum.join(roles)}",
      "run" => run["key"],
      "entry" => run["entry"],
      "status" => "applied",
      "roles" => roles,
      "changed_fields" => changed,
      "position" => 5,
      "subject_version" => "v1",
      "prepared_at" => "2026-11-13T00:01:00Z"
    }

  defp lookup,
    do: %{
      "current" => fn -> %{"values" => %{"title" => "Tidy it", "status" => "open"}} end,
      "fact" => fn _, _ -> nil end,
      "list" => fn _ -> {:ok, []} end,
      "incoming" => fn _, _, _ -> [] end,
      "fingerprint" => &AtlasBus.SubjectFingerprint.of/2
    }

  defp close(values),
    do:
      Model.AtlasEyra.check(
        @name,
        %{"op" => "change", "key" => "TD-01", "values" => values, "links" => %{}},
        %{"by" => "someone"},
        lookup()
      )

  defp presenter, do: Enum.find(Model.AtlasEyra.presentation(), &(&1["subject"] == @name))

  # The To-Do's Assignment as Facts serves it while its run is in `open`.
  defp assigned(owner) do
    assignment = %{
      "key" => "AS-TD-01",
      "values" => %{"flow_state" => "open", "expected" => "Do it"},
      "links" => %{"assigned_to" => [owner]}
    }

    run = %{
      "key" => "R-1",
      "flow" => @name,
      "generation" => 1,
      "status" => "active",
      "state" => "open"
    }

    to_do = %{
      "key" => "TD-01",
      "values" => %{"status" => "open", "instructions" => "Set up the account at the bank."},
      "links" => %{}
    }

    shown = AtlasFacts.Presentation.view(presenter(), assignment, to_do, [run], fn -> false end)
    {to_do, Map.put(assignment, "presentation", shown)}
  end

  test "selected in both environments, runnable, with no gate, review or timer" do
    for env <- @envs do
      runner = AtlasFlow.Model.load(Model.AtlasEyra, env, %{"decider" => "someone"})
      assert runner.refusal == nil
      assert Map.has_key?(runner.config["selection"], @name)

      f = flow(env)
      assert Run.validate(f) == :ok
      assert f.initial() == "open"
      assert Enum.sort(f.states()) == ~w(done open wont_do)
      # Atlas cannot check the work: nothing is dispatched, made or due.
      assert Enum.all?(f.states(), &(f.mechanism(&1) == nil))
      assert Enum.all?(f.states(), &(f.timers(&1) == []))
      assert f.waiting_for("open") == ["assignee"]
    end

    s = selection()
    assert {s["subject"], s["choices"], s["choice_states"]} == {@name, ["status"], ["open"]}
    assert s["admission"] == []
    assert s["reopen"] == "explicit"
    refute Map.has_key?(s, "legacy")
    # Presented on its Assignment, as every assigned item is.
    assert s["projection"]["on"] == "assignment"
    assert s["projection"]["owner_relation"] == "assigned_to"

    # The one who may close it is the one its Assignment names.
    inputs = Model.AtlasEyra.runs()["inputs"]
    assert inputs["roles"]["assignee"] == "assigned_to"
    assert inputs["acl"]["assignee"]["update"] == [@name]
  end

  test "its owner closes it: Done with a note, or Won't do with the reason" do
    for env <- @envs do
      f = flow(env)
      run = new(env, %{"status" => "open"}) |> Map.put("key", "R-1")
      assert {run["state"], run["status"]} == {"open", "active"}

      for {status, final} <- [{"done", "done"}, {"wont_do", "wont_do"}] do
        changed = %{"status" => status, "note" => "Filed the form"}
        written = subject(Map.put(changed, "title", "Tidy it"))

        # Written alone, without the owner's choice, it moves nothing.
        assert {:ok, ^run} = Run.step(run, f, written, @now)

        assert {:ok, %{"state" => ^final, "status" => "completed"}} =
                 Run.step(run, f, written, @now, [choice(run, changed, ["assignee"])])
      end
    end
  end

  test "refused: closed by anyone but its owner, or without a note" do
    for env <- @envs do
      f = flow(env)
      run = new(env, %{"status" => "open"}) |> Map.put("key", "R-1")
      changed = %{"status" => "done", "note" => "Did it"}

      # Someone with another role (or none): the choice is passed over; the run stays open.
      for roles <- [["decider"], []] do
        assert {:ok, passed_over} =
                 Run.step(run, f, subject(changed), @now, [choice(run, changed, roles)])

        assert {passed_over["state"], passed_over["status"], passed_over["entry"]} ==
                 {"open", "active", 1}

        assert passed_over["last_input"]["ignored"] == true
      end
    end

    # Facts refuses either close without a note, and takes it with one.
    for status <- ~w(done wont_do) do
      assert {:refuse, [_]} = close(%{"status" => status})
      assert {:refuse, [_]} = close(%{"status" => status, "note" => ""})
      assert {:refuse, [_]} = close(%{"status" => status, "note" => "  \t\n  "})
      assert close(%{"status" => status, "note" => "How, or why not"}) == :ok
    end

    assert close(%{"note" => "", "status" => "open"}) == :ok

    # The answers are its owner's alone, and each asks for the note it keeps.
    {to_do, assignment} = assigned("ada")
    item = %{"fact" => to_do, "parts" => %{"assignment" => assignment}}

    for key <- ~w(x n) do
      assert {:write, %{"note" => true, "values" => values}} =
               Model.AtlasEyra.answer(@name, key, item, %{key: "ada", kind: "person"})

      assert values["note"] == "$note"

      assert {:error, _} =
               AtlasControl.Answers.change(
                 %{"note" => true, "values" => values},
                 "TD-01",
                 "ada",
                 "",
                 @now
               )

      assert {:refuse, _} =
               Model.AtlasEyra.answer(@name, key, item, %{key: "bo", kind: "person"})
    end
  end

  test "a closed one is completed history; an open one starts in open, as a new one does" do
    for env <- @envs do
      for {values, state, status} <- [
            {%{"status" => "done", "note" => "n"}, "done", "completed"},
            {%{"status" => "wont_do", "note" => "n"}, "wont_do", "completed"},
            {%{"status" => "open"}, "open", "active"},
            {%{}, "open", "active"}
          ] do
        run = new(env, values)
        assert {run["state"], run["status"]} == {state, status}
        assert run["pending"]["writes"] == []
      end
    end
  end

  test "terminal facts stay completed; only an open fact with an ended run is reopened" do
    for env <- @envs, ending <- ~w(done wont_do), status <- [ending, "open"] do
      values = %{"status" => status, "note" => "Closed it", "instructions" => "Do the work"}
      raw = %{key: "TD-01", properties: values, links: %{}}

      assert {:ok, [derived]} =
               Model.AtlasEyra.derived(
                 @name,
                 [raw],
                 Map.merge(lookup(), %{
                   "linked" => fn _, _, _ -> {:ok, []} end,
                   "facts" => fn _, _ -> {:ok, []} end
                 })
               )

      completed? = fn -> get_in(derived, ["completion", "done"]) == true end
      run = new(env, %{"status" => ending, "note" => "Closed it"})
      fact = subject(values)
      assignment = %{"key" => "AS-TD-01", "values" => %{}, "links" => %{}}
      shown = AtlasFacts.Presentation.view(presenter(), assignment, fact, [run], completed?)

      assert shown["status"] == "completed"
      assert shown["actionable"] == false
      assert shown["reopened"] == (status == "open")
      assert shown["owner"] == []

      todo =
        Model.AtlasEyra.todo(
          @name,
          fact,
          %{"assignment" => Map.put(assignment, "presentation", shown)},
          %{key: "ada", kind: "person"}
        )

      if status == "open" do
        assert %{answers: [], instructions: nil, section: nil} = todo
      else
        assert todo == nil
      end

      # Changing the fact does not restart the completed run or change its history.
      assert {:ok, ^run} = Run.step(run, flow(env), fact, @now)
    end
  end

  test "an agent-owned To-Do is open work for Runtime, and the agent may close it" do
    # Runtime starts turns on the facts the turn's items name, owned through their owner
    # relation, while Facts' presentation says there is something to do.
    assert %{"kind" => "assignment", "owner_relation" => "assigned_to"} in Model.AtlasEyra.turn()[
             "items"
           ]

    assert presenter()["kind"] == "assignment"
    {to_do, assignment} = assigned("coordinator")

    assert %{"actionable" => true, "owner" => ["coordinator"], "handover" => nil, "flow" => @name} =
             assignment["presentation"]

    viewer = %{key: "coordinator", kind: "agent"}

    assert %{expected: "Do it", instructions: how, answers: answers} =
             Model.AtlasEyra.todo(@name, to_do, %{"assignment" => assignment}, viewer)

    assert is_binary(how) and how != ""
    assert Enum.map(answers, & &1.key) == ~w(x n)

    # Its own instructions, whole, are what to do: the page, the TUI and the agent's
    # guidance all show this section.
    assert %{section: %{heading: heading, text: text}} =
             Model.AtlasEyra.todo(@name, to_do, %{"assignment" => assignment}, viewer)

    assert is_binary(heading) and heading != ""
    assert text == to_do["values"]["instructions"]
    assert Enum.all?(answers, & &1.note)

    # Its owner by default, while nobody is assigned: the configured decider, a person.
    {:ok, actors} = AtlasBus.Actors.resolve(Model.AtlasEyra.actors(), %{"decider" => "ada"})

    owner = AtlasFlow.Model.owner(flow(:prod).owner("open")["default"], actors)
    assert owner == actors["decider"]
    assert owner["kind"] == "person"
  end

  test "created like any fact: with its Assignment, and the decisions it is based on" do
    create = %{
      "op" => "create",
      "key" => "TD-01",
      "values" => %{
        "title" => "Tidy the scene texts",
        "instructions" => "Make each scene text one paragraph.",
        "status" => "open"
      },
      "links" => %{"based_on" => ["D-0024"]}
    }

    assert [
             %{"as" => "component", "kind" => "assignment", "key" => "AS-TD-01"},
             %{"as" => "fact", "key" => "TD-01", "links" => %{"based_on" => ["D-0024"]}}
           ] = Model.AtlasEyra.with_change(@name, create, lookup())

    assert Model.AtlasEyra.check(@name, create, %{"by" => "someone"}, lookup()) == :ok

    assert @name in Model.AtlasEyra.relations()["based_on"]["from"]
    assert Model.AtlasEyra.relations()["based_on"]["to"] == ["decision"]

    # The form asks what to do; its one deadline is its Assignment's, set when it is
    # handed to someone. The id is TD- and the next number.
    assert %{ask: ["title", "instructions"], defaults: %{"status" => "open"}} =
             Model.AtlasEyra.form(@name, :create)

    kinds = Model.AtlasEyra.kinds()
    refute Enum.any?(Enum.find(kinds, &(&1.name == @name)).fields, &(&1.name == "deadline"))

    assert Enum.any?(
             Enum.find(kinds, &(&1.name == "assignment")).fields,
             &(&1.name == "deadline")
           )

    kind = Enum.find(Model.AtlasEyra.kinds(), &(&1.name == @name))
    assert %{label: "To-Do", plural: "To-Dos", top: true} = kind
    # What to do is required (Rela refuses a To-Do without it).
    assert Enum.find(kind.fields, &(&1.name == "instructions")).required
    assert %{prefix: "TD-", digits: 2} = kind.id
  end
end

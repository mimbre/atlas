defmodule Model.FlowFactsTest do
  @moduledoc """
  F1.2 of the Flow Engine plan (§3.2): the records Flow keeps of the tasks it defines.
  Additive only: `machinery`, `task`, `task_attempt` and `package` are new, every field
  and link of them is Flow's alone (`set_by: [:flow]`), `assigned_to` may also target a
  machinery, and the `turn` kind Runtime's Lifecycle keeps stays exactly as it was.
  """
  use ExUnit.Case, async: true

  alias Model.AtlasEyra

  @new_kinds ~w(machinery task task_attempt package)
  @new_relations ~w(task_of attempt_of ran_on package_of)

  defp description, do: AtlasEyra.__rela__(:description)
  defp schema, do: description().schema
  defp extension, do: description().extension

  # The rules Facts holds a write to, with an empty store.
  defp lookup do
    %{
      "current" => fn -> nil end,
      "fact" => fn _, _ -> nil end,
      "list" => fn _ -> {:ok, []} end,
      "incoming" => fn _, _, _ -> [] end,
      "fingerprint" => &AtlasBus.SubjectFingerprint.of/2
    }
  end

  @flow %{"by" => "flow", "writer" => "flow", "sender" => "flow"}
  @someone %{"by" => "someone"}

  defp create(kind, key, values, links \\ %{}),
    do: {kind, %{"op" => "create", "key" => key, "values" => values, "links" => links}}

  defp check({kind, change}, env), do: AtlasEyra.check(kind, change, env, lookup())

  test "the new kinds, with the keys Flow names them by" do
    entities = schema()["entities"]
    for kind <- @new_kinds, do: assert(Map.has_key?(entities, kind), kind)

    assert entities["task"]["id_type"] == "manual"
    assert entities["task"]["id_prefix"] == "TK-"
    assert entities["task_attempt"]["id_prefix"] == "TA-"
    assert entities["package"]["id_prefix"] == "PK-"
    assert entities["machinery"]["id_type"] == "manual"

    assert entities["task"]["properties"]["kind"]["type"] == "task_kind"
    assert schema()["types"]["task_kind"]["values"] == ~w(plan author review fix)
    assert schema()["types"]["task_role"]["values"] == ~w(architect developer)
    assert schema()["types"]["task_verdict"]["values"] == ~w(approved changes_required)

    # §3.2's fields, no more: F3's (change id, review id, fpr_, PR URL; published_*) wait.
    assert Enum.sort(Map.keys(entities["task"]["properties"])) ==
             Enum.sort(~w(kind role profile input client_key work_id attempt state result_kind
               reason check_exit_status check_ending check_output_tail verdict answer
               result_fingerprints based_on base_id base_snapshot base_revision))

    assert Enum.sort(Map.keys(entities["task_attempt"]["properties"])) ==
             Enum.sort(~w(turn_id state result_kind provider harness harness_version
               configured_model reported_model selection_reason conversation_id machine slot
               started_at ended_at))

    # F1.4 adds the result field its subflow's task branches read (never written).
    assert Enum.sort(Map.keys(entities["package"]["properties"])) ==
             Enum.sort(~w(title instructions acceptance after state task_result))

    assert Map.keys(entities["machinery"]["properties"]) == ["name"]
  end

  test "every field and link of the new kinds is Flow's alone" do
    for kind <- @new_kinds,
        {name, _} <- schema()["entities"][kind]["properties"] do
      assert get_in(extension(), ["entities", kind, "properties", name, "set_by"]) == ["flow"],
             "#{kind}.#{name} is not set_by: [:flow]"
    end

    for relation <- @new_relations do
      assert get_in(extension(), ["relations", relation, "set_by"]) == ["flow"],
             "#{relation} is not set_by: [:flow]"
    end

    # Facts holds it so: Flow writes a task; anyone else is refused, field and link.
    task = create("task", "TK-PK-IS-Atlas-01-1-1", %{"kind" => "author", "state" => "waiting"})
    assert check(task, @flow) == :ok
    assert {:refuse, [why]} = check(task, @someone)
    assert why =~ "protected fields"

    for kind <- @new_kinds,
        {name, _} <- schema()["entities"][kind]["properties"] do
      assert {:refuse, [why]} = check(create(kind, "X-1", %{name => "x"}), @someone),
             "#{kind}.#{name} is written by someone other than Flow"

      assert why == "protected fields: #{name}"
    end

    linked =
      create("task", "TK-PK-IS-Atlas-01-1-1", %{}, %{"task_of" => ["PK-IS-Atlas-01-1"]})

    assert {:refuse, [why]} = check(linked, @someone)
    assert why =~ "only a flow sets task_of"
  end

  test "a package is a child of an issue; a task of a package or an issue; an attempt of a task" do
    relations = schema()["relations"]

    assert %{"from" => ["package"], "to" => ["issue"], "max_outgoing" => 1} =
             relations["package_of"]

    assert %{"from" => ["task"], "to" => ["package", "issue"], "max_outgoing" => 1} =
             relations["task_of"]

    assert %{"from" => ["task_attempt"], "to" => ["task"]} = relations["attempt_of"]
    assert %{"from" => ["task_attempt"], "to" => ["machinery"]} = relations["ran_on"]

    for relation <- ~w(package_of task_of attempt_of),
        do: assert(get_in(extension(), ["relations", relation, "parent"]) == true, relation)

    # in_issue stays the pull request's alone: its limit and the issue's completion read
    # a pull request's state.
    assert relations["in_issue"]["from"] == ["pull_request"]
  end

  test "an assignment may be assigned to a person, an agent or a machinery" do
    assert schema()["relations"]["assigned_to"]["to"] == ["person", "agent", "machinery"]
    assert schema()["relations"]["assigned_to"]["max_outgoing"] == 1
  end

  test "foundation alone has machinery, tasks and their attempts, but no packages" do
    entities = Model.Profiles.Foundation.__rela__(:description).schema["entities"]
    for kind <- ~w(machinery task task_attempt), do: assert(Map.has_key?(entities, kind))
    refute Map.has_key?(entities, "package")
  end

  # Lifecycle, Facts guidance and Control's worker pages read the turn kind as it is; it
  # goes with Lifecycle (Runtime S5b), never changed by Flow (§3.2).
  test "Lifecycle's turn declaration is unchanged" do
    assert AtlasEyra.turn() |> Map.drop(["items", "on_kinds"]) == %{
             "kind" => "turn",
             "key" => "TU-{on}-{n}",
             "on" => "turn_on",
             "by" => "turn_by",
             "state" => "state",
             "running" => "running",
             "ended" => "ended",
             "machine" => "machine",
             "lease" => "lease_until",
             "activity" => "activity",
             "why" => "why",
             "ended_at" => "ended_at",
             "outcome" => "outcome",
             "attempt" => "attempt",
             "title" => "title",
             "model" => "model"
           }

    assert AtlasEyra.turn()["on_kinds"] == ["assignment"]
    assert AtlasEyra.agent() == %{"kind" => "agent", "cannot_run" => "cannot_run"}

    turn = schema()["entities"]["turn"]
    assert turn["id_type"] == "manual"
    assert turn["id_prefix"] == "TU-"

    assert Map.new(turn["properties"], fn {name, p} -> {name, {p["type"], p["required"]}} end) ==
             %{
               "state" => {"turn_state", true},
               "machine" => {"string", true},
               "lease_until" => {"datetime", nil},
               "activity" => {"string", nil},
               "why" => {"string", nil},
               "ended_at" => {"datetime", nil},
               "outcome" => {"string", nil},
               "attempt" => {"string", nil},
               "title" => {"string", nil},
               "model" => {"string", nil}
             }

    set_by =
      Map.new(extension()["entities"]["turn"]["properties"], fn {name, p} ->
        {name, p["set_by"]}
      end)

    assert set_by == %{
             "state" => ["runtime"],
             "machine" => ["runtime"],
             "lease_until" => ["runtime"],
             "activity" => ["runtime"],
             "why" => ["runtime"],
             "ended_at" => ["runtime"],
             "outcome" => ["turn_owner"],
             "attempt" => ["runtime"],
             "title" => ["runtime"],
             "model" => ["runtime"]
           }

    assert schema()["types"]["turn_state"]["values"] == ["running", "ended"]

    assert schema()["relations"]["turn_on"] == %{
             "label" => "on",
             "description" => "The item the turn acts on.",
             "from" => ["turn"],
             "to" => ["assignment"],
             "max_outgoing" => 1,
             "inverse" => %{"id" => "turns", "label" => "turns"}
           }

    assert schema()["relations"]["turn_by"] == %{
             "label" => "by",
             "description" => "The agent that acts in the turn.",
             "from" => ["turn"],
             "to" => ["agent"],
             "max_outgoing" => 1,
             "inverse" => %{"id" => "turns_by", "label" => "turns"}
           }
  end
end

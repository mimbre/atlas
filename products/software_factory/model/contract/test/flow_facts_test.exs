defmodule Model.FlowFactsTest do
  @moduledoc """
  F1.2 of the Flow Engine plan (§3.2): the records Flow keeps of the tasks it defines.
  Additive only: `machinery`, `task` and `task_attempt` are new, every field
  and link of them is Flow's alone (`set_by: [:flow]`), `assigned_to` may also target a
  machinery, and the `turn` kind Runtime's Lifecycle keeps stays exactly as it was.

  M3 P2 adds the lease fields Flow keeps as the Runtime's work source (decision
  2026-11-17 §6.2), additive as well: Flow's alone, on `task` and `task_attempt` only.

  IS-Atlas-100 retired the `package` kind, its `package_of` relation, and the task fields
  of the review → fix ladder, Landing's publication and the stored change set: a result
  travels over Git (`result_ref`).
  """
  use ExUnit.Case, async: true

  alias Model.AtlasEyra

  @new_kinds ~w(machinery task task_attempt)
  @new_relations ~w(task_of attempt_of ran_on)

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

  # The lease fields (M3 P2) and their types.
  @task_lease %{
    "lease_id" => "string",
    "runtime" => "string",
    "expires_at" => "datetime",
    "granted_at" => "datetime",
    "lease_state" => "string",
    "lease_end_cause" => "string",
    "lease_revision" => "integer",
    "lease_report" => "string",
    "result_ref" => "string"
  }
  @attempt_lease %{"lease_id" => "string"}

  @flow %{"by" => "flow", "writer" => "flow", "sender" => "flow"}
  @someone %{"by" => "someone"}
  # A person's write from a TUI session, and one that also claims to be Flow.
  @session %{"by" => "holder-1", "writer" => "holder-1", "sender" => "control/session-1"}
  @posing %{"by" => "flow", "writer" => "flow", "sender" => "control/session-1"}

  defp create(kind, key, values, links \\ %{}),
    do: {kind, %{"op" => "create", "key" => key, "values" => values, "links" => links}}

  defp check({kind, change}, env), do: AtlasEyra.check(kind, change, env, lookup())

  test "the new kinds, with the keys Flow names them by" do
    entities = schema()["entities"]
    for kind <- @new_kinds, do: assert(Map.has_key?(entities, kind), kind)

    assert entities["task"]["id_type"] == "manual"
    assert entities["task"]["id_prefix"] == "TK-"
    assert entities["task_attempt"]["id_prefix"] == "TA-"
    refute Map.has_key?(entities, "package")
    assert entities["machinery"]["id_type"] == "manual"

    assert entities["task"]["properties"]["kind"]["type"] == "task_kind"
    # F2 adds the diagnose kind and its investigator role.
    assert schema()["types"]["task_kind"]["values"] == ~w(plan author review fix diagnose)
    assert schema()["types"]["task_role"]["values"] == ~w(architect developer investigator)
    assert schema()["types"]["task_verdict"]["values"] == ~w(approved changes_required)

    # §3.2's fields and M3's lease fields, no more: nothing of the ladder, Landing or a
    # stored change set (IS-Atlas-100).
    assert Enum.sort(Map.keys(entities["task"]["properties"])) ==
             Enum.sort(
               ~w(kind role profile input client_key work_id attempt state result_kind
               reason check_exit_status check_ending check_output_tail verdict answer
               base_id base_snapshot) ++
                 Map.keys(@task_lease)
             )

    assert Enum.sort(Map.keys(entities["task_attempt"]["properties"])) ==
             Enum.sort(~w(turn_id state result_kind provider harness harness_version
               configured_model reported_model selection_reason conversation_id machine slot
               started_at ended_at) ++ Map.keys(@attempt_lease))

    # IS-Atlas-27: the Runtime's configuration, and what the Runtime did with it;
    # IS-Atlas-116: the digest of its credential, and the build and incarnation it polls from.
    assert Enum.sort(Map.keys(entities["machinery"]["properties"])) ==
             ~w(applied_version configuration credential_sha256 name refused_reason
               refused_version runtime_build runtime_incarnation)
  end

  test "a supervisor makes a machinery with its credential's digest; what a poll says is Flow's (IS-Atlas-116)" do
    sha = String.duplicate("ab", 32)
    made = create("machinery", "new-mac", %{"name" => "new-mac", "credential_sha256" => sha})
    assert check(made, @session) == :ok

    assert get_in(extension(), ["relations", "runs_for", "set_by"]) == nil
    assert get_in(schema(), ["relations", "runs_for", "from"]) == ["machinery"]
    assert get_in(schema(), ["relations", "runs_for", "to"]) == ["person"]

    for field <- ~w(runtime_build runtime_incarnation) do
      assert {:refuse, [why]} =
               check(create("machinery", "new-mac", %{"name" => "x", field => "y"}), @session)

      assert why =~ "protected fields"
      assert check(create("machinery", "new-mac", %{"name" => "x", field => "y"}), @flow) == :ok
    end
  end

  test "every field and link of the new kinds is Flow's alone" do
    # A person sets a Runtime's configuration (IS-Atlas-27), and makes a machinery, naming
    # it, with its credential's digest (IS-Atlas-116): no set_by.
    by_hand = [
      {"machinery", "configuration"},
      {"machinery", "name"},
      {"machinery", "credential_sha256"}
    ]

    for {kind, name} <- by_hand,
        do: assert(get_in(extension(), ["entities", kind, "properties", name, "set_by"]) == nil)

    for kind <- @new_kinds,
        {name, _} <- schema()["entities"][kind]["properties"],
        {kind, name} not in by_hand do
      assert get_in(extension(), ["entities", kind, "properties", name, "set_by"]) == ["flow"],
             "#{kind}.#{name} is not set_by: [:flow]"
    end

    for relation <- @new_relations do
      assert get_in(extension(), ["relations", relation, "set_by"]) == ["flow"],
             "#{relation} is not set_by: [:flow]"
    end

    # Facts holds it so: Flow writes a task; anyone else is refused, field and link.
    task = create("task", "TK-IS-Atlas-01-1", %{"kind" => "author", "state" => "waiting"})
    assert check(task, @flow) == :ok
    assert {:refuse, [why]} = check(task, @someone)
    assert why =~ "protected fields"

    for kind <- @new_kinds,
        {name, _} <- schema()["entities"][kind]["properties"],
        {kind, name} not in by_hand do
      assert {:refuse, [why]} = check(create(kind, "X-1", %{name => "x"}), @someone),
             "#{kind}.#{name} is written by someone other than Flow"

      assert why == "protected fields: #{name}"
    end

    linked = create("task", "TK-IS-Atlas-01-1", %{}, %{"task_of" => ["IS-Atlas-01"]})

    assert {:refuse, [why]} = check(linked, @someone)
    assert why =~ "only a flow sets task_of"

    # Anyone may write a Runtime's configuration.
    assert check(create("machinery", "X-1", %{"configuration" => "{}"}), @someone) == :ok
  end

  test "F2: a diagnose task by an investigator is Flow's to write" do
    diagnose =
      create("task", "TK-IS-Atlas-01-4", %{
        "kind" => "diagnose",
        "role" => "investigator",
        "profile" => "deep_coding"
      })

    assert check(diagnose, @flow) == :ok
    assert {:refuse, [_]} = check(diagnose, @someone)
  end

  test "the lease fields: on task and task_attempt, typed, optional, Flow's alone" do
    for {kind, fields} <- [{"task", @task_lease}, {"task_attempt", @attempt_lease}],
        {name, type} <- fields do
      property = schema()["entities"][kind]["properties"][name]
      assert property, "#{kind}.#{name} is missing"
      assert property["type"] == type, "#{kind}.#{name}: type"
      refute property["required"], "#{kind}.#{name}: required"

      assert get_in(extension(), ["entities", kind, "properties", name, "set_by"]) == ["flow"],
             "#{kind}.#{name}: set_by"
    end

    # The two kinds stay records: never top, never made by hand.
    for kind <- ~w(task task_attempt),
        do:
          assert(
            Map.take(extension()["entities"][kind], ["top", "by_hand"]) ==
              %{"top" => false, "by_hand" => false},
            kind
          )
  end

  test "only Flow sets a lease: a TUI session's write is refused, even one that claims Flow" do
    lease = %{"lease_id" => "TK-X-1~1~lease", "runtime" => "rt-1", "lease_state" => "offered"}

    for {kind, key, values} <- [
          {"task", "TK-X-1", lease},
          {"task", "TK-X-1", Map.take(lease, ["lease_id"])},
          {"task_attempt", "TA-TK-X-1-1", Map.take(lease, ["lease_id"])}
        ] do
      change = create(kind, key, values)
      assert check(change, @flow) == :ok, kind
      assert {:refuse, [_ | _]} = check(change, @session), kind
      assert {:refuse, [_ | _]} = check(change, @posing), kind
    end
  end

  test "a task of an issue, a use case or a scene; an attempt of a task; no package" do
    relations = schema()["relations"]

    refute Map.has_key?(relations, "package_of")
    assert %{"from" => ["task"], "to" => to, "max_outgoing" => 1} = relations["task_of"]
    assert Enum.sort(to) == ~w(issue scene use_case)

    assert %{"from" => ["task_attempt"], "to" => ["task"]} = relations["attempt_of"]
    assert %{"from" => ["task_attempt"], "to" => ["machinery"]} = relations["ran_on"]

    for relation <- ~w(task_of attempt_of),
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

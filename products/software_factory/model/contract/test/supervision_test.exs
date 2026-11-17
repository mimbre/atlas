defmodule Model.SupervisionTest do
  @moduledoc """
  M3a of the work-acquisition decision (2026-11-17, §5.6–5.8, §6.6): "you supervise a
  flow; you never own an item". Additive only: a run's human supervisor
  (`supervised_by`, written by Flow alone), the pickup and hand-over inputs, the issue
  build's span, a task's `done_for`, and the two start page entries. Existing kinds,
  relations and run digests stay as they were. Structure, not wording.
  """
  use ExUnit.Case, async: true

  alias Model.AtlasEyra

  defp description, do: AtlasEyra.__rela__(:description)
  defp schema, do: description().schema
  defp extension, do: description().extension
  defp committed(path), do: JSON.decode!(File.read!(Path.join("../targets", path)))

  defp lookup do
    %{
      "current" => fn -> nil end,
      "fact" => fn _, _ -> nil end,
      "list" => fn _ -> {:ok, []} end,
      "incoming" => fn _, _, _ -> [] end,
      "fingerprint" => &AtlasBus.SubjectFingerprint.of/2
    }
  end

  @someone %{"by" => "someone"}

  defp check(kind, change, env), do: AtlasEyra.check(kind, change, env, lookup())

  test "a run has at most one human supervisor, a person, and a task whom it is done for" do
    relations = schema()["relations"]

    for {relation, from} <- [{"supervised_by", "flow_run"}, {"done_for", "task"}] do
      assert %{"from" => [^from], "to" => ["person"], "max_outgoing" => 1} =
               relations[relation]

      assert get_in(extension(), ["relations", relation, "set_by"]) == ["flow"], relation
    end
  end

  test "only Flow sets a run's supervisor or a task's done_for: Facts refuses anyone else" do
    for {kind, key, relation} <- [
          {"flow_run", "RUN-1", "supervised_by"},
          {"task", "TK-PK-IS-Atlas-01-1-1", "done_for"}
        ] do
      change = %{
        "op" => "create",
        "key" => key,
        "values" => %{},
        "links" => %{relation => ["melle"]}
      }

      assert {:refuse, [why]} = check(kind, change, @someone), relation
      assert why =~ relation
    end
  end

  test "a supervisor is a link, never a field of the run: Flow's run writes keep it" do
    # Flow writes every field of its run mapping on each write; supervised_by is none.
    assert Enum.sort(Map.keys(AtlasEyra.runs()["fields"])) ==
             Enum.sort(~w(flow subject_kind subject_key generation definition_sha256 state
               entry entered_at status deadlines pending input_cursor last_input blocked_reason))

    refute Map.has_key?(schema()["entities"]["flow_run"]["properties"], "supervised_by")
  end

  test "pickup and hand-over are flow inputs: an operation and the person handed to" do
    properties = schema()["entities"]["flow_input"]["properties"]
    operation = properties["operation"]["type"]

    assert Enum.sort(schema()["types"][operation]["values"]) ==
             Enum.sort(~w(choice pickup hand_over))

    assert properties["hand_to"]["type"] == "string"
    refute properties["operation"]["required"] || properties["hand_to"]["required"]

    supervision = AtlasEyra.supervision()

    assert %{"operation" => "operation", "hand_to" => "hand_to"} =
             supervision["inputs"]

    assert supervision["inputs"]["operations"] == ~w(pickup hand_over)

    # Mapped as every other field of an input, so Facts keeps them with it.
    fields = AtlasEyra.runs()["inputs"]["fields"]
    assert fields["operation"] == "operation" and fields["hand_to"] == "hand_to"
    assert supervision["relation"] == "supervised_by"
  end

  test "the issue build is the one span: its author state, with its packages' runs" do
    assert %{"issue" => [%{"name" => "build", "states" => ["author"], "with" => ["package"]}]} =
             AtlasEyra.supervision()["spans"]

    flows = committed("atlas/flows.json")["flows"]

    for {subflow, spans} <- AtlasEyra.supervision()["spans"], span <- spans do
      for state <- span["states"] do
        assert flows[subflow]["states"][state]["final"] == false, "#{subflow}.#{state}"
      end

      for other <- span["with"] do
        child = flows[other]["subject"]
        parent = flows[subflow]["subject"]

        assert Enum.any?(schema()["relations"], fn {_, r} ->
                 child in r["from"] and parent in r["to"]
               end),
               "#{other} runs on no fact under #{subflow}"
      end
    end
  end

  test "S3: in a spanned subflow, every gate's person outcome lies in a span or owns itself" do
    flows = committed("atlas/flows.json")
    gates = flows["gates"]

    for {subflow, spans} <- AtlasEyra.supervision()["spans"],
        spanned = Enum.flat_map(spans, & &1["states"]),
        {_name, state} <- flows["flows"][subflow]["states"],
        state["kind"] == "gate",
        person = gates[state["spec"]["gate"]]["person"],
        branch <- state["branches"],
        branch["when"] == "entity.gate_result == '#{person}'" do
      target = flows["flows"][subflow]["states"][branch["to"]]
      assert branch["to"] in spanned or target["owner"] != nil, "#{subflow}: #{branch["to"]}"
    end
  end

  test "the spans sit beside the subflows: no definition, digest or Rela flow holds them" do
    for {_name, flow} <- committed("atlas/flows.json")["flows"] do
      refute Map.has_key?(flow, "spans")
      refute Map.has_key?(flow, "supervision")
    end

    refute File.read!("../targets/rela/flows.yaml") =~ "supervise"

    # The committed proof is the compiled one: no run identity moved.
    proof = committed("proof/digests.json")

    for {env, by_name} <- AtlasEyra.__rela__(:digests), {name, %{digest: digest}} <- by_name do
      assert get_in(proof, ["subflows", to_string(name), to_string(env), "digest"]) == digest
    end
  end

  test "the committed run mapping holds the compiled supervision" do
    assert committed("rela/flow-runtime.json")["flow_runtime"]["supervision"] ==
             AtlasEyra.supervision()
  end

  test "the start page: Open for you and Supervised by you, beside Assigned to you" do
    start = AtlasEyra.start_page()
    assert %{relation: "assigned_to"} = start.assigned

    assert %{spans: spans} = open = start.open_for_you
    assert [%{subflow: "issue", subject: "issue", span: "build", states: ["author"]}] = spans
    assert %{relation: "supervised_by"} = mine = start.supervised_by_you

    for entry <- [open, mine], key <- [:title, :count, :empty] do
      assert is_binary(entry[key]) and entry[key] != "", "#{key}"
    end

    assert open.count =~ "{count}" and mine.count =~ "{count}"
  end

  test "foundation alone maps supervision, with no span to pick up" do
    assert %{"relation" => "supervised_by", "spans" => spans} =
             Model.Profiles.Foundation.supervision()

    assert spans == %{}
    assert %{open_for_you: nil, supervised_by_you: nil} = Model.Profiles.Foundation.start_page()
  end
end

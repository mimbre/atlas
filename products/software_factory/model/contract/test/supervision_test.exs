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
  @flow %{"by" => "flow", "writer" => "flow", "sender" => "flow"}

  # Writers that are not Flow: a person in a Control session, an agent, the Runtime, a
  # migration, a name that only starts like Flow's, and an unnamed one.
  @not_flow [
    %{"by" => "melle", "writer" => "melle", "sender" => "control/session-1"},
    %{"by" => "agent", "writer" => "agent", "sender" => "agent"},
    %{"by" => "runtime", "writer" => "runtime", "sender" => "runtime"},
    %{"by" => "migration", "writer" => "migration", "sender" => "migration"},
    %{"by" => "flowx", "writer" => "flowx", "sender" => "flowx"},
    @someone
  ]

  @links [
    {"flow_run", "RUN-1", "supervised_by"},
    {"task", "TK-PK-IS-Atlas-01-1-1", "done_for"}
  ]

  defp check(kind, change, env), do: AtlasEyra.check(kind, change, env, lookup())

  # The same check against a store that already holds `key` linked to `melle`.
  defp check_stored(kind, key, relation, change, env) do
    stored = %{"key" => key, "values" => %{}, "links" => %{relation => ["melle"]}}
    AtlasEyra.check(kind, change, env, %{lookup() | "current" => fn -> stored end})
  end

  defp create_with(key, relation),
    do: %{"op" => "create", "key" => key, "values" => %{}, "links" => %{relation => ["melle"]}}

  defp clear(key, relation),
    do: %{"op" => "change", "key" => key, "values" => %{}, "links" => %{relation => []}}

  test "a run has at most one human supervisor, a person, and a task whom it is done for" do
    relations = schema()["relations"]

    for {relation, from} <- [{"supervised_by", "flow_run"}, {"done_for", "task"}] do
      assert %{"from" => [^from], "to" => ["person"], "max_outgoing" => 1} =
               relations[relation]

      assert get_in(extension(), ["relations", relation, "set_by"]) == ["flow"], relation
    end
  end

  test "Flow sets and clears a run's supervisor and a task's done_for" do
    for {kind, key, relation} <- @links do
      assert check(kind, create_with(key, relation), @flow) == :ok, relation
      assert check_stored(kind, key, relation, clear(key, relation), @flow) == :ok, relation
    end
  end

  test "only Flow sets a run's supervisor or a task's done_for: Facts refuses anyone else" do
    for {kind, key, relation} <- @links, env <- @not_flow do
      assert {:refuse, [why]} = check(kind, create_with(key, relation), env), relation
      assert why =~ relation

      assert {:refuse, [why]} = check_stored(kind, key, relation, clear(key, relation), env),
             relation

      assert why =~ relation
    end
  end

  test "on a run, Flow's name from another sender is refused too" do
    env = %{@flow | "sender" => "control/session-1"}
    {kind, key, relation} = {"flow_run", "RUN-1", "supervised_by"}

    assert {:refuse, [_]} = check(kind, create_with(key, relation), env)
    assert {:refuse, [_]} = check_stored(kind, key, relation, clear(key, relation), env)
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
             Enum.sort(~w(choice pickup hand_over retry))

    assert properties["hand_to"]["type"] == "string"
    refute properties["operation"]["required"] || properties["hand_to"]["required"]

    supervision = AtlasEyra.supervision()

    assert %{"operation" => "operation", "hand_to" => "hand_to"} =
             supervision["inputs"]

    assert supervision["inputs"]["operations"] == ~w(pickup hand_over retry)

    # Mapped as every other field of an input, so Facts keeps them with it.
    fields = AtlasEyra.runs()["inputs"]["fields"]
    assert fields["operation"] == "operation" and fields["hand_to"] == "hand_to"
    assert supervision["relation"] == "supervised_by"
  end

  test "the issue build is the one span: its states until merged, with its packages' runs" do
    states =
      ~w(working reviewing fixing publishing checking ci_fixing ci_fixing_again ci_pushing ci_failing updating update_pushing update_failing merging unchanged stuck review_stuck)

    assert %{
             "issue" => [
               %{"name" => "build", "states" => ^states, "with" => ["package", "pull_request"]}
             ]
           } =
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

    assert %{subject: "issue", span: "build", states: ["working" | _]} =
             Enum.find(spans, &(&1.subflow == "issue"))

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

  # -- M3b (P2): the screens' tabs and a supervisor's running work ------------------------

  test "the shell: a tab for each screen, labelled as its start entry, beside today's tabs" do
    tabs = AtlasEyra.shell(%{})["tabs"]
    start = AtlasEyra.start_page()

    # Melle (2026-11-24): most urgent first, Assigned to you first; then what one browses,
    # the products first (SC-Atlas-20: a product's page lists its scenes).
    assert Enum.map(tabs, & &1["id"]) ==
             ~w(assigned supervised_by_you open_for_you products scenes agents to_dos agent_requests)

    for {id, to, entry} <- [
          {"open_for_you", "/_open", start.open_for_you},
          {"supervised_by_you", "/_supervised", start.supervised_by_you}
        ] do
      tab = Enum.find(tabs, &(&1["id"] == id))
      assert tab["to"] == to, id
      assert tab["label"] == entry.title, id
      refute Map.has_key?(tab, "assigned"), id
    end
  end

  test "Supervised by you's work: a kind, under the span's subjects, done for the supervisor" do
    %{kind: kind, of: of, for: for_, ended: ended} = AtlasEyra.start_page().supervised_by_you.work
    relations = schema()["relations"]

    assert Map.has_key?(schema()["entities"], kind)
    assert Map.has_key?(schema()["entities"][kind]["properties"], ended)
    refute schema()["entities"][kind]["properties"][ended]["required"]

    # Whom it is done for is the supervisor's kind.
    assert kind in relations[for_]["from"]
    assert relations[for_]["to"] == relations[AtlasEyra.supervision()["relation"]]["to"]

    # What it is part of: the span's subject, or the subject of one of its with: subflows.
    assert kind in relations[of]["from"]
    flows = committed("atlas/flows.json")["flows"]

    for span <- AtlasEyra.start_page().open_for_you.spans do
      subjects = [span.subject | Enum.map(span.with, &flows[&1]["subject"])]
      assert Enum.any?(subjects, &(&1 in relations[of]["to"])), span.span
    end

    assert AtlasEyra.supervision()["work"] ==
             %{"kind" => kind, "of" => of, "for" => for_, "ended" => ended}
  end

  test "what Control sends and reads by: the inputs' kind, the relation, the with: subjects" do
    %{open_for_you: open, supervised_by_you: mine} = AtlasEyra.start_page()
    flows = committed("atlas/flows.json")["flows"]

    for entry <- [open, mine] do
      assert entry.inputs == committed("rela/flow-runtime.json")["flow_runtime"]["inputs"]["kind"]
      assert entry.relation == AtlasEyra.supervision()["relation"]
    end

    for span <- open.spans do
      assert span.with_subjects == Enum.map(span.with, &flows[&1]["subject"]), span.span
      assert Enum.all?(span.with_subjects, &Map.has_key?(schema()["entities"], &1)), span.span

      # What the span's subflow makes under its subject: the kinds its tasks create.
      assert span.creates ==
               Enum.uniq(
                 for {_, s} <- flows[span.subflow]["states"],
                     kind = get_in(s, ["spec", "creates", "kind"]),
                     do: kind
               ),
             span.span
    end

    # Plan makes a use case's issues, Design a scene's use cases.
    assert %{"use_case" => ["issue"], "scene" => ["use_case"]} =
             Map.new(open.spans, &{&1.subject, &1.creates})
  end

  test "foundation alone declares no running work" do
    refute Map.has_key?(Model.Profiles.Foundation.supervision(), "work")
  end

  test "the Console opens on Assigned to you, which the shell names; the work tabs, then browse" do
    shell = AtlasEyra.shell(%{})
    default = Enum.find(shell["tabs"], &(&1["id"] == shell["default"]))

    # The tab whose page is the start page's assigned list.
    assert %{"to" => "/", "assigned" => true} = default
    assert start_page_assigned?()

    {work, browse} = Enum.split_with(shell["tabs"], &(&1["section"] == "work"))

    assert Enum.map(shell["tabs"], & &1["section"]) ==
             ~w(work work work browse browse browse browse browse)

    assert Enum.map(work, & &1["id"]) == ~w(assigned supervised_by_you open_for_you)

    # Every browse tab has its own `g` key; the start page holds only what is assigned, no
    # ways to other lists (Melle, 2026-11-24).
    keys = Enum.map(browse, & &1["key"])
    assert Enum.all?(keys, &String.starts_with?(&1, "g ")) and keys == Enum.uniq(keys)
    assert AtlasEyra.start_page().actions == []
  end

  test "Q4 boot: Control's shell opens a person on Assigned to you, the screens are tabs" do
    old = Application.get_env(:atlas_bus, :environment)
    Application.put_env(:atlas_bus, :environment, old || "test")
    on_exit(fn -> if old == nil, do: Application.delete_env(:atlas_bus, :environment) end)

    m = AtlasControl.Model.catalog(AtlasEyra)
    shell = AtlasEyra.shell(%{})
    person = hd(m.relations[AtlasEyra.start_page().assigned.relation].to)

    # With no target, the default tab, Assigned to you; every model tab is offered.
    assert {:ok, booted} = AtlasControl.Shell.boot(m, person)
    assert booted["active_tab"] == shell["default"]
    assert booted["initial_to"] == Enum.find(shell["tabs"], &(&1["id"] == shell["default"]))["to"]
    assert Enum.map(booted["tabs"], & &1["id"]) == Enum.map(shell["tabs"], & &1["id"])

    # Each screen is a boot target of its own.
    for id <- ~w(open_for_you supervised_by_you) do
      to = Enum.find(shell["tabs"], &(&1["id"] == id))["to"]

      assert {:ok, %{"initial_to" => ^to, "active_tab" => ^id}} =
               AtlasControl.Shell.boot(m, person, to)
    end

    # Every tab has its icon; the screens carry their groups, each a boot target that
    # keeps its tab: Build is a group of Open for you.
    tabs = Map.new(booted["tabs"], &{&1["id"], &1})
    assert Enum.all?(booted["tabs"], &is_binary(&1["icon"]))

    for id <- ~w(open_for_you supervised_by_you assigned) do
      assert [_ | _] = groups = tabs[id]["groups"]
      to = hd(groups)["to"]

      assert {:ok, %{"initial_to" => ^to, "active_tab" => ^id}} =
               AtlasControl.Shell.boot(m, person, to)
    end

    # Open for you groups by flow, each labelled by its name.
    assert Enum.map(tabs["open_for_you"]["groups"], & &1["label"]) == ["Design", "Plan", "Build"]
  end

  defp start_page_assigned?, do: match?(%{relation: _}, AtlasEyra.start_page().assigned)
end

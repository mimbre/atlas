defmodule AtlasRuntimeBoundary.WorkTest do
  use ExUnit.Case, async: true

  alias AtlasRuntimeBoundary.Work

  # Design 2026-11-16-runtime-bff §3, written out by hand: a change to the contract's shape
  # must change this file too.

  @states [
    :buffered,
    :starting,
    :running,
    :cancelling,
    :completed,
    :failed,
    :crashed,
    :interrupted,
    :cancelled,
    :returned
  ]
  @kinds [:completed, :failed, :crashed, :interrupted, :cancelled, :returned]
  @stages [:requested, :signalled, :forced]

  defp f(name, type, required \\ false), do: %{name: name, type: type, required: required}

  defp expected_models do
    %{
      client: [
        f(:id, :string, true),
        f(
          :rights,
          {:list, {:enum, [:submit, :cancel, :read, :read_all, :choose_slot, :choose_path]}},
          true
        )
      ],
      work_request: [
        f(:client_key, :string),
        f(:title, :string, true),
        f(:instructions, :string, true),
        f(:profile, :string, true),
        f(:cost_class, {:enum, [:low, :standard, :high]}, true),
        f(:workspace, {:one_of, [:repository, :folder], tag: :kind}, true),
        f(:resume_from, :string),
        f(:slot, :string)
      ],
      repository: [f(:url, :string, true), f(:branch, :string, true), f(:base, :string, true)],
      # D44: a work shows the path only to a client holding choose_path.
      folder: [
        f(:path, :string),
        f(:permissions, {:enum, [:"read-only", :"workspace-write", :"materialized-folder"]}, true)
      ],
      capacity: [
        f(:slots, :slot_counts, true),
        f(:buffer, :buffer_counts, true),
        f(:profiles, {:list, :profile_availability}, true),
        f(:accepting, :boolean, true),
        f(:policy_version, :integer, true),
        f(:runtime_build, :string, true),
        f(:incarnation, :string, true),
        f(:retry_after, :integer)
      ],
      slot_counts: [f(:total, :integer, true), f(:busy, :integer, true), f(:free, :integer, true)],
      buffer_counts: [
        f(:size, :integer, true),
        f(:used, :integer, true),
        f(:free, :integer, true)
      ],
      profile_availability: [
        f(:profile, :string, true),
        f(:available, :boolean, true),
        f(:reason, {:enum, [:quota, :no_permitted_option, :not_installed]}),
        f(:until, :datetime)
      ],
      work: [
        f(:work_id, :string, true),
        f(:client, :string, true),
        f(:client_key, :string),
        f(:idempotency_key, :string, true),
        f(:revision, :integer, true),
        f(:sequence, :integer, true),
        f(:request, :work_request, true),
        f(:state, {:enum, @states}, true),
        f(:attempts, {:list, :attempt}, true)
      ],
      attempt: [
        f(:attempt, :integer, true),
        f(:state, {:enum, @states}, true),
        f(:cancel_stage, {:enum, @stages}),
        f(:cancel_reason, {:enum, [:cancel, :superseded, :time_limit]}),
        f(:timestamps, :attempt_timestamps, true),
        f(:slot, :string),
        f(:turn_id, :string),
        f(:provenance, :provenance),
        f(:resume_point, :resume_point),
        f(:quiescent, :boolean, true),
        f(:result, :result)
      ],
      attempt_timestamps: [
        f(:received_at, :datetime, true),
        f(:accepted_at, :datetime),
        f(:started_at, :datetime),
        f(:running_at, :datetime),
        f(:cancel_requested_at, :datetime),
        f(:signalled_at, :datetime),
        f(:forced_at, :datetime),
        f(:ended_at, :datetime)
      ],
      resume_point: [
        f(:turn_id, :string, true),
        f(:conversation_id, :string, true),
        f(:workspace, :resume_workspace, true)
      ],
      # D44: the path only for a client holding choose_path.
      resume_workspace: [f(:path, :string), f(:branch, :string), f(:commit, :string)],
      result: [
        f(:kind, {:enum, @kinds}, true),
        f(
          :reason,
          {:enum,
           [
             :time_limit,
             :quota,
             :launch,
             :workspace,
             :model_changed,
             :cancel,
             :superseded,
             :runtime_stop
           ]}
        ),
        f(:retryable, :boolean, true),
        f(:native_outcome, {:enum, [:finished, :failed, :stopped, :killed]}),
        f(:never_started, :boolean, true),
        f(:answer, :string),
        f(:work_product, :work_product),
        f(:log, :output_log, true)
      ],
      work_product: [f(:workspace, :work_product_workspace, true)],
      work_product_workspace: [
        f(:path, :string),
        f(:branch, :string),
        f(:base_sha, :string),
        f(:head_sha, :string),
        f(:changed, :boolean, true)
      ],
      output_log: [
        f(:complete, :boolean, true),
        f(:missing_bytes, :integer, true),
        f(:ref, :string, true)
      ],
      provenance: [
        f(:executor_kind, {:enum, [:agent]}, true),
        f(:provider, :string, true),
        f(:harness, :string, true),
        f(:harness_version, :string),
        f(:runtime_build, :string, true),
        f(:machine, :string, true),
        f(:slot, :string, true),
        f(:configured_model, :string, true),
        f(:reported_model, :string),
        f(:selection, :selection, true),
        f(:conversation_id, :string),
        f(:turn_id, :string, true),
        f(:continues, :string),
        f(:started_at, :datetime, true),
        f(:ended_at, :datetime)
      ],
      selection: [
        f(:profile, :string, true),
        f(:policy_version, :integer, true),
        f(:option, :option, true),
        f(:reason, {:enum, [:preferred, :fallback, :continuation]}, true),
        f(:skipped, {:list, :skipped_option}, true)
      ],
      option: [f(:provider, :string, true), f(:harness, :string, true), f(:model, :string, true)],
      skipped_option: [
        f(:option, :option, true),
        f(:why, {:enum, [:not_installed, :quota]}, true)
      ],
      output_event: [
        f(:sequence, :integer, true),
        f(:kind, {:enum, [:text, :activity]}, true),
        f(:text, :string, true)
      ],
      work_changed: [
        f(:sequence, :integer, true),
        f(:work_id, :string, true),
        f(:revision, :integer, true),
        f(:state, {:enum, @states}, true)
      ],
      capacity_available: [f(:sequence, :integer, true), f(:capacity, :capacity, true)],
      heartbeat: [
        f(:at, :datetime, true),
        f(:capacity, :capacity, true),
        f(:running, {:list, :running_attempt}, true)
      ],
      running_attempt: [
        f(:work_id, :string, true),
        f(:attempt, :integer, true),
        f(:state, {:enum, @states}, true),
        f(:alive, :boolean, true),
        f(:last_progress_at, :datetime),
        f(:activity, :string)
      ],
      retry_input: [f(:work_id, :string, true), f(:resume, :boolean)],
      cancel_input: [
        f(:work_id, :string, true),
        f(:mode, {:enum, [:graceful, :force]}, true),
        f(:reason, :string)
      ],
      get_work_input: [f(:work_id, :string, true)],
      find_work_input: [f(:client_key, :string, true)],
      list_work_input: [f(:state, {:enum, @states}), f(:changed_since, :integer)],
      turn_output_input: [f(:turn_id, :string, true), f(:cursor, :string)],
      subscribe_input: [f(:from, :integer)],
      accepted: [f(:work, :work, true)],
      existing: [f(:work, :work, true)],
      at_capacity: [
        f(:reason, {:enum, [:full, :profile_unavailable, :not_accepting]}, true),
        f(:retry_after, :integer, true),
        f(:capacity, :capacity, true)
      ],
      refused: [
        f(
          :reason,
          {:enum,
           [
             :not_permitted,
             :conflict,
             :invalid,
             :unsupported_workspace,
             :policy_forbids,
             :no_permitted_option,
             :resume_unavailable
           ]},
          true
        ),
        f(:detail, :string)
      ],
      not_found: [],
      cancelling: [f(:stage, {:enum, @stages}, true), f(:work, :work, true)],
      ended: [f(:work, :work, true)],
      found: [f(:work, :work, true)],
      pruned: [f(:work_id, :string, true), f(:kind, {:enum, @kinds}, true)],
      works: [f(:works, {:list, :work}, true), f(:sequence, :integer, true)],
      page: [
        f(:events, {:list, :output_event}, true),
        f(:cursor, :string, true),
        f(:more, :boolean, true)
      ],
      subscribed: [],
      reset: [f(:current_sequence, :integer, true)]
    }
  end

  # name => {right, input, [outcome: model]}, in §3.2's order.
  @capabilities [
    submit:
      {:submit, :work_request,
       [accepted: :accepted, existing: :existing, at_capacity: :at_capacity, refused: :refused]},
    retry:
      {:submit, :retry_input,
       [accepted: :accepted, at_capacity: :at_capacity, refused: :refused, not_found: :not_found]},
    # §3.2 Ownership: another client's work is refused (not_permitted) to a read_all caller.
    cancel:
      {:cancel, :cancel_input,
       [cancelling: :cancelling, ended: :ended, refused: :refused, not_found: :not_found]},
    get_work: {:read, :get_work_input, [found: :found, pruned: :pruned, not_found: :not_found]},
    find_work: {:read, :find_work_input, [found: :found, pruned: :pruned, not_found: :not_found]},
    list_work: {:read, :list_work_input, [works: :works]},
    capacity: {:read, nil, [capacity: :capacity]},
    turn_output: {:read, :turn_output_input, [page: :page, not_found: :not_found]},
    subscribe: {:read, :subscribe_input, [subscribed: :subscribed, reset: :reset]}
  ]

  # The schema's shape for an outcome is the generator's; accept `%{name:, model:}` or a
  # `{name, model}` pair, so these tests check the contract, not that detail.
  defp outcomes(capability) do
    for outcome <- capability.outcomes do
      case outcome do
        %{name: name, model: model} -> {name, model}
        {name, model} -> {name, model}
      end
    end
  end

  defp schema, do: Work.__schema__()
  defp models, do: Map.new(schema().models, &{&1.name, &1.fields})

  test "declares exactly the models of §3, each field with its type and requiredness" do
    actual = models()
    assert Enum.sort(Map.keys(actual)) == Enum.sort(Map.keys(expected_models()))

    for {name, fields} <- expected_models() do
      assert actual[name] == fields, "model #{name}"
    end
  end

  test "declares exactly the capabilities of §3.2, in order, with right, input and outcomes" do
    actual =
      for capability <- schema().capabilities,
          do: {capability.name, {capability.right, capability.input, outcomes(capability)}}

    assert Keyword.keys(actual) == Keyword.keys(@capabilities)

    for {name, expected} <- @capabilities do
      assert actual[name] == expected, "capability #{name}"
    end
  end

  test "every right a capability needs is a right a client can hold" do
    [rights] = for %{name: :rights, type: {:list, {:enum, rights}}} <- models().client, do: rights
    for capability <- schema().capabilities, do: assert(capability.right in rights)
  end

  test "outcomes of one capability are distinct models, so the facade can tell them apart" do
    for capability <- schema().capabilities do
      targets = for {_name, model} <- outcomes(capability), do: model
      assert targets == Enum.uniq(targets), "capability #{capability.name}"
      for model <- targets, do: assert(Map.has_key?(models(), model))
    end
  end

  test "an outcome model means the same in every capability that returns it" do
    pairs =
      for c <- schema().capabilities, {name, model} <- outcomes(c), uniq: true, do: {name, model}

    by_model = Enum.group_by(pairs, &elem(&1, 1), &elem(&1, 0))
    for {model, names} <- by_model, do: assert(names == [model], "model #{model}")
  end

  test "work states and result kinds follow the attempt state machine (§5)" do
    work = Map.new(models().work, &{&1.name, &1})
    result = Map.new(models().result, &{&1.name, &1})
    assert {:enum, states} = work.state.type
    assert {:enum, kinds} = result.kind.type
    # Every result kind is a terminal attempt state.
    assert kinds -- states == []
    assert states -- kinds == [:buffered, :starting, :running, :cancelling]
  end

  test "later-slice elements are not declared yet" do
    names = Map.keys(models())
    refute :packet in names

    fields = for {_m, fs} <- models(), %{name: n} <- fs, do: n
    refute :independence in fields
    refute :packet_id in fields
    refute :artifacts in fields

    [workspace] = for %{name: :workspace, type: t} <- models().work_request, do: t
    assert {:one_of, [:repository, :folder], tag: :kind} = workspace
  end

  test "the contract stays in Runtime vocabulary" do
    atoms =
      for {model, fields} <- models(), field <- fields, atom <- [model, field.name], do: atom

    atoms = atoms ++ for c <- schema().capabilities, {n, _} <- outcomes(c), do: n

    forbidden =
      ~r/flow|fact|http|rest\b|json|bus\b|sse\b|token|auth|header|status_code|serializ/i

    for atom <- Enum.uniq(atoms), do: refute(Atom.to_string(atom) =~ forbidden, "#{atom}")

    source = File.read!(schema().file)

    for word <- ~w(Flow Facts HTTP REST JSON Bus SSE token authentication header Engine) do
      refute source =~ ~r/\b#{word}\b/i, "#{word} in the contract source"
    end
  end

  # S2 changes work.json by one hunk only: runtime_stop in result.reason (§13.1 Q9). S3
  # adds D44: the right choose_path, and a path in resume_workspace,
  # work_product_workspace and folder (a request names it; a work shows it only with
  # choose_path) no longer required; and §3.2 Ownership: cancel may answer refused
  # (not_permitted, another client's work). The fixture is work.json as S1 left it; any
  # other change to the work contract fails here.
  @work_json Path.expand("../../targets/json/work.json", __DIR__)
  @s1_work_json Path.expand("fixtures/work.develop.json", __DIR__)

  test "work.json differs from S1's only by runtime_stop in result.reason, D44 and ownership" do
    s1 = JSON.decode!(File.read!(@s1_work_json))
    now = JSON.decode!(File.read!(@work_json))

    assert reason_values(s1) == reason_values(now) -- ["runtime_stop"]
    assert List.last(reason_values(now)) == "runtime_stop"

    assert field(s1, "client", "rights")["values"] ++ ["choose_path"] ==
             field(now, "client", "rights")["values"]

    for model <- ["resume_workspace", "work_product_workspace", "folder"] do
      assert field(s1, model, "path")["required"] == true
      assert field(now, model, "path") == %{field(s1, model, "path") | "required" => false}
    end

    assert Enum.sort(outcomes(now, "cancel")) ==
             Enum.sort(outcomes(s1, "cancel") ++ [%{"model" => "refused", "name" => "refused"}])

    allowed =
      s1
      |> put_reason_values(reason_values(now))
      |> put_field("client", "rights", field(now, "client", "rights"))
      |> put_field("resume_workspace", "path", field(now, "resume_workspace", "path"))
      |> put_field("work_product_workspace", "path", field(now, "work_product_workspace", "path"))
      |> put_field("folder", "path", field(now, "folder", "path"))
      |> put_outcomes("cancel", outcomes(now, "cancel"))

    for key <- Enum.uniq(Map.keys(allowed) ++ Map.keys(now)) do
      assert by_name(Map.get(now, key)) == by_name(Map.get(allowed, key)),
             "work.json #{key} changed"
    end
  end

  # Models and capabilities by name, so a failure shows the one that changed.
  defp by_name([%{"name" => _} | _] = list), do: Map.new(list, &{&1["name"], &1})
  defp by_name(other), do: other

  defp reason_values(json) do
    [values] =
      for %{"name" => "result", "fields" => fields} <- json["models"],
          %{"name" => "reason", "values" => values} <- fields,
          do: values

    values
  end

  defp field(json, model, name) do
    [field] =
      for %{"name" => ^model, "fields" => fields} <- json["models"],
          %{"name" => ^name} = field <- fields,
          do: field

    field
  end

  defp put_field(json, model, name, value) do
    update_in(json["models"], fn models ->
      for m <- models do
        if m["name"] == model,
          do:
            update_in(m["fields"], fn fs ->
              for f <- fs, do: if(f["name"] == name, do: value, else: f)
            end),
          else: m
      end
    end)
  end

  defp outcomes(json, capability) do
    [outcomes] = for %{"name" => ^capability, "outcomes" => o} <- json["capabilities"], do: o
    outcomes
  end

  # The outcomes compare as a set (by_name), so the new one's place does not matter.
  defp put_outcomes(json, capability, outcomes) do
    update_in(json["capabilities"], fn capabilities ->
      for c <- capabilities,
          do: if(c["name"] == capability, do: %{c | "outcomes" => outcomes}, else: c)
    end)
  end

  defp put_reason_values(json, values) do
    update_in(json["models"], fn models ->
      for model <- models do
        if model["name"] == "result",
          do:
            update_in(model["fields"], fn fields ->
              for f <- fields,
                  do: if(f["name"] == "reason", do: %{f | "values" => values}, else: f)
            end),
          else: model
      end
    end)
  end
end

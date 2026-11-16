defmodule AtlasRuntimeBoundary.OperationsTest do
  use ExUnit.Case, async: true

  alias AtlasRuntimeBoundary.Operations

  # Design 2026-11-16-runtime-backend §13.1 (Q4–Q9, Q12, Q13), written out by hand: a change
  # to the contract's shape must change this file too.

  @operations_json Path.expand("../../targets/json/operations.json", __DIR__)

  defp f(name, type, required \\ false), do: %{name: name, type: type, required: required}

  @permission_profiles [
    :"dedicated-repository",
    :"materialized-folder",
    :"workspace-write",
    :"read-only",
    :"review-packet"
  ]

  defp expected_models do
    %{
      client: [f(:id, :string, true), f(:rights, {:list, {:enum, [:inspect, :operate]}}, true)],
      runtime_info: [
        f(:runtime_build, :string, true),
        f(:incarnation, :string, true),
        f(:mode, {:enum, [:open, :paused, :draining, :stopping]}, true),
        f(:policy_version, :integer, true),
        f(:slots, {:list, :slot}, true)
      ],
      slot: [f(:name, :string, true), f(:busy, :boolean, true)],
      policy: [
        f(:version, :integer, true),
        f(:changed_by, :string),
        f(:changed_at, :datetime),
        f(:buffer_size, :integer, true),
        f(:independence, :independence),
        f(:profiles, {:list, :profile_policy}, true)
      ],
      independence: [f(:different_from, {:enum, [:conversation, :model, :provider]}, true)],
      profile_policy: [
        f(:profile, :string, true),
        f(:permissions, {:list, {:enum, @permission_profiles}}, true),
        f(:cost_classes, {:list, {:enum, [:low, :standard, :high]}}, true),
        f(:limits, :profile_limits, true),
        f(:options, {:list, :policy_option}, true)
      ],
      profile_limits: [f(:max_duration, :integer)],
      policy_option: [
        f(:provider, :string, true),
        f(:harness, :string, true),
        f(:model, :string, true),
        f(:availability, :option_availability, true)
      ],
      option_availability: [
        f(:available, :boolean, true),
        f(:reason, {:enum, [:quota, :not_installed]}),
        f(:until, :datetime)
      ],
      stop_input: [f(:force, :boolean)],
      release_slot_input: [f(:slot, :string, true)],
      clear_quota_mark_input: [f(:harness, :string, true)],
      released: [f(:slot, :string, true)],
      refused: [f(:reason, {:enum, [:slot_busy, :invalid]}, true), f(:detail, :string)],
      not_found: [],
      cleared: []
    }
  end

  # name => {right, input, [outcome: model]}. inspect: runtime info and the policy view;
  # operate: everything that changes the Runtime (Q4).
  @capabilities [
    runtime_info: {:inspect, nil, [runtime_info: :runtime_info]},
    policy: {:inspect, nil, [policy: :policy]},
    pause: {:operate, nil, [runtime_info: :runtime_info]},
    resume: {:operate, nil, [runtime_info: :runtime_info]},
    drain: {:operate, nil, [runtime_info: :runtime_info]},
    stop: {:operate, :stop_input, [stopping: :runtime_info]},
    release_slot:
      {:operate, :release_slot_input,
       [released: :released, refused: :refused, not_found: :not_found]},
    clear_quota_mark:
      {:operate, :clear_quota_mark_input, [cleared: :cleared, not_found: :not_found]}
  ]

  defp schema, do: Operations.__schema__()
  defp models, do: Map.new(schema().models, &{&1.name, &1.fields})
  defp outcomes(capability), do: for(o <- capability.outcomes, do: {o.name, o.model})

  test "declares exactly the models of §13.1, each field with its type and requiredness" do
    actual = models()
    assert Enum.sort(Map.keys(actual)) == Enum.sort(Map.keys(expected_models()))
    for {name, fields} <- expected_models(), do: assert(actual[name] == fields, "model #{name}")
  end

  test "declares exactly the capabilities, in order, with right, input and outcomes" do
    actual =
      for c <- schema().capabilities, do: {c.name, {c.right, c.input, outcomes(c)}}

    assert Keyword.keys(actual) == Keyword.keys(@capabilities)
    for {name, expected} <- @capabilities, do: assert(actual[name] == expected, "#{name}")
  end

  test "an invalid input is refused as invalid, with the reasons in detail" do
    assert schema().invalid_input == %{
             outcome: :refused,
             set: [reason: :invalid],
             detail: :detail
           }
  end

  test "every right a capability needs is a right a client can hold" do
    [rights] = for %{name: :rights, type: {:list, {:enum, rights}}} <- models().client, do: rights
    assert Enum.sort(rights) == [:inspect, :operate]
    for c <- schema().capabilities, do: assert(c.right in rights, "#{c.name}")
  end

  test "outcomes of one capability are distinct models, so the facade can tell them apart" do
    for c <- schema().capabilities do
      targets = for {_name, model} <- outcomes(c), do: model
      assert targets == Enum.uniq(targets), "capability #{c.name}"
    end
  end

  # The backend gives each outcome one status (Q12): stop answers 202, the modes 200, so
  # stop's outcome has a name of its own while carrying the same runtime info.
  test "stop answers an outcome of its own; the modes answer runtime_info" do
    by_name = Map.new(schema().capabilities, &{&1.name, outcomes(&1)})
    assert by_name.stop == [stopping: :runtime_info]

    for mode <- [:pause, :resume, :drain],
        do: assert(by_name[mode] == [runtime_info: :runtime_info])
  end

  # Policy file internals and availability evidence stay private (§1.6, Q7): the view has
  # exactly the declared fields, at every level.
  test "the policy view holds only the declared fields" do
    allowed = %{
      policy: ~w(version changed_by changed_at buffer_size independence profiles)a,
      independence: [:different_from],
      profile_policy: ~w(profile permissions cost_classes limits options)a,
      profile_limits: [:max_duration],
      policy_option: ~w(provider harness model availability)a,
      option_availability: ~w(available reason until)a
    }

    for {model, names} <- allowed do
      assert Enum.map(models()[model], & &1.name) == names, "#{model}"
    end

    json = JSON.decode!(File.read!(@operations_json))

    for %{"name" => model, "fields" => fields} <- json["models"],
        Map.has_key?(allowed, String.to_atom(model)) do
      assert Enum.map(fields, &String.to_atom(&1["name"])) == allowed[String.to_atom(model)],
             "#{model} in operations.json"
    end
  end

  test "operations.json carries no policy file or availability internals" do
    json = File.read!(@operations_json)

    # Names of the files and of the quota evidence (§6, §7), and words that would point at
    # a raw copy of either.
    for word <- ~w(policy.json availability.json claude_quota raw file path latch registry) do
      refute json =~ ~r/(^|[^A-Za-z0-9_])#{Regex.escape(word)}([^A-Za-z0-9_]|$)/,
             "#{word} in operations.json"
    end
  end

  test "the contract names no model of another contract" do
    source = File.read!(schema().file)
    refute source =~ "AtlasRuntimeBoundary.Work"
    refute source =~ "AtlasRuntimeBoundary.History"
  end

  test "the contract stays in Runtime vocabulary" do
    atoms =
      for {model, fields} <- models(), field <- fields, atom <- [model, field.name], do: atom

    atoms = atoms ++ for c <- schema().capabilities, {n, _} <- outcomes(c), do: n

    forbidden =
      ~r/flow|fact|http|rest\b|json|bus\b|sse\b|token|auth|header|status_code|serializ|worker|backend/i

    for atom <- Enum.uniq(atoms), do: refute(Atom.to_string(atom) =~ forbidden, "#{atom}")

    source = File.read!(schema().file)

    for word <- ~w(Flow Facts HTTP REST JSON Bus SSE token authentication header Engine socket) do
      refute source =~ ~r/\b#{word}\b/i, "#{word} in the contract source"
    end
  end
end

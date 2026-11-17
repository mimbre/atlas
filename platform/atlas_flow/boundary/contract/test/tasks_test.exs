defmodule AtlasFlowBoundary.TasksTest do
  use ExUnit.Case, async: true

  alias AtlasFlowBoundary.Tasks

  # Flow Engine plan §3.3 (F5a), written out by hand: a change to the contract's shape must
  # change this file too.

  defp f(name, type, required \\ false), do: %{name: name, type: type, required: required}

  defp expected_models do
    %{
      check: [
        f(:exit_status, :integer),
        f(:ending, {:enum, [:timed_out, :cancelled, :interrupted]}),
        f(:output_tail, :string)
      ],
      task_attempt: [
        f(:attempt, :integer, true),
        f(:state, :string),
        f(:result_kind, :string),
        f(:machinery, :string),
        f(:provider, :string),
        f(:harness, :string),
        f(:harness_version, :string),
        f(:configured_model, :string),
        f(:reported_model, :string),
        f(:selection_reason, :string),
        f(:conversation_id, :string),
        f(:machine, :string),
        f(:slot, :string),
        f(:turn_id, :string),
        f(:started_at, :datetime),
        f(:ended_at, :datetime)
      ],
      task: [
        f(:task_id, :string, true),
        f(:subject, :string, true),
        f(:kind, {:enum, [:plan, :author, :review, :fix, :diagnose, :native_check]}, true),
        f(:role, {:enum, [:architect, :developer, :investigator]}),
        f(:profile, :string),
        f(:state, :string),
        f(:work_id, :string),
        f(:attempt, :integer),
        f(:result_kind, :string),
        f(:reason, :string),
        f(:check, :check),
        f(:verdict, {:enum, [:approved, :changes_required]}),
        f(:answer, :string),
        f(:result_fingerprints, {:list, :string}, true),
        f(:based_on, {:list, :string}, true),
        f(:base_id, :string),
        f(:base_snapshot, :string),
        f(:base_revision, :string),
        f(:attempts, {:list, :task_attempt}, true)
      ],
      profile_capacity: [
        f(:profile, :string, true),
        f(:available, :boolean, true),
        f(:reason, :string)
      ],
      capacity: [
        f(:accepting, :boolean, true),
        f(:free_slots, :integer, true),
        f(:profiles, {:list, :profile_capacity}, true)
      ],
      problem: [f(:message, :string, true)],
      list_tasks_input: [f(:subject, :string, true)],
      get_task_input: [f(:task_id, :string, true)],
      machinery_status_input: [f(:machinery, :string, true)],
      task_list: [f(:subject, :string, true), f(:tasks, {:list, :task}, true)],
      machinery_status: [
        f(:machinery, :string, true),
        f(:reachable, :boolean, true),
        f(:last_capacity, :capacity),
        f(:last_seen, :datetime)
      ]
    }
  end

  # The plan's reading capabilities; cancel_task and retry_task (right steer) are F5b's.
  @capabilities [
    list_tasks: {:read, :list_tasks_input, [tasks: :task_list, unavailable: :problem]},
    get_task: {:read, :get_task_input, [found: :task, not_found: nil, unavailable: :problem]},
    machinery_status: {:read, :machinery_status_input, [status: :machinery_status]}
  ]

  defp schema, do: Tasks.__schema__()
  defp models, do: Map.new(schema().models, &{&1.name, &1.fields})
  defp outcomes(capability), do: for(o <- capability.outcomes, do: {o.name, o.model})

  test "declares exactly its models, each field with its type and requiredness" do
    actual = models()
    assert Enum.sort(Map.keys(actual)) == Enum.sort(Map.keys(expected_models()))
    for {name, fields} <- expected_models(), do: assert(actual[name] == fields, "model #{name}")
  end

  test "declares exactly the reading capabilities, each with right read" do
    actual = for c <- schema().capabilities, do: {c.name, {c.right, c.input, outcomes(c)}}
    assert actual == @capabilities
  end

  test "steering waits for F5b: no capability needs a right other than read" do
    assert Enum.uniq(for c <- schema().capabilities, do: c.right) == [:read]
    names = for c <- schema().capabilities, do: c.name
    refute :cancel_task in names
    refute :retry_task in names
  end

  test "refusals are outcomes; the facade answers malformed input itself" do
    assert schema().invalid_input == nil
  end

  test "the contract stays in Flow's vocabulary: no transport, no paths, no secrets" do
    atoms =
      for {model, fields} <- models(), field <- fields, atom <- [model, field.name], do: atom

    atoms = atoms ++ for c <- schema().capabilities, {n, _} <- outcomes(c), do: n
    forbidden = ~r/http|status_code|json|token|header|url|path|folder|secret|password|key$/i
    for atom <- Enum.uniq(atoms), do: refute(Atom.to_string(atom) =~ forbidden, "#{atom}")
  end
end

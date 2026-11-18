defmodule AtlasRuntimeBoundary.HistoryTest do
  use ExUnit.Case, async: true

  alias AtlasRuntimeBoundary.History

  # Design 2026-11-16-runtime-backend §13.1 (Q1, Q2, Q4), written out by hand: a change to
  # the contract's shape must change this file too.

  @history_json Path.expand("../../targets/json/history.json", __DIR__)

  defp f(name, type, required \\ false), do: %{name: name, type: type, required: required}

  @turn_states [:running, :stopping, :killing, :finished, :failed, :stopped, :killed, :unknown]

  defp expected_models do
    %{
      client: [f(:id, :string, true), f(:rights, {:list, {:enum, [:read, :read_all]}}, true)],
      turn: [
        f(:turn_id, :string, true),
        f(:slot, :string),
        f(:state, {:enum, @turn_states}, true),
        f(:native_outcome, {:enum, [:finished, :failed, :stopped, :killed]}),
        f(:started_at, :datetime),
        f(:ended_at, :datetime),
        f(:harness, :string),
        f(:configured_model, :string),
        f(:reported_model, :string),
        f(:conversation_id, :string)
      ],
      list_turns_input: [
        f(:slot, :string),
        f(:since, :datetime),
        f(:cursor, :string),
        Map.put(f(:limit, :integer), :range, {1, 100})
      ],
      get_turn_input: [f(:turn_id, :string, true)],
      turns: [
        f(:turns, {:list, :turn}, true),
        f(:cursor, :string, true),
        f(:more, :boolean, true)
      ],
      found: [f(:turn, :turn, true)],
      not_found: []
    }
  end

  # Read-only: read sees the caller's own turns, read_all widens it (Q2, Q4).
  @capabilities [
    list_turns: {:read, :list_turns_input, [turns: :turns]},
    get_turn: {:read, :get_turn_input, [found: :found, not_found: :not_found]}
  ]

  defp schema, do: History.__schema__()
  defp models, do: Map.new(schema().models, &{&1.name, &1.fields})
  defp outcomes(capability), do: for(o <- capability.outcomes, do: {o.name, o.model})

  test "declares exactly the models of Q1, each field with its type and requiredness" do
    actual = models()
    assert Enum.sort(Map.keys(actual)) == Enum.sort(Map.keys(expected_models()))
    for {name, fields} <- expected_models(), do: assert(actual[name] == fields, "model #{name}")
  end

  test "declares exactly list_turns and get_turn, with right, input and outcomes" do
    actual = for c <- schema().capabilities, do: {c.name, {c.right, c.input, outcomes(c)}}
    assert actual == @capabilities
  end

  test "every right a capability needs is a right a client can hold" do
    [rights] = for %{name: :rights, type: {:list, {:enum, rights}}} <- models().client, do: rights
    for c <- schema().capabilities, do: assert(c.right in rights)
  end

  # The fields of a turn record that the old read path never projected (the Runtime's
  # read API test) stay out of the summary, and out of history.json.
  test "a turn summary carries none of the turn record's private fields" do
    private =
      ~w(assignment cwd permissions sandbox artifacts repository session_id selection quota
         request_id server last_answer resume_context)

    fields =
      for {model, fs} <- models(), model != :client, %{name: n} <- fs, do: Atom.to_string(n)

    assert "id" not in fields
    json = File.read!(@history_json)

    for name <- private do
      refute name in fields, "#{name} is declared"
      refute json =~ ~r/"#{name}"/, "#{name} in history.json"
    end
  end

  test "the old read path's words become Runtime terms: slot, harness" do
    names =
      for {model, fs} <- models(), atom <- [model | Enum.map(fs, & &1.name)], do: "#{atom}"

    for word <- ~w(worker worker_id backend requested_model model recorded_state) do
      refute word in names, word
    end

    assert :slot in Enum.map(models().turn, & &1.name)
    assert :harness in Enum.map(models().turn, & &1.name)
  end

  test "the contract names no model of another contract, and has no write" do
    source = File.read!(schema().file)
    refute source =~ "AtlasRuntimeBoundary.Work"
    refute source =~ "AtlasRuntimeBoundary.Operations"
    assert Enum.all?(schema().capabilities, &(&1.right in [:read, :read_all]))
  end

  test "the contract stays in Runtime vocabulary" do
    atoms =
      for {model, fields} <- models(), field <- fields, atom <- [model, field.name], do: atom

    atoms = atoms ++ for c <- schema().capabilities, {n, _} <- outcomes(c), do: n
    forbidden = ~r/flow|fact|http|rest\b|json|bus\b|sse\b|token|auth|header|status_code|serializ/i
    for atom <- Enum.uniq(atoms), do: refute(Atom.to_string(atom) =~ forbidden, "#{atom}")

    source = File.read!(schema().file)

    for word <- ~w(Flow Facts HTTP REST JSON Bus SSE token authentication header Engine socket) do
      refute source =~ ~r/\b#{word}\b/i, "#{word} in the contract source"
    end
  end
end

defmodule AtlasRuntime.ProvenanceTest do
  use ExUnit.Case, async: true
  alias AtlasRuntime.Provenance

  @context %{machine: "mini", runtime_build: "0.1.0"}
  @claude %{"provider" => "anthropic", "harness" => "claude", "model" => "claude-opus-5-5"}
  @selection %{
    "profile" => "deep_coding",
    "policy_version" => 4,
    "option" => @claude,
    "reason" => "fallback",
    "skipped" => [%{"option" => @claude, "why" => "quota"}],
    "requested" => %{"backend" => "claude", "model" => "claude-opus-5-5"},
    "selected" => %{"backend" => "claude", "model" => "claude-opus-5-5"}
  }

  @run %{
    id: "turn-00000000000000c1",
    worker_id: "dev1",
    backend: "claude",
    model: "claude-opus-5-5[1m]",
    requested_model: "claude-opus-5-5",
    selection: %{"reason" => "explicit"},
    session_id: "conversation-1",
    source_turn_id: "turn-00000000000000b0",
    started_at: "2026-11-16T10:00:00Z",
    ended_at: "2026-11-16T10:05:00Z"
  }

  test "a model attempt's provenance from the turn and its policy selection" do
    assert Provenance.record(@run, @selection, @context) == %{
             "executor_kind" => "agent",
             "provider" => "anthropic",
             "harness" => "claude",
             "harness_version" => "unknown",
             "runtime_build" => "0.1.0",
             "machine" => "mini",
             "slot" => "dev1",
             "configured_model" => "claude-opus-5-5",
             "reported_model" => "claude-opus-5-5[1m]",
             "selection" => %{
               "profile" => "deep_coding",
               "policy_version" => 4,
               "option" => @claude,
               "reason" => "fallback",
               "skipped" => [%{"option" => @claude, "why" => "quota"}]
             },
             "conversation_id" => "conversation-1",
             "turn_id" => "turn-00000000000000c1",
             "continues" => "turn-00000000000000b0",
             "started_at" => "2026-11-16T10:00:00Z",
             "ended_at" => "2026-11-16T10:05:00Z"
           }
  end

  test "a saved turn.json with a legacy selection derives the provider from the harness" do
    saved =
      @run
      |> Map.put(:backend, "codex")
      |> Map.put(:model, nil)
      |> JSON.encode!()
      |> JSON.decode!()

    record = Provenance.record(saved, nil, @context)
    assert record["provider"] == "openai"
    assert record["configured_model"] == "claude-opus-5-5"
    assert record["reported_model"] == nil

    assert record["selection"] == %{
             "profile" => nil,
             "policy_version" => nil,
             "option" => nil,
             "reason" => "explicit",
             "skipped" => []
           }
  end

  test "the default context names this machine and build" do
    assert %{machine: machine, runtime_build: build} = Provenance.context()
    assert is_binary(machine) and machine != ""
    assert is_binary(build)
    assert Provenance.record(@run, @selection, Provenance.context())["machine"] == machine
  end

  test "model_changed is read from either key form" do
    assert Provenance.model_changed(@run) == nil
    change = %{"first" => "a", "reported" => "b", "at" => "2026-11-16T10:01:00Z"}
    assert Provenance.model_changed(Map.put(@run, :model_changed, change)) == change
    assert Provenance.model_changed(%{"model_changed" => change}) == change
  end
end

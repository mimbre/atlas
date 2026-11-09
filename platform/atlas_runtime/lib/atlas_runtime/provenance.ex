defmodule AtlasRuntime.Provenance do
  @moduledoc """
  What actually ran for one model attempt (design §3.5): one record per turn, built from
  the Service's turn and the policy selection, and never changed once the caller wrote it.

  `reported_model` is the first normalized model a top-level record reported: the Service
  keeps the first one and stops the turn with `model_changed` on a later different one
  (`model_changed` on the turn). The harness version is not known yet (F12).
  """

  @providers %{"claude" => "anthropic", "codex" => "openai"}

  @doc """
  The provenance fields of `run` (a live Service run or a saved `turn.json`, atom or string
  keys). `selection` is the policy selection (`AtlasRuntime.Policy.resolve/5`), or nil to
  use the turn's own. `context` holds `:machine` and `:runtime_build`; see `context/0`.
  """
  def record(run, selection, context) do
    run = Map.new(run, fn {key, value} -> {to_string(key), value} end)
    selection = selection || run["selection"] || %{}
    option = selection["option"]
    harness = run["backend"]

    %{
      "executor_kind" => "agent",
      "provider" => (option && option["provider"]) || @providers[harness],
      "harness" => harness,
      "harness_version" => "unknown",
      "runtime_build" => Map.fetch!(context, :runtime_build),
      "machine" => Map.fetch!(context, :machine),
      "slot" => run["worker_id"],
      "configured_model" => (option && option["model"]) || run["requested_model"],
      "reported_model" => run["model"],
      "selection" => %{
        "profile" => selection["profile"],
        "policy_version" => selection["policy_version"],
        "option" => option,
        "reason" => selection["reason"],
        "skipped" => selection["skipped"] || []
      },
      "conversation_id" => run["session_id"],
      "turn_id" => run["id"],
      "continues" => run["source_turn_id"],
      "started_at" => run["started_at"],
      "ended_at" => run["ended_at"]
    }
  end

  @doc "This machine and Runtime build, for `record/3`."
  def context do
    {:ok, host} = :inet.gethostname()
    vsn = Application.spec(:atlas_runtime, :vsn)
    %{machine: to_string(host), runtime_build: if(vsn, do: to_string(vsn), else: "unknown")}
  end

  @doc "The turn's top-level model change, or nil: then its result is `failed: model_changed`."
  def model_changed(run) do
    run = Map.new(run, fn {key, value} -> {to_string(key), value} end)
    run["model_changed"]
  end
end

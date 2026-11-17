defmodule AtlasFlow.WorkSource.Translate do
  @moduledoc """
  Flow's task ↔ the Runtime's work, on Flow's side (plan m3 §3.5; decision §5.1). Pure.

  **Intent (version 2).** What a run holds as `pending.task` for a task that goes through
  the work source (A4 makes it, Dispatch offers it):

      %{"version" => 2, "key" => "TK-<subject>-<n>", "machinery" => <name>,
        "created_at" => <iso8601>, "base_snapshot" => <Code snapshot id>,
        "work" => %{"title", "instructions", "profile", "cost_class",
                    "after_check" => %{"command" => [...]} (only with a check),
                    "input" => %{"base" => %{"base_id", "manifest"},
                                 "permissions" => "workspace-write" | "read-only"}}}

  Title and instructions are built as `AtlasFlow.Activities.Task.request/3` builds them;
  the base comes from `AtlasFlow.Bases`. No `slot`, `folder`, `resume_from`, `repository` or
  path is ever in it, so none can reach `offered_work/1`.

  **Reports.** A report arrives in contract terms (atom keys, atoms, structs or plain
  maps); `normal/1` turns it into JSON terms (string keys, strings, no nil values), the
  form every other function here takes and the form its digest (`digest/1`) is taken of.
  Then `ended_values/1` gives the task fact's result fields, `attempt_values/1` an attempt
  record's, and `outcome/2` the run's result from the task fact Delivery wrote.
  """

  alias AtlasFlow.Activities.Task

  @answer_bytes 8192
  @read_only ~w(review)

  # -- Task → offered work ---------------------------------------------------------------

  @doc """
  The version-2 intent of task `key` (`spec`, the subject fact, its `base`
  (`%{base_id, manifest, snapshot_id}`), the machinery name and when it was made).
  """
  def intent(spec, subject, key, base, machinery, %DateTime{} = now) do
    request = Task.request(spec, subject, key)

    work =
      request
      |> Map.take(["title", "instructions", "profile", "cost_class", "after_check"])
      |> Map.put("input", %{
        "base" => %{"base_id" => base.base_id, "manifest" => base.manifest},
        "permissions" => permissions(spec["kind"])
      })

    %{
      "version" => 2,
      "key" => key,
      "machinery" => machinery,
      "created_at" => DateTime.to_iso8601(now),
      "base_snapshot" => base.snapshot_id,
      "work" => work
    }
  end

  @doc "The permissions a task kind's work runs with: read-only for a review."
  def permissions(kind) when kind in @read_only, do: "read-only"
  def permissions(_kind), do: "workspace-write"

  @doc "Whether `intent` is a version-2 intent Dispatch can offer."
  def intent?(%{"version" => 2, "key" => key, "work" => %{} = work} = intent) do
    text?(key) and text?(intent["created_at"]) and text?(work["title"]) and
      text?(work["instructions"]) and text?(work["profile"]) and text?(work["cost_class"]) and
      base?(get_in(work, ["input", "base"])) and
      get_in(work, ["input", "permissions"]) in ["read-only", "workspace-write"]
  end

  def intent?(_), do: false

  defp base?(%{"base_id" => id, "manifest" => manifest}), do: text?(id) and text?(manifest)
  defp base?(_), do: false

  @doc """
  The `offered_work` of an intent (atom keys, the contract's fields only): `work_key` is
  the task key; `after_check` only with a check, without a timeout (the Runtime's cap).
  """
  def offered_work(%{"key" => key, "work" => work}) do
    input = work["input"]

    offered = %{
      work_key: key,
      title: work["title"],
      instructions: work["instructions"],
      profile: work["profile"],
      cost_class: work["cost_class"],
      input: %{
        base: %{base_id: input["base"]["base_id"], manifest: input["base"]["manifest"]},
        permissions: input["permissions"]
      }
    }

    case work["after_check"] do
      %{"command" => [_ | _] = command} -> Map.put(offered, :after_check, %{command: command})
      _ -> offered
    end
  end

  @doc "The lease's input as the task fact keeps it (`input`, JSON): what `get_blob` scopes by."
  def lease_input(%{"work" => %{"input" => input}}), do: JSON.encode!(input)

  @doc "The base manifest of a lease input the task fact keeps, or nil."
  def input_manifest(input) when is_binary(input) do
    case JSON.decode(input) do
      {:ok, %{"base" => %{"manifest" => manifest}}} when is_binary(manifest) -> manifest
      _ -> nil
    end
  end

  def input_manifest(_), do: nil

  # -- Reports ---------------------------------------------------------------------------

  @doc "A term as JSON terms: string keys, atoms as strings, nil values and struct tags left out."
  def normal(%DateTime{} = at), do: DateTime.to_iso8601(at)
  def normal(%{__struct__: _} = struct), do: struct |> Map.from_struct() |> normal()

  def normal(map) when is_map(map),
    do: for({k, v} <- map, v != nil, into: %{}, do: {to_string(k), normal(v)})

  def normal(list) when is_list(list), do: Enum.map(list, &normal/1)
  def normal(atom) when is_atom(atom) and atom not in [nil, true, false], do: Atom.to_string(atom)
  def normal(other), do: other

  @doc "A report's state: `\"accepted\"`, `\"refused\"`, `\"started\"`, `\"ended\"`, or nil."
  def state(%{"state" => state}) when state in ~w(accepted refused started ended), do: state
  def state(_), do: nil

  @doc "The sha256 of a report's canonical JSON (keys sorted): how a replay is recognised."
  def digest(report), do: sha256(AtlasFlow.Results.canonical(report))

  @doc """
  Why an `ended` report brings no result (§3.5, Q8): `"returned"`, `"runtime_stop"` (an
  interruption at Runtime stop), `"supervision"` (cancelled after Flow asked for it because
  the supervisor changed), or nil when it brings one. `cancel_cause` is the lease's
  `lease_end_cause` when Flow asked for the cancel.
  """
  def result_less(%{"result" => result}, cancel_cause),
    do: no_result_cause(result["kind"], result["reason"], cancel_cause)

  def result_less(_ended, _cancel_cause), do: nil

  @doc """
  Whether a task fact's ending brought no result (§3.5): the same rule as `result_less/2`,
  decided from the stored ending (`result_kind`, `reason`), with `lease_end_cause` used only
  to tell a supervision `cancelled` from any other. A cancel request alone never makes an
  ending result-less: an `ended(completed)` after `cancel_requested` keeps its result.
  Delivery, `outcome/2` and Dispatch's grant all decide by this rule.
  """
  def no_result?(values) do
    v = values || %{}
    no_result_cause(v["result_kind"], v["reason"], v["lease_end_cause"]) != nil
  end

  defp no_result_cause("returned", _reason, _cause), do: "returned"
  defp no_result_cause("interrupted", "runtime_stop", _cause), do: "runtime_stop"
  defp no_result_cause("cancelled", _reason, "supervision"), do: "supervision"
  defp no_result_cause(_kind, _reason, _cause), do: nil

  @doc """
  The task fact's result fields of an `ended` report: `result_kind`, `reason`, `answer`
  (at most 8 KB), the check (`check_exit_status`, `check_ending`, `check_output_tail`) and
  `result_fingerprints` (the roots' fingerprints, JSON). Every field is given, nil when the
  report has none, so a field of an earlier attempt is cleared.
  """
  def ended_values(%{"result" => result} = ended) do
    check = result["check"]

    %{
      "result_kind" => result["kind"],
      "reason" => result["reason"],
      "answer" => answer(result["answer"]),
      "check_exit_status" => check && check["exit_status"],
      "check_ending" => check && ending(check),
      "check_output_tail" => check && check["output_tail"],
      "result_fingerprints" => fingerprints(ended["change_set"])
    }
  end

  # How a check ended, when it did not simply exit (§3.5).
  defp ending(check) do
    cond do
      check["timed_out"] == true -> "timed_out"
      is_binary(check["error"]) -> "error: " <> check["error"]
      is_binary(check["signal"]) -> "signal: " <> check["signal"]
      not is_integer(check["exit_status"]) -> "no_exit_status"
      true -> nil
    end
  end

  defp answer(text) when is_binary(text) and byte_size(text) > @answer_bytes,
    do: text |> binary_part(0, @answer_bytes) |> String.chunk(:valid) |> hd()

  defp answer(text) when is_binary(text), do: text
  defp answer(_), do: nil

  defp fingerprints(%{"roots" => [_ | _] = roots}),
    do:
      JSON.encode!(for r <- roots, do: %{"root" => r["root"], "fingerprint" => r["fingerprint"]})

  defp fingerprints(_), do: nil

  @doc "Whether an `ended` report carries a change set with at least one root."
  def change_set?(%{"change_set" => %{"roots" => [_ | _]}}), do: true
  def change_set?(_), do: false

  @doc """
  The change set Flow stores as the result's manifest: the report's roots on top of the
  lease's base (`base`), so its `csf_` fingerprints can be computed again.
  """
  def manifest(%{"change_set" => %{"roots" => roots}}, base),
    do: %{"base" => base, "roots" => roots}

  @doc "Every blob a change set references: the sha256 of each write entry, sorted."
  def references(%{"roots" => roots}) when is_list(roots) do
    for %{"entries" => entries} <- roots,
        %{"op" => "write", "sha256" => sha} <- List.wrap(entries),
        is_binary(sha),
        uniq: true,
        do: sha
  end

  def references(_), do: []

  @doc """
  Whether every root's reported `csf_` fingerprint is the one `AtlasChangeset` computes
  for its entries on the manifest's base (the work's `base_id`, as the Runtime freezes it).
  """
  def fingerprints_hold?(%{"base" => base, "roots" => roots} = manifest) when is_binary(base) do
    plain = %{"base" => base, "roots" => Enum.map(roots, &Map.delete(&1, "fingerprint"))}

    with :ok <- AtlasChangeset.validate(plain) do
      computed = Enum.map(AtlasChangeset.fingerprints(plain), &{&1.root, &1.fingerprint})
      reported = Enum.map(manifest["roots"], &{&1["root"], &1["fingerprint"]})
      Enum.sort(computed) == Enum.sort(reported)
    else
      _ -> false
    end
  end

  def fingerprints_hold?(_), do: false

  @doc """
  The `task_attempt` values of a report (§3.5), no nil values: `state` and, for an
  `ended`, its `result_kind` and the provenance of its last turn (`turn_id`, `provider`,
  `harness`, `harness_version`, `configured_model`, `reported_model`, `machine`, `slot`,
  `started_at`, `ended_at`). There is no `selection_reason`: the contract has none.
  """
  def attempt_values(%{"state" => "refused"}), do: %{"state" => "refused"}
  def attempt_values(%{"state" => "started"}), do: %{"state" => "running"}

  def attempt_values(%{"state" => "ended", "result" => result} = ended) do
    p = List.last(ended["provenance"] || []) || %{}

    Map.take(p, ~w(turn_id provider harness harness_version configured_model reported_model
                   machine slot started_at ended_at))
    |> Map.merge(%{"state" => result["kind"], "result_kind" => result["kind"]})
    |> Map.reject(fn {_, v} -> v in [nil, ""] end)
  end

  # -- Task fact → the run's result ------------------------------------------------------

  @doc """
  The run's result from the task fact Delivery wrote (§3.5; A4 calls it), `checked?` when
  the task has an after-check:

  - `{:result, outcome, detail}` once the lease is done: `completed` (completed, and its
    check, if any, exited 0 with no ending), `check_failed` (completed otherwise), `stuck`
    (refused, too large, invalid, or any other kind; `detail["reason"]` says which);
  - `:retry`: the lease ended without a result (returned, Runtime stop, a `cancelled`
    after a supervision cancel request; `no_result?/1`); the work is offered again as a
    fresh attempt;
  - `:waiting`: no result yet (no lease, a live one, or a result still incomplete).
  """
  def outcome(fact, checked?) do
    v = (fact || %{})["values"] || %{}

    cond do
      v["lease_state"] != "done" ->
        :waiting

      no_result?(v) ->
        :retry

      v["result_kind"] == "refused" ->
        {:result, "stuck", %{"reason" => "refused: #{v["reason"]}", "kind" => "refused"}}

      v["result_state"] in ~w(too_large invalid) ->
        {:result, "stuck", %{"reason" => v["result_state"], "kind" => v["result_kind"]}}

      v["result_state"] not in [nil, "complete"] ->
        :waiting

      v["result_kind"] == "completed" ->
        check = check(v)
        {:result, completed(check, checked?), %{"kind" => "completed", "check" => check}}

      true ->
        {:result, "stuck",
         %{"reason" => v["reason"] || v["result_kind"], "kind" => v["result_kind"]}}
    end
  end

  defp check(v) do
    if Map.has_key?(v, "check_exit_status") or Map.has_key?(v, "check_ending"),
      do: %{
        "exit_status" => v["check_exit_status"],
        "ending" => v["check_ending"],
        "tail" => v["check_output_tail"]
      }
  end

  defp completed(_check, false), do: "completed"
  defp completed(nil, true), do: "check_failed"
  defp completed(%{"exit_status" => 0, "ending" => nil}, true), do: "completed"
  defp completed(_check, true), do: "check_failed"

  defp text?(v), do: is_binary(v) and String.trim(v) != ""
  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end

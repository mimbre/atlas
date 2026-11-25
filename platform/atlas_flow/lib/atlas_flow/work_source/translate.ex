defmodule AtlasFlow.WorkSource.Translate do
  @moduledoc """
  Flow's task ↔ the Runtime's work, on Flow's side (plan m3 §3.5; decision §5.1). Pure.

  **Intent (version 2).** What a run holds as `pending.task` for a task that goes through
  the work source (A4 makes it, Dispatch offers it):

      %{"version" => 2, "key" => "TK-<subject>-<n>", "machinery" => <name> | nil (a supervised flow's),
        "created_at" => <iso8601>, "base_snapshot" => <Code snapshot id>,
        "work" => %{"title", "instructions", "profile", "cost_class",
                    "after_check" => %{"command" => [...]} (only with a check),
                    "input" => %{"base" => %{"base_id", "manifest"},
                                 "change_set" => %{"manifest", "fingerprints"} (F2 only),
                                 "permissions" => "workspace-write" | "read-only",
                                 "result_ref" => "refs/atlas/results/<key>" (a subject's only)}}}

  Title and instructions are built as `AtlasFlow.Activities.Task.request/3` builds them;
  the base comes from `AtlasFlow.Bases`. A review, fix or diagnose (F2) also gets a frozen
  change set: the reviewed task's `result_manifest` and `result_fingerprints`, whose blobs
  Delivery scopes the lease to (`get_blob`, from the result store). No `slot`, `folder`,
  `resume_from`, `repository` or path is ever in it, so none can reach `offered_work/1`.

  **Reports.** A report arrives in contract terms (atom keys, atoms, structs or plain
  maps); `normal/1` turns it into JSON terms (string keys, strings, no nil values), the
  form every other function here takes and the form its digest (`digest/1`) is taken of.
  Then `ended_values/1` gives the task fact's result fields, `attempt_values/1` an attempt
  record's, and `outcome/2` the run's result from the task fact Delivery wrote.
  """

  alias AtlasFlow.Activities.Task

  @answer_bytes 8192
  @read_only ~w(review diagnose)

  # -- Task → offered work ---------------------------------------------------------------

  @doc "The version-2 intent of task `key` without a change set: `intent/7` with nil."
  def intent(spec, subject, key, base, machinery, %DateTime{} = now),
    do: intent(spec, subject, key, base, nil, machinery, now)

  @doc """
  The version-2 intent of task `key` (`spec`, the subject fact, its `base`
  (`%{base_id, manifest, snapshot_id}`), its `change_set` or nil, the machinery name and
  when it was made). `change_set` is `%{manifest, fingerprints}` (atom or string keys):
  the sha256 of a stored result manifest and its roots' `csf_` fingerprints (a list of
  `%{root, fingerprint}`, or the task fact's `result_fingerprints` JSON).
  """
  def intent(spec, subject, key, base, change_set, machinery, %DateTime{} = now) do
    request = Task.request(spec, subject, key)

    input =
      %{
        "base" => %{"base_id" => base.base_id, "manifest" => base.manifest},
        "permissions" => permissions(spec)
      }
      |> put_change_set(change_set)

    work =
      request
      |> Map.take(["title", "instructions", "profile", "cost_class", "after_check"])
      |> Map.put("input", input)

    %{
      "version" => 2,
      "key" => key,
      "machinery" => machinery,
      "created_at" => DateTime.to_iso8601(now),
      "base_snapshot" => base.snapshot_id,
      "work" => work
    }
  end

  defp put_change_set(input, nil), do: input

  defp put_change_set(input, change_set) do
    change_set = normal(change_set)

    fingerprints =
      case change_set["fingerprints"] do
        text when is_binary(text) ->
          case JSON.decode(text) do
            {:ok, list} when is_list(list) -> list
            _ -> []
          end

        list when is_list(list) ->
          list

        _ ->
          []
      end

    Map.put(input, "change_set", %{
      "manifest" => change_set["manifest"],
      "fingerprints" => for(%{} = f <- fingerprints, do: Map.take(f, ["root", "fingerprint"]))
    })
  end

  @doc """
  The intent with its after-check's program placed in the repository's root
  (`AtlasFlow.Bases.root_of/1`): a pulled work's folder holds the repository at
  `<root>/`, and the Runtime runs the check in that folder. A relative program path
  (`bin/check`) becomes `<root>/bin/check`; a bare name (found on PATH) or an absolute path
  is kept, as is an intent without a check or without a repository.
  """
  def root_check(intent, repository) when is_binary(repository) do
    case get_in(intent, ["work", "after_check", "command"]) do
      [program | args] when is_binary(program) ->
        if String.contains?(program, "/") and Path.type(program) == :relative,
          do:
            put_in(intent, ["work", "after_check", "command"], [
              AtlasFlow.Bases.root_of(repository) <> "/" <> program | args
            ]),
          else: intent

      _ ->
        intent
    end
  end

  def root_check(intent, _repository), do: intent

  @doc """
  The intent of task `key` with its result over Git: `input.result_ref`, the ref
  `refs/atlas/results/<key>` the Runtime pushes its result commit to in the base's Code
  repository, instead of a change set. Only for a task outside any ladder and without an
  after-check (a subject's task): nothing publishes or reworks its result from a change set.
  The Runtime makes such a task's folder a Git checkout of its base; a subject's review gets one
  too, and the result it pushes is never read; a subject's fix too, its result on the author's.
  """
  def result_ref(intent, key, true) do
    if get_in(intent, ["work", "after_check"]) == nil and
         get_in(intent, ["work", "input", "permissions"]) == "workspace-write",
       do: put_in(intent, ["work", "input", "result_ref"], result_ref(key)),
       else: intent
  end

  def result_ref(intent, _key, false), do: intent

  @doc "The ref the result commit of task `key` is pushed to: `refs/atlas/results/<key>`."
  def result_ref(key), do: "refs/atlas/results/" <> key

  @doc """
  The key of a subject run's latest result: its latest task (`pending.tasks`) that is no
  review, whose folder is only read, and that ended with a result (completed or
  check_failed): its author's, or its fix's once one ran. A task that ended stuck or
  abandoned left none, so a task run again after it starts from the one before. Nil while
  it has none.
  """
  def latest_result(tasks) do
    tasks
    |> Enum.reverse()
    |> Enum.find_value(fn t ->
      t["task_kind"] != "review" and t["outcome"] in ["completed", "check_failed"] and t["key"]
    end)
  end

  @doc """
  A subject run's latest review that ended with an answer (completed or check_failed), as its
  result keeps it (`verdict`, `findings`): what its fix works on, and what its publication
  shows. Nil while it has none.
  """
  def latest_review(tasks) do
    tasks
    |> Enum.reverse()
    |> Enum.find(
      &(&1["task_kind"] == "review" and &1["outcome"] in ["completed", "check_failed"])
    )
  end

  @doc """
  The permissions a task's work runs with: read-only for a review or a diagnose of the
  loop's latest result. A subject's review or fix (`input` a repository and the latest result)
  works in a Git checkout of that result it may build in (bin/check): writable.
  """
  def permissions(%{"input" => %{"repository" => _, "result" => "latest"}}),
    do: "workspace-write"

  def permissions(%{} = spec), do: permissions(spec["kind"])
  def permissions(kind) when kind in @read_only, do: "read-only"
  def permissions(_kind), do: "workspace-write"

  @doc "Whether `intent` is a version-2 intent Dispatch can offer."
  def intent?(%{"version" => 2, "key" => key, "work" => %{} = work} = intent) do
    text?(key) and text?(intent["created_at"]) and text?(work["title"]) and
      text?(work["instructions"]) and text?(work["profile"]) and text?(work["cost_class"]) and
      base?(get_in(work, ["input", "base"])) and
      change_set_input?(Map.get(work["input"], "change_set", :none)) and
      get_in(work, ["input", "permissions"]) in ["read-only", "workspace-write"]
  end

  def intent?(_), do: false

  defp base?(%{"base_id" => id, "manifest" => manifest}), do: text?(id) and text?(manifest)
  defp base?(_), do: false

  defp change_set_input?(:none), do: true

  defp change_set_input?(%{"manifest" => manifest, "fingerprints" => [_ | _] = fingerprints}),
    do:
      text?(manifest) and
        Enum.all?(fingerprints, &(text?(&1["root"]) and text?(&1["fingerprint"])))

  defp change_set_input?(_), do: false

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
      input: offered_input(input)
    }

    case work["after_check"] do
      %{"command" => [_ | _] = command} -> Map.put(offered, :after_check, %{command: command})
      _ -> offered
    end
  end

  defp offered_input(input) do
    offered = %{
      base: %{base_id: input["base"]["base_id"], manifest: input["base"]["manifest"]},
      permissions: input["permissions"]
    }

    offered =
      if ref = input["result_ref"], do: Map.put(offered, :result_ref, ref), else: offered

    case input["change_set"] do
      %{"manifest" => manifest, "fingerprints" => fingerprints} ->
        Map.put(offered, :change_set, %{
          manifest: manifest,
          fingerprints:
            for(f <- fingerprints, do: %{root: f["root"], fingerprint: f["fingerprint"]})
        })

      _ ->
        offered
    end
  end

  @doc "The lease's input as the task fact keeps it (`input`, JSON): what `get_blob` scopes by."
  def lease_input(%{"work" => %{"input" => input}}), do: JSON.encode!(input)

  @doc "The result ref of a lease input the task fact keeps (`result_ref/3`), or nil."
  def input_result_ref(input) when is_binary(input) do
    case JSON.decode(input) do
      {:ok, %{"result_ref" => ref}} when is_binary(ref) -> ref
      _ -> nil
    end
  end

  def input_result_ref(_input), do: nil

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
  Why an `ended` report brings no result (§3.5, Q8, D-0102): `"returned"`; `"interrupted"`
  (any interruption: a Runtime stop, a crash, a restart of its machine); `"check_interrupted"`
  (completed, but its after-check gave no exit status: a stop or restart cut it short);
  `"supervision"` (cancelled after Flow asked for it because the supervisor changed);
  `"restart"` (cancelled after Flow asked for it because the work was running when Flow
  booted: an update or an outage, `AtlasFlow.Dispatch`); or nil when it brings one.
  `cancel_cause` is the lease's `lease_end_cause` when Flow asked for the cancel. A
  result-less ending's work is offered again as a fresh attempt of the same step.
  """
  def result_less(%{"result" => result}, cancel_cause) do
    check = result["check"]
    no_result_cause(result["kind"], check && ending(check), cancel_cause)
  end

  def result_less(_ended, _cancel_cause), do: nil

  @doc """
  Whether a task fact's ending brought no result (§3.5): the same rule as `result_less/2`,
  decided from the stored ending (`result_kind`, `check_ending`), with `lease_end_cause`
  used only to tell a supervision or restart `cancelled` from any other. A cancel request
  alone never makes an ending result-less: an `ended(completed)` after `cancel_requested`
  keeps its result. Delivery, `outcome/2` and Dispatch's grant all decide by this rule.
  """
  def no_result?(values) do
    v = values || %{}
    no_result_cause(v["result_kind"], v["check_ending"], v["lease_end_cause"]) != nil
  end

  defp no_result_cause("returned", _check_ending, _cause), do: "returned"
  defp no_result_cause("interrupted", _check_ending, _cause), do: "interrupted"
  defp no_result_cause("completed", "no_exit_status", _cause), do: "check_interrupted"
  defp no_result_cause("cancelled", _check_ending, "supervision"), do: "supervision"
  defp no_result_cause("cancelled", _check_ending, "restart"), do: "restart"
  defp no_result_cause(_kind, _check_ending, _cause), do: nil

  @doc """
  Whether the task fact's last attempt was an **empty turn** (UC-Atlas-03: a silent turn
  is ended): `"silent"` when its lease ran out unrenewed (`lost` at expiry: its Runtime,
  or the turn on it, went silent; the Runtime fences such a lease itself), `"empty"` when
  it ended `crashed` with no answer and no result, nil otherwise. A lease lost for any
  other cause (a `restart` among them), or an ending without a result by rule
  (`no_result?/1`, every `interrupted` among them), is no empty turn: it is offered again
  as always. Flow starts an empty turn's task once more on a fresh attempt, and the second
  in a row ends it `abandoned` (`AtlasFlow.Activities.Task`); Dispatch grants such a task
  again only for an attempt its run counted (`retried/1`).
  """
  def empty(values) do
    v = values || %{}

    cond do
      v["lease_state"] == "lost" and v["lease_end_cause"] == "expired" ->
        "silent"

      v["lease_state"] == "done" and v["result_kind"] == "crashed" and
        not text?(v["answer"]) and v["result_state"] != "complete" ->
        "empty"

      true ->
        nil
    end
  end

  @doc """
  The attempts of an intent's task that ended empty and were started again (the run's
  count, kept in its `pending.task`): a list of attempt numbers, `[]` when none.
  """
  def retried(intent), do: for(n <- List.wrap((intent || %{})["retried"]), is_integer(n), do: n)

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

  # How a check ended, when it did not simply exit (§3.5). `no_exit_status`: it did not
  # finish (a cancel, a Runtime stop or a restart cut it short), so the ending is result-less.
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
  Whether a report's change set, when it has one, declares its `base` as text (work_source
  0.2.0: required). A report without a change set has nothing to declare.
  """
  def base_declared?(%{"change_set" => %{} = change_set}), do: text?(change_set["base"])
  def base_declared?(%{"change_set" => _}), do: false
  def base_declared?(_report), do: true

  @doc """
  The change set Flow stores as the result's manifest: the report's roots on the base the
  report declares, **as reported** (Main's ruling, option A), each root without its
  `fingerprint`. That base is the Runtime's content-derived id of the baseline it imported
  and froze on, not the lease's `base_id`; every root's `csf_` is computed on it, and a
  later work's input must sit on it again. The stored manifest is the plain change set
  (`root` and `entries` per root), because a later work gets these bytes as its input
  manifest, which the Runtime validates with `AtlasChangeset.validate/1` (work_source
  `change_set_ref`); the fingerprints go beside it (`result_fingerprints`).
  """
  def manifest(%{"change_set" => %{"base" => base, "roots" => roots}}),
    do: %{"base" => base, "roots" => Enum.map(roots, &Map.delete(&1, "fingerprint"))}

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
  for its entries on the manifest's base (the base the report declared, `manifest/1`).
  `reported` is the roots' fingerprints: a list of `%{"root", "fingerprint"}` or the task
  fact's `result_fingerprints` (JSON of that list).
  """
  def fingerprints_hold?(manifest, reported) when is_binary(reported) do
    case JSON.decode(reported) do
      {:ok, list} when is_list(list) -> fingerprints_hold?(manifest, list)
      _ -> false
    end
  end

  def fingerprints_hold?(%{"base" => base, "roots" => roots}, [_ | _] = reported)
      when is_binary(base) do
    plain = %{"base" => base, "roots" => roots}

    with :ok <- AtlasChangeset.validate(plain) do
      computed = Enum.map(AtlasChangeset.fingerprints(plain), &{&1.root, &1.fingerprint})
      reported = for %{} = r <- reported, do: {r["root"], r["fingerprint"]}
      Enum.sort(computed) == Enum.sort(reported)
    else
      _ -> false
    end
  end

  def fingerprints_hold?(_manifest, _reported), do: false

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
  - `:retry`: the lease ended without a result (`no_result?/1`: returned, any
    interruption, a check that gave no exit status, a `cancelled` after a supervision or
    restart cancel request); the work is offered again as a fresh attempt of the same step;
  - `{:empty, why, attempt}`: attempt `attempt` was an empty turn (`empty/1`, `why`
    `silent` or `empty`); the run decides whether it is started again;
  - `:waiting`: no result yet (no lease, a live one, or a result still incomplete).
  """
  def outcome(fact, checked?) do
    v = (fact || %{})["values"] || %{}

    cond do
      why = empty(v) ->
        {:empty, why, v["attempt"]}

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

defmodule AtlasFlow.Ladder do
  @moduledoc """
  The review → fix loop of a package and its strategy ladder (F2; the F2/F3 plan rev 3
  §3.1, §3.3, §4, §5 F2-L). #297's rules, unchanged except rung (e) and the plan's §4
  edits, with Main's rulings on the F2-L review. Pure: it reads only its arguments and
  writes nothing. The Engine (`Task.step/4`, F2-E) asks `next/5` what follows a task's
  end or a supervisor's answer, builds the next task through
  `AtlasFlow.WorkSource.Translate` with `sections/3` in its instructions, and keeps the
  ladder it returns in the run (`pending.ladder`).

  **Tasks.** `next/5` takes the package's tasks as the Engine sees them, one map each
  (string keys; any order: they are put in the order of their key's number):

    * `"key"` (`TK-<package>-<n>`), `"kind"` (`author`, `fix`, `review` or `diagnose`),
      `"outcome"` once it ended (`completed`, `check_failed`, `stuck` or `abandoned`),
      `"reason"` (a stuck task's, e.g. `refused: policy_forbids`), `"profile"`;
    * `"base"`: `%{"base_id", "manifest", "base_snapshot"}`, the base its intent pinned;
    * `"result_state"`, `"result_manifest"`, `"result_fingerprints"`, as Delivery wrote
      them on the task fact; `"check"`: `%{"ending", "exit_status", "tail"}`;
    * `"answer"`: the worker's answer (a review's verdict, a diagnosis);
    * `"turn_id"`: the turn of its last attempt (provenance);
    * a review's `"based_on"` (the reviewed task's `result_fingerprints`, as Flow gave it),
      a fix's or diagnose's `"reviewed"` (the key of the task whose change set it got).

  **Steps.** `next/5` answers `{step, ladder}`:

    * `{:task, task}`: the next task, `%{"step", "kind", "role", "profile", "cost_class",
      "permissions", "check", "base", "change_set", "based_on", "reviewed", "findings",
      "diagnosis", "choice", "flaky", "rung"}` (nil where none applies). `step` is
      `author`, `review`, `fix`, `diagnose`, `fresh` or `stronger`. Every task starts from
      the **original** base (the first author's); a review, fix or diagnose gets the change
      set of the task it reviews, fixes or diagnoses (`%{"manifest", "fingerprints"}`);
    * `{:ready, %{"task", "review"}}`: the latest result is approved;
    * `{:held, %{"reason", "task", "question"}}`: the package is held, and its supervisor
      is asked (`question`, below; never a silent hold);
    * `{:escalate, question}`: rung (e), the package waits for its supervisor's `answer`.
      **No write**: Flow writes no `decision` fact (plan §3.3);
    * `:none`: nothing follows.

  **Rules** (#297 §4):

    * an author or fix whose result is complete → `review` of exactly that result; its
      check failed → `fix` on it (or on the latest result when it stored none);
    * `approved` → `ready`; `changes_required` → `fix` on the reviewed result, with the
      findings;
    * an invalid review (no verdict; changes required without a finding; in an author's
      turn, a belt; superseded: its `based_on` is not the latest result's fingerprints) →
      one re-review per reason, then `held` with that reason (R1). The counters count in
      a row: every new result, valid verdict and climb resets them. A superseded verdict
      while a review of the latest result runs → `:none`;
    * each rung has a budget of two fix tasks; a third would be needed → climb;
    * a stuck task → `held`, except the rung's own task refused by policy
      (`policy_forbids`, `no_permitted_option`): that rung is skipped. A review that did
      not complete → `held`;
    * an abandoned task (a lost lease) is started once more; abandoned again → `held`,
      asking `retry | stronger | abandon` (Main's ruling 2).

  **Ladder** (#297 §4.1): no rung → (a) `diagnose` the latest result (read-only) → (b)
  `fresh` → (c) `stronger` (`deep_coding_max`; skipped when not offered, plan §7) → (d) a
  final `diagnose` that phrases the scope choice → (e) `escalate`. The diagnosis goes into
  every later task. `unclear_spec` → (d); `flaky_test` → one fix that stabilises it
  (budget 1); `environment` needing `native_check` → `held`; needing `access` → (e).

  **Rung (e)** (plan §3.3, Main's ruling 1). The question carries the diagnosis's worded
  options (recommended first) next to `fresh`, `stronger` (when offered) and `abandon`.
  When the recommended option is `safe_to_continue` and touches no authority
  (credentials, permissions, production, spending), the question's `"continue"` is a
  fresh author on it, to run while the supervisor decides; otherwise it is nil and the
  package waits. An answer (`next(ladder, {:answer, a}, …)`) applies only while the
  ladder waits (escalated or held); one the question does not offer asks it again.
  """

  @budget 2
  @rereviews 1
  @retries 1
  @findings 20
  @finding_chars 300
  @clip 2000
  @stronger "deep_coding_max"
  @causes ~w(wrong_assumption unclear_spec flaky_test environment other)
  @policy ["refused: policy_forbids", "refused: no_permitted_option"]
  @authority ~w(credentials permissions production spending)
  @fixed ~w(fresh stronger abandon retry hold)
  @option_fields ~w(id text details rule consequences)

  @authoring ~w(author fix)

  @doc "The fix tasks a rung allows (#297: two)."
  def budget, do: @budget

  @doc """
  The step after `event`, and the ladder to keep. `ladder` is the run's `pending.ladder`
  (nil at first); `event` is `{:ended, key}` (the task that just ended) or `{:answer, a}`
  (one of the waiting question's `answers`); `tasks` the package's tasks (above);
  `profiles` the profiles the supervisor's policy offers (rung (c) needs
  `deep_coding_max`); `limits` may set `"budget"`, `"rereviews"` and `"retries"` (the
  defaults: 2, 1 and 1).
  """
  def next(ladder, event, tasks, profiles, limits \\ %{}) do
    tasks = order(tasks)
    ladder = Map.merge(new(tasks), ladder || %{})

    limits = %{
      budget: limits["budget"] || @budget,
      rereviews: limits["rereviews"] || @rereviews,
      retries: limits["retries"] || @retries
    }

    ctx = %{tasks: tasks, profiles: List.wrap(profiles), limits: limits}

    case event do
      {:ended, key} ->
        case Enum.find(tasks, &(&1["key"] == key)) do
          nil -> {:none, ladder}
          task -> ended(task, remember(ladder, tasks), ctx)
        end

      {:answer, answer} ->
        answered(answer, ladder, ctx)
    end
  end

  defp new(tasks) do
    %{
      "version" => 2,
      "rung" => nil,
      "fixes" => 0,
      "rereviews" => %{},
      "retries" => 0,
      "base" => original_base(tasks),
      "authors" => authors(tasks),
      "diagnosis" => nil,
      "decision" => nil,
      "choice" => nil,
      "awaiting" => nil
    }
  end

  # -- A task ended ------------------------------------------------------------------------

  defp ended(%{"outcome" => "abandoned"} = task, ladder, ctx) do
    if ladder["retries"] < ctx.limits.retries,
      do: {{:task, again(task, ladder, ctx)}, %{ladder | "retries" => ladder["retries"] + 1}},
      else: held("abandoned", task, ladder, ctx)
  end

  defp ended(task, ladder, ctx), do: ended_once(task, %{ladder | "retries" => 0}, ctx)

  defp ended_once(%{"outcome" => "stuck"} = task, ladder, ctx) do
    if task["reason"] in @policy and rung_task?(ladder, task["kind"]),
      do: climb(ladder, ctx),
      else: held("stuck", task, ladder, ctx)
  end

  defp ended_once(%{"kind" => kind} = task, ladder, ctx) when kind in @authoring do
    case task["outcome"] do
      "completed" ->
        if result?(task),
          do: {{:task, review(task, ladder)}, %{ladder | "rereviews" => %{}}},
          else: held("no_result", task, ladder, ctx)

      "check_failed" ->
        fix_or_climb(if(result?(task), do: task, else: latest(ctx.tasks)), nil, ladder, ctx)

      _ ->
        held("stuck", task, ladder, ctx)
    end
  end

  defp ended_once(%{"kind" => "review"} = review, ladder, ctx) do
    latest = latest(ctx.tasks)

    cond do
      review["outcome"] != "completed" ->
        held("review_not_completed", review, ladder, ctx)

      latest == nil ->
        held("no_result", review, ladder, ctx)

      is_binary(review["turn_id"]) and review["turn_id"] in (ladder["authors"] || []) ->
        rereview("author_turn", review, latest, ladder, ctx)

      review["based_on"] != latest["result_fingerprints"] ->
        if in_flight?(latest, ctx),
          do: {:none, ladder},
          else: rereview("superseded", review, latest, ladder, ctx)

      true ->
        case verdict(review["answer"]) do
          {:ok, "approved", _} ->
            {{:ready, %{"task" => latest["key"], "review" => review["key"]}},
             %{ladder | "rereviews" => %{}}}

          {:ok, "changes_required", []} ->
            rereview("no_findings", review, latest, ladder, ctx)

          {:ok, "changes_required", findings} ->
            fix_or_climb(latest, findings, %{ladder | "rereviews" => %{}}, ctx)

          :error ->
            rereview("no_verdict", review, latest, ladder, ctx)
        end
    end
  end

  defp ended_once(%{"kind" => "diagnose"} = task, ladder, ctx) do
    diagnosis =
      (task["outcome"] == "completed" && diagnosis(task["answer"])) ||
        %{"cause" => "other", "evidence" => "no diagnosis"}

    diagnosed(%{ladder | "diagnosis" => diagnosis}, diagnosis, task, ctx)
  end

  defp ended_once(task, ladder, ctx), do: held("unknown_kind", task, ladder, ctx)

  # The task the rung itself started: a policy refusal of it skips the rung (#297).
  defp rung_task?(%{"rung" => rung}, kind),
    do: (rung in ["b", "c"] and kind == "author") or (rung in ["a", "d"] and kind == "diagnose")

  defp in_flight?(latest, ctx),
    do:
      Enum.any?(
        ctx.tasks,
        &(&1["kind"] == "review" and &1["based_on"] == latest["result_fingerprints"] and
            &1["outcome"] in [nil, ""])
      )

  defp diagnosed(ladder, diagnosis, task, ctx) do
    decision = diagnosis["decision"]

    case {ladder["rung"], diagnosis["cause"], diagnosis["needs"]} do
      {"d", _, _} when is_map(decision) ->
        escalate(diagnosis["cause"], decision, ladder, ctx)

      {"d", _, _} ->
        held("no_decision", task, ladder, ctx)

      {_, "unclear_spec", _} ->
        diagnose(rung(ladder, "d"), ctx)

      {_, "flaky_test", _} ->
        flaky_fix(ladder, ctx)

      {_, "environment", "native_check"} ->
        held("native_check", task, ladder, ctx)

      {_, "environment", "access"} when is_map(decision) ->
        escalate("access", decision, ladder, ctx)

      {_, "environment", "access"} ->
        held("access_no_decision", task, ladder, ctx)

      _ ->
        author("fresh", rung(ladder, "b"), ctx)
    end
  end

  # -- An answer resumes ---------------------------------------------------------------------

  defp answered(_answer, %{"awaiting" => nil} = ladder, _ctx), do: {:none, ladder}

  defp answered(answer, %{"awaiting" => %{} = awaiting} = ladder, ctx) do
    question = awaiting["question"]
    resumed = %{ladder | "awaiting" => nil}

    cond do
      answer not in question["answers"] ->
        {asked(awaiting), ladder}

      answer == "abandon" ->
        {:none, resumed}

      answer == "retry" ->
        retry(awaiting["task"], resumed, ctx)

      answer in ["fresh", "stronger"] ->
        author(answer, %{rung(resumed, "e") | "choice" => nil}, ctx)

      true ->
        author("fresh", %{rung(resumed, "e") | "choice" => option(question, answer)}, ctx)
    end
  end

  defp retry(key, ladder, ctx) do
    case Enum.find(ctx.tasks, &(&1["key"] == key)) do
      nil -> {:none, ladder}
      task -> {{:task, again(task, ladder, ctx)}, %{ladder | "retries" => ctx.limits.retries}}
    end
  end

  defp asked(%{"on" => "escalation", "question" => q}), do: {:escalate, q}
  defp asked(%{"on" => "held"} = a), do: {:held, Map.take(a, ["reason", "task", "question"])}

  defp option(question, id), do: Enum.find(question["options"], &(&1["id"] == id))

  # -- Steps ---------------------------------------------------------------------------------

  defp review(task, ladder) do
    step("review", ladder, %{
      "change_set" => change_set(task),
      "based_on" => task["result_fingerprints"],
      "reviewed" => task["key"]
    })
  end

  # A fix of `task`'s change set (the reviewed one, the one whose check failed, or the
  # latest result) while the rung's budget lasts; else the ladder climbs.
  defp fix_or_climb(task, findings, ladder, ctx) do
    if ladder["fixes"] < budget(ladder, ctx) do
      ladder = %{ladder | "fixes" => ladder["fixes"] + 1}
      {{:task, fix(task, findings, ladder)}, ladder}
    else
      climb(ladder, ctx)
    end
  end

  defp fix(task, findings, ladder) do
    step("fix", ladder, %{
      "change_set" => task && change_set(task),
      "reviewed" => task && task["key"],
      "findings" => findings,
      "check" => true
    })
  end

  # #297: a flaky test gets one fix that stabilises it.
  defp flaky_fix(ladder, ctx) do
    ladder = Map.merge(ladder, %{"fixes" => 1, "rereviews" => %{}, "flaky" => true})
    {{:task, fix(latest(ctx.tasks), nil, ladder)}, ladder}
  end

  defp budget(%{"flaky" => true}, _ctx), do: 1
  defp budget(_ladder, ctx), do: ctx.limits.budget

  defp climb(ladder, ctx) do
    case ladder["rung"] do
      nil ->
        if latest(ctx.tasks),
          do: diagnose(rung(ladder, "a"), ctx),
          else: author("fresh", rung(ladder, "b"), ctx)

      "a" ->
        author("fresh", rung(ladder, "b"), ctx)

      "b" ->
        if @stronger in ctx.profiles,
          do: author("stronger", rung(ladder, "c"), ctx),
          else: diagnose(rung(ladder, "d"), ctx)

      "c" ->
        diagnose(rung(ladder, "d"), ctx)

      "d" ->
        held("no_decision", nil, ladder, ctx)

      _e ->
        held("no_rung_left", nil, ladder, ctx)
    end
  end

  defp rung(ladder, rung) do
    ladder
    |> Map.merge(%{"rung" => rung, "fixes" => 0, "rereviews" => %{}})
    |> Map.delete("flaky")
  end

  defp diagnose(ladder, ctx), do: {{:task, diagnose_step(ladder, ctx)}, ladder}

  defp diagnose_step(ladder, ctx) do
    latest = latest(ctx.tasks)

    step("diagnose", ladder, %{
      "change_set" => latest && change_set(latest),
      "reviewed" => latest && latest["key"]
    })
  end

  defp author(name, ladder, _ctx), do: {{:task, author_step(name, ladder)}, ladder}

  defp author_step(name, ladder), do: step(name, ladder, %{"check" => true})

  # Rung (e): the question for the supervisor, and nothing written (plan §3.3). Work goes
  # on on the recommended option while they decide only when it is safe and touches no
  # authority (Main's ruling 1, #297 §4.1 e).
  defp escalate(reason, decision, ladder, ctx) do
    ladder = rung(%{ladder | "decision" => decision, "choice" => nil}, "e")
    [default | _] = decision["options"]
    safe = decision["safe_to_continue"] and not decision["authority"]
    ladder = if safe, do: %{ladder | "choice" => default}, else: ladder

    worded = Enum.map(decision["options"], & &1["id"])
    answers = worded ++ fixed(["fresh", "stronger", "abandon"], ctx)
    latest = latest(ctx.tasks)

    question = %{
      "reason" => reason,
      "rung" => "e",
      "latest" => latest && latest["key"],
      "question" => decision["question"],
      "rationale" => decision["rationale"],
      "options" => decision["options"],
      "answers" => answers,
      "recommended" => hd(answers),
      "safe_to_continue" => decision["safe_to_continue"],
      "authority" => decision["authority"],
      "continue" => if(safe, do: author_step("fresh", ladder))
    }

    {{:escalate, question},
     %{ladder | "awaiting" => %{"on" => "escalation", "question" => question}}}
  end

  # Held, and the supervisor asked (plan §3.3: `held` presents the same answers; Main's
  # ruling 2 for an abandoned task: retry first). Held while an escalation waits (the
  # work that went on on its default failed), its worded options stay on offer (ruling 1).
  defp held(reason, task, ladder, ctx) do
    pending = escalation(ladder)
    worded = Enum.map(pending["options"] || [], & &1["id"])

    answers =
      if reason == "abandoned",
        do: fixed(["retry" | worded] ++ ["stronger", "abandon"], ctx),
        else: worded ++ fixed(["fresh", "stronger", "abandon"], ctx)

    latest = latest(ctx.tasks)

    question =
      Map.merge(Map.take(pending, ["question", "rationale"]), %{
        "reason" => reason,
        "rung" => ladder["rung"],
        "latest" => latest && latest["key"],
        "options" => pending["options"] || [],
        "answers" => answers,
        "recommended" => hd(answers),
        "continue" => nil
      })

    held = %{"reason" => reason, "task" => task && task["key"], "question" => question}
    {{:held, held}, %{ladder | "awaiting" => Map.put(held, "on", "held")}}
  end

  defp escalation(%{"awaiting" => %{"on" => "escalation", "question" => q}}), do: q
  defp escalation(_ladder), do: %{}

  defp fixed(answers, ctx),
    do: Enum.filter(answers, &(&1 != "stronger" or @stronger in ctx.profiles))

  # The same task again (its lease was lost): only the retry counter moves.
  defp again(task, ladder, ctx) do
    case task["kind"] do
      "review" ->
        reviewed =
          Enum.find(ctx.tasks, &(result?(&1) and &1["result_fingerprints"] == task["based_on"]))

        review(reviewed || latest(ctx.tasks), ladder)

      "fix" ->
        reviewed = Enum.find(ctx.tasks, &(&1["key"] == task["reviewed"] and result?(&1)))
        fix(reviewed || latest(ctx.tasks), findings_before(task, ctx), ladder)

      "diagnose" ->
        diagnose_step(ladder, ctx)

      _author ->
        cond do
          ladder["rung"] == "c" or task["profile"] == @stronger -> author_step("stronger", ladder)
          ladder["rung"] == nil -> author_step("author", ladder)
          true -> author_step("fresh", ladder)
        end
    end
  end

  # The findings of the last changes-required review before `task`.
  defp findings_before(task, ctx) do
    ctx.tasks
    |> Enum.take_while(&(&1["key"] != task["key"]))
    |> Enum.reverse()
    |> Enum.find_value(fn t ->
      case t["kind"] == "review" and verdict(t["answer"]) do
        {:ok, "changes_required", [_ | _] = findings} -> findings
        _ -> nil
      end
    end)
  end

  # What each step runs as (plan §3.1).
  @shapes %{
    "author" => {"author", "developer", "deep_coding", "standard", "workspace-write"},
    "fresh" => {"author", "developer", "deep_coding", "standard", "workspace-write"},
    "stronger" => {"author", "developer", @stronger, "high", "workspace-write"},
    "fix" => {"fix", "developer", "deep_coding", "standard", "workspace-write"},
    "review" => {"review", "developer", "independent_review", "standard", "read-only"},
    "diagnose" => {"diagnose", "investigator", "deep_coding", "standard", "read-only"}
  }

  defp step(name, ladder, extra) do
    {kind, role, profile, cost, permissions} = Map.fetch!(@shapes, name)

    Map.merge(
      %{
        "step" => name,
        "kind" => kind,
        "role" => role,
        "profile" => profile,
        "cost_class" => cost,
        "permissions" => permissions,
        "check" => false,
        "base" => ladder["base"],
        "change_set" => nil,
        "based_on" => nil,
        "reviewed" => nil,
        "findings" => nil,
        "diagnosis" => if(kind in ["author", "fix", "diagnose"], do: ladder["diagnosis"]),
        "choice" => if(kind == "author", do: ladder["choice"]),
        "flaky" => kind == "fix" and ladder["flaky"] == true,
        "rung" => ladder["rung"]
      },
      extra
    )
  end

  defp remember(ladder, tasks) do
    %{ladder | "base" => ladder["base"] || original_base(tasks), "authors" => authors(tasks)}
  end

  # R1: one re-review per reason, in a row; the next invalid review of that reason holds.
  defp rereview(reason, review, latest, ladder, ctx) do
    n = Map.get(ladder["rereviews"], reason, 0)

    if n < ctx.limits.rereviews,
      do: {{:task, review(latest, ladder)}, put_in(ladder, ["rereviews", reason], n + 1)},
      else: held("invalid_review:" <> reason, review, ladder, ctx)
  end

  # -- Reading tasks -------------------------------------------------------------------------

  @doc """
  The latest result: the newest author or fix task whose result is stored complete
  (`result_state: complete`) with a `result_manifest`; nil when none is.
  """
  def latest(tasks) do
    tasks
    |> order()
    |> Enum.filter(&(&1["kind"] in @authoring and result?(&1)))
    |> List.last()
  end

  @doc "The turns of the package's author and fix tasks (the lesson-8 belt)."
  def authors(tasks) do
    for t <- order(tasks),
        t["kind"] in @authoring,
        is_binary(t["turn_id"]),
        uniq: true,
        do: t["turn_id"]
  end

  @doc """
  The original base: the first author task's `%{"base_id", "manifest", "base_snapshot"}`;
  nil when there is none yet.
  """
  def original_base(tasks) do
    case Enum.find(order(tasks), &(&1["kind"] == "author")) do
      %{"base" => %{} = base} -> Map.take(base, ["base_id", "manifest", "base_snapshot"])
      _ -> nil
    end
  end

  defp result?(t),
    do:
      t["result_state"] == "complete" and is_binary(t["result_manifest"]) and
        t["result_manifest"] != ""

  defp change_set(t),
    do: %{"manifest" => t["result_manifest"], "fingerprints" => t["result_fingerprints"]}

  defp order(tasks), do: Enum.sort_by(List.wrap(tasks), &number(&1["key"]))

  defp number(key) when is_binary(key) do
    with [n] <- Regex.run(~r/-(\d+)$/, key, capture: :all_but_first),
         {i, ""} <- Integer.parse(n),
         do: i,
         else: (_ -> 0)
  end

  defp number(_), do: 0

  # -- Parsing answers (#297) ----------------------------------------------------------------

  @doc """
  A review's verdict from its answer, which ends with a JSON block `{"verdict":
  "approved" | "changes_required", "findings": [...]}`, fenced (any fence) or bare:
  `{:ok, verdict, findings}`, at most 20 findings of at most 300 characters each (a
  finding that is not a text is JSON-encoded). `:error` when the answer does not end
  with such a block, or its `findings` is not a list. A `changes_required` without
  findings parses with `[]`; `next/5` counts it as the invalid reason `no_findings`.
  """
  def verdict(answer) do
    with {:ok, %{"verdict" => verdict} = block} <- last_json(answer),
         true <- verdict in ["approved", "changes_required"],
         {:ok, findings} <- findings(block["findings"]) do
      {:ok, verdict, findings}
    else
      _ -> :error
    end
  end

  defp findings(nil), do: {:ok, []}

  defp findings(list) when is_list(list) do
    texts =
      for f <- Enum.take(list, @findings) do
        text = if is_binary(f), do: f, else: JSON.encode!(f)
        String.slice(text, 0, @finding_chars)
      end

    {:ok, texts}
  end

  defp findings(_), do: :error

  @doc """
  A diagnosis from a diagnose task's answer, which ends with a JSON block `{cause,
  evidence, advice, needs?, decision?}` (#297 §4.1 a): the map, or nil when it cannot be
  parsed. `cause` is one of `wrong_assumption`, `unclear_spec`, `flaky_test`,
  `environment`, `other`; texts are clipped to 2000 characters. A `decision` is
  `{question, rationale, options: [{id, text, details, rule, consequences}],
  safe_to_continue, authority}`, the recommended option first, at most 20 options of at
  most 300 characters per field; an option that is not complete, or whose id is one of
  the fixed answers, is left out.
  """
  def diagnosis(answer) do
    with {:ok, %{"cause" => cause} = block} <- last_json(answer),
         true <- cause in @causes do
      %{
        "cause" => cause,
        "evidence" => clip(block["evidence"]),
        "advice" => clip(block["advice"]),
        "needs" => if(block["needs"] in ["access", "native_check"], do: block["needs"]),
        "decision" => decision(block["decision"])
      }
      |> Map.reject(fn {_, v} -> v == nil end)
    else
      _ -> nil
    end
  end

  defp decision(%{"question" => q, "options" => [first | _] = options} = d) when is_binary(q) do
    options =
      for o <- options,
          option?(o),
          do: Map.new(@option_fields, &{&1, String.slice(o[&1], 0, @finding_chars)})

    options = options |> Enum.uniq_by(& &1["id"]) |> Enum.take(@findings)
    touches = for t <- List.wrap(d["touches"]), t in @authority, do: t

    if text?(q) and options != [] do
      %{
        "question" => clip(q),
        "rationale" => clip(d["rationale"]),
        "options" => options,
        # Safe only for the option the diagnosis recommended: when it was left out, the
        # next one is recommended, but nobody said work may go on on it (ruling 1).
        "safe_to_continue" => d["safe_to_continue"] == true and option?(first),
        "authority" => d["authority"] == true or touches != []
      }
    end
  end

  defp decision(_), do: nil

  defp option?(o),
    do:
      is_map(o) and Enum.all?(@option_fields, &text?(o[&1])) and
        o["id"] =~ ~r/^[a-z][a-z0-9_-]{0,63}$/ and o["id"] not in @fixed

  # The last JSON object the answer ends with (a fenced block or bare).
  defp last_json(answer) when is_binary(answer) do
    text =
      answer
      |> String.trim_trailing()
      |> String.replace_suffix("```", "")
      |> String.trim_trailing()

    if String.ends_with?(text, "}") do
      :binary.matches(text, "{")
      |> Enum.reverse()
      |> Enum.take(400)
      |> Enum.find_value(:error, fn {at, _} ->
        case JSON.decode(binary_part(text, at, byte_size(text) - at)) do
          {:ok, %{} = map} -> {:ok, map}
          _ -> nil
        end
      end)
    else
      :error
    end
  end

  defp last_json(_), do: :error

  defp clip(text) when is_binary(text), do: String.slice(text, 0, @clip)
  defp clip(_), do: nil

  defp text?(v), do: is_binary(v) and String.trim(v) != ""

  # -- Instructions (#297's sections/3) ------------------------------------------------------

  @review_format """
  ## Your answer

  Review the result you are given; change nothing. End your answer with one JSON block, \
  and nothing after it: {"verdict": "approved" | "changes_required", "findings": ["…"]}. \
  Give at most 20 findings of at most 300 characters each; changes_required needs at \
  least one.\
  """

  @diagnose_format """
  ## Your answer

  Find out why the work on this package keeps failing; change nothing. End your answer \
  with one JSON block, and nothing after it: {"cause": "wrong_assumption" | \
  "unclear_spec" | "flaky_test" | "environment" | "other", "evidence": "…", "advice": \
  "…"}. For an environment cause, add "needs": "access" when it needs access, \
  credentials or permissions, or "native_check" when only a privileged command can \
  check it. When the supervisor must choose, add "decision": {"question": "…", "rationale": \
  "…", "options": [{"id": "…", "text": "…", "details": "…", "rule": "…", \
  "consequences": "…"}], "safe_to_continue": true | false, "touches": []}, the \
  recommended option first; safe_to_continue says work may go on on it before the supervisor \
  answers, and touches names any of credentials, permissions, production or spending.\
  """

  @final_format """
  ## The scope choice

  The fixes, a fresh author and a stronger profile did not resolve it. Phrase the choice \
  the supervisor must make about this package's scope as the decision of your JSON block, \
  with the recommended option first.\
  """

  @doc """
  The sections the next task of the loop adds to its instructions (#297 §4, §4.1): for a
  review or diagnosis its answer format (and at rung (d) the scope choice); for a fix
  what to fix (the review's findings, or the check's output); for an author on a rung
  what failed before; from rung (a) on the diagnosis; and for an author on a chosen
  option (rung e) that option. `kind` is the next task's kind.
  """
  def sections(kind, ladder, tasks) do
    tasks = order(tasks)
    diagnosis = ladder["diagnosis"]

    [
      kind == "fix" and fix_section(ladder, tasks),
      kind in ["author", "fix", "diagnose"] and is_map(diagnosis) and
        diagnosis_section(diagnosis),
      kind == "author" and ladder["rung"] != nil and history_section("What failed before", tasks),
      kind == "author" and choice_section(ladder),
      kind == "diagnose" and history_section("What happened", tasks),
      kind == "diagnose" and @diagnose_format,
      kind == "diagnose" and ladder["rung"] == "d" and @final_format,
      kind == "review" and @review_format
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&("\n\n" <> &1))
  end

  # What the fix is for: the last ended review's findings, or the last check's output.
  defp fix_section(ladder, tasks) do
    last =
      tasks
      |> Enum.reverse()
      |> Enum.find(
        &(&1["kind"] in ["review", "author", "fix"] and
            &1["outcome"] in ["completed", "check_failed"])
      )

    body =
      case last do
        %{"kind" => "review"} ->
          "The review found:\n\n" <> Enum.map_join(found(last), "\n", &("- " <> &1))

        %{} ->
          check_text(last["check"])

        nil ->
          check_text(nil)
      end

    flaky =
      if ladder["flaky"], do: "\n\nThe diagnosis found a flaky test: stabilise it.", else: ""

    "## What to fix\n\n" <> body <> flaky
  end

  defp found(review) do
    case verdict(review["answer"]) do
      {:ok, _, findings} -> findings
      :error -> []
    end
  end

  defp check_text(%{"ending" => ending}) when ending in ["cancelled", "interrupted", "not_run"],
    do: "The check did not finish; run bin/check."

  defp check_text(%{} = check) do
    status = if check["ending"], do: check["ending"], else: "exit #{check["exit_status"]}"
    "The check failed (#{status}). The tail of its output:\n\n```\n#{check["tail"]}\n```"
  end

  defp check_text(_), do: "The check did not finish; run bin/check."

  defp diagnosis_section(d) do
    "## Diagnosis\n\nCause: #{d["cause"]}." <>
      if(d["evidence"], do: "\n\nEvidence: #{d["evidence"]}", else: "") <>
      if(d["advice"], do: "\n\nAdvice: #{d["advice"]}", else: "")
  end

  defp choice_section(%{"choice" => %{} = o, "decision" => d} = ladder) do
    who =
      if ladder["awaiting"],
        do: "The supervisor decides later; continue on the recommended option",
        else: "The supervisor chose"

    "## Decision\n\n#{d && d["question"]} #{who}: #{o["text"]}. #{o["rule"]}"
  end

  defp choice_section(_), do: nil

  defp history_section(heading, tasks) do
    lines =
      for t <- tasks, t["outcome"] not in [nil, ""] do
        "- #{t["key"]} (#{t["kind"]}): #{t["outcome"]}" <> history_detail(t)
      end

    "## #{heading}\n\n" <> Enum.join(lines, "\n")
  end

  defp history_detail(%{"kind" => "review"} = t) do
    case found(t) do
      [_ | _] = f -> ", findings: " <> Enum.join(f, "; ")
      [] -> ""
    end
  end

  defp history_detail(%{"outcome" => "check_failed", "check" => check}),
    do: ", check: " <> String.slice(check_text(check), 0, 1200)

  defp history_detail(%{"reason" => reason}) when is_binary(reason), do: ", " <> reason
  defp history_detail(_), do: ""
end

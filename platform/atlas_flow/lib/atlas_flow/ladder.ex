defmodule AtlasFlow.Ladder do
  @moduledoc """
  The review and fix loop and its strategy ladder (Flow Engine plan 2026-11-17 §4, §4.1,
  §5 F2): what comes after a task of the loop (`ladder: true` in the DSL) ended, decided
  from the run's own task results only. No IO; the task activity
  (`AtlasFlow.Activities.Task`) calls it when a task ends, and when it builds the next
  task's request.

  **Steps** (the branch the run takes): `review`, `fix`, `diagnose`, `fresh` (rung b: a
  fresh author from the original base, in a new conversation), `stronger` (rung c: the
  same with `deep_coding_max`), `ready` (approved), `decide` (a person decides, rung e)
  and `held`.

  **Rules** (§4):

  - an author or fix task whose check passed → `review` of exactly that result;
  - its check failed, timed out or did not finish → `fix` on that result;
  - a review `approved` → `ready`; `changes_required` → `fix` on the reviewed result,
    with the findings;
  - a review that cannot be parsed → one new review, then the ladder; a review in the
    conversation of an author or fix attempt of the run (lesson 8), or whose `based_on`
    is not the reviewed result's fingerprint (superseded) → one new review, then `held`;
  - each rung has a budget of two fix tasks (§4.1); a third would be needed → climb;
  - any other end (stuck, abandoned) → `held` (before F5), except a rung's task that the
    Runtime's policy refused (`policy_forbids`, `no_permitted_option`): that rung is
    skipped.

  **Ladder** (§4.1): no rung → (a) `diagnose` the latest result (read-only, with the
  history) → (b) `fresh` → (c) `stronger` → (d, before F4) a final `diagnose` that
  phrases the scope choice → (e) the decision. The diagnosis goes into every later task's
  instructions. A diagnosis of `unclear_spec` goes to (d); `flaky_test` gives one fix
  that stabilises the test; `environment` that needs access goes to (e), one that needs a
  privileged check is `held` until `native_check` (F5). At (e) the decision is recorded as
  a proposed `decision` (recommended option first, a decline last); when its default is
  `safe_to_continue` and touches no authority, work continues on it (a `fresh` author
  with the default), otherwise `decide`. Nothing is left after (e): `held`.

  The ladder's own state (`rung`, the fixes and re-reviews it spent, the diagnosis and
  the decision) is the run's (`pending.ladder`, in the `flow_run` fact), so it survives a
  restart; Flow's own records never drive it.
  """

  @steps ~w(review fix diagnose fresh stronger ready decide held)
  @fixes 2
  @causes ~w(wrong_assumption unclear_spec flaky_test environment other)
  @findings 20
  @finding_chars 300
  @policy ["refused: policy_forbids", "refused: no_permitted_option"]
  @authority ~w(credentials permissions production spending)

  def steps, do: @steps

  @doc "A run's ladder before its first rung."
  def new, do: %{"version" => 1, "rung" => nil, "fixes" => 0, "reviews" => 0}

  @doc "The run's ladder (`pending.ladder`), or a new one."
  def of(run), do: get_in(run, ["pending", "ladder"]) || new()

  @doc """
  What follows the task that just ended: `{step, ladder, writes}`. `kind` is the task's
  kind (author, review, fix or diagnose), `result` its result as it joins the run's
  tasks, `tasks` the run's earlier task results (oldest first), `subject_key` the
  subject's key (for a decision's context). `writes` are Facts writes besides the task's
  own record (a proposed decision).
  """
  def next(ladder, kind, result, tasks, subject_key \\ nil)

  def next(ladder, kind, %{"outcome" => outcome} = result, tasks, subject_key) do
    cond do
      outcome == "abandoned" ->
        held(ladder, "abandoned")

      outcome == "stuck" and result["reason"] in @policy and rung_task?(ladder, kind) ->
        climb(ladder, tasks, subject_key)

      outcome == "stuck" ->
        held(ladder, "stuck: #{result["reason"] || result["kind"]}")

      kind in ["author", "fix"] ->
        authored(ladder, outcome, tasks, subject_key)

      kind == "review" ->
        reviewed(ladder, result, tasks, subject_key)

      kind == "diagnose" ->
        diagnosed(ladder, result, subject_key)

      true ->
        held(ladder, "no loop step after a #{kind} task")
    end
  end

  # The task the rung itself started: refusing it skips the rung (§4: policy refusals).
  defp rung_task?(%{"rung" => rung}, kind),
    do: (rung in ["b", "c"] and kind == "author") or (rung in ["a", "d"] and kind == "diagnose")

  defp authored(ladder, "completed", _tasks, _subject),
    do: {"review", %{ladder | "reviews" => 0}, []}

  defp authored(ladder, "check_failed", tasks, subject), do: fix_or_climb(ladder, tasks, subject)

  defp reviewed(ladder, result, tasks, subject) do
    reviewed = reviewed_result(tasks)

    cond do
      result["outcome"] != "completed" ->
        held(ladder, "review ended #{result["outcome"]}")

      result["conversation"] != nil and result["conversation"] in authors(tasks) ->
        again(ladder, "the reviewer's conversation is an author's", tasks, subject)

      reviewed == nil or result["based_on"] == nil or
          result["based_on"] != reviewed["fingerprint"] ->
        again(ladder, "the review is not of the latest result", tasks, subject)

      result["verdict"] == "approved" ->
        {"ready", %{ladder | "reviews" => 0}, []}

      result["verdict"] == "changes_required" ->
        fix_or_climb(%{ladder | "reviews" => 0}, tasks, subject)

      true ->
        again(ladder, :unparsed, tasks, subject)
    end
  end

  # One new review; after a second invalid one in a row, the ladder (an unparseable
  # verdict) or held (any other invalid review: climbing changes no reviewer).
  defp again(%{"reviews" => n} = ladder, why, tasks, subject) do
    cond do
      n < 1 -> {"review", %{ladder | "reviews" => n + 1}, []}
      why == :unparsed -> climb(%{ladder | "reviews" => 0}, tasks, subject)
      true -> held(ladder, why)
    end
  end

  defp fix_or_climb(ladder, tasks, subject) do
    if ladder["fixes"] < budget(ladder),
      do: {"fix", %{ladder | "fixes" => ladder["fixes"] + 1}, []},
      else: climb(ladder, tasks, subject)
  end

  # A flaky test gets one fix that stabilises it (§4.1 a).
  defp budget(%{"flaky" => true}), do: 1
  defp budget(_ladder), do: @fixes

  defp climb(ladder, _tasks, _subject) do
    rung = ladder["rung"]

    fresh = fn r ->
      ladder |> Map.merge(%{"rung" => r, "fixes" => 0, "reviews" => 0}) |> Map.delete("flaky")
    end

    case rung do
      nil -> {"diagnose", fresh.("a"), []}
      "a" -> {"fresh", fresh.("b"), []}
      "b" -> {"stronger", fresh.("c"), []}
      "c" -> {"diagnose", fresh.("d"), []}
      "d" -> held(ladder, "the final diagnosis phrased no decision")
      "e" -> held(ladder, "the ladder has no rung left")
    end
  end

  defp diagnosed(ladder, result, subject) do
    diagnosis = result["diagnosis"] || %{"cause" => "other", "evidence" => "no diagnosis"}
    ladder = Map.put(ladder, "diagnosis", diagnosis)
    decision = diagnosis["decision"]

    case {ladder["rung"], diagnosis["cause"], diagnosis["needs"]} do
      {"d", _, _} when is_map(decision) ->
        decide(ladder, decision, result, subject)

      {"d", _, _} ->
        held(ladder, "the final diagnosis phrased no decision")

      {_, "unclear_spec", _} ->
        {"diagnose", %{ladder | "rung" => "d", "fixes" => 0, "reviews" => 0}, []}

      {_, "flaky_test", _} ->
        {"fix", Map.merge(ladder, %{"fixes" => 1, "reviews" => 0, "flaky" => true}), []}

      {_, "environment", "native_check"} ->
        held(ladder, "the check needs a privileged native check (native_check, F5)")

      {_, "environment", "access"} when is_map(decision) ->
        decide(ladder, decision, result, subject)

      {_, "environment", "access"} ->
        held(ladder, "the environment needs access, and the diagnosis phrased no decision")

      _ ->
        {"fresh", %{ladder | "rung" => "b", "fixes" => 0, "reviews" => 0}, []}
    end
  end

  # Rung (e): the decision is recorded as proposed; work goes on on its default only
  # when that is safe and touches no authority (§4.1 e, lesson 12).
  defp decide(ladder, decision, result, subject) do
    ladder =
      Map.merge(ladder, %{"rung" => "e", "fixes" => 0, "reviews" => 0, "decision" => decision})

    write = decision_write(decision, result, subject)

    if decision["safe_to_continue"] == true and not decision["authority"],
      do: {"fresh", ladder, [write]},
      else: {"decide", ladder, [write]}
  end

  defp held(ladder, why), do: {"held", Map.put(ladder, "held", to_string(why)), []}

  @doc "The run's latest author or fix result that has a work to start from, or nil."
  def latest(tasks) do
    tasks
    |> Enum.filter(
      &(&1["task_kind"] in ["author", "fix"] and is_binary(&1["work_id"]) and
          &1["kind"] == "completed")
    )
    |> List.last()
  end

  # The result the review reviewed: the latest at the time it was asked, which is the
  # latest author or fix result (a review is never asked while another one runs).
  defp reviewed_result(tasks), do: latest(tasks)

  @doc "The conversations of the run's author and fix attempts (the package's authors, lesson 8)."
  def authors(tasks),
    do:
      for(
        t <- tasks,
        t["task_kind"] in ["author", "fix"],
        is_binary(t["conversation"]),
        do: t["conversation"]
      )

  @doc "The original base: what the run's first author task started from, or nil."
  def original_base(tasks) do
    Enum.find_value(tasks, fn t -> if t["task_kind"] == "author", do: t["base"] end)
  end

  # -- Answers -------------------------------------------------------------------------

  @doc """
  A review's verdict from its answer, which ends with a JSON block `{"verdict":
  "approved" | "changes_required", "findings": [...]}` (§4): `{:ok, verdict, findings}`,
  at most 20 findings of at most 300 characters each; `:error` when it cannot be parsed.
  `changes_required` without findings cannot be acted on, so it is not parsed either.
  """
  def verdict(answer) do
    with {:ok, %{"verdict" => verdict} = block} <- last_json(answer),
         true <- verdict in ["approved", "changes_required"],
         {:ok, findings} <- findings(block["findings"]),
         true <- verdict == "approved" or findings != [] do
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
  evidence, advice, needs?, decision?}` (§4.1 a): the map, or nil when it cannot be
  parsed. A `decision` is `{question, rationale, options: [{id, text, details, rule,
  consequences}], safe_to_continue, authority}`, the recommended option first; one that
  is not complete is left out.
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

  defp decision(%{"question" => q, "options" => [_ | _] = options} = d) when is_binary(q) do
    options =
      for o <- options,
          is_map(o),
          Enum.all?(~w(id text details rule consequences), &text?(o[&1])),
          o["id"] =~ ~r/^[a-z][a-z0-9_-]{0,63}$/ and o["id"] != "hold",
          do: Map.take(o, ~w(id text details rule consequences))

    touches = for t <- List.wrap(d["touches"]), t in @authority, do: t

    if text?(q) and options != [] and length(options) == length(Enum.uniq_by(options, & &1["id"])) do
      %{
        "question" => clip(q),
        "rationale" => clip(d["rationale"]) || "Recommended by the diagnosis.",
        "options" => options,
        "safe_to_continue" => d["safe_to_continue"] == true,
        "authority" => d["authority"] == true or touches != []
      }
    end
  end

  defp decision(_), do: nil

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

  defp clip(text) when is_binary(text), do: String.slice(text, 0, 2000)
  defp clip(_), do: nil

  defp text?(v), do: is_binary(v) and String.trim(v) != ""

  # -- Instructions --------------------------------------------------------------------

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
  check it. When a person must choose, add "decision": {"question": "…", "rationale": \
  "…", "options": [{"id": "…", "text": "…", "details": "…", "rule": "…", \
  "consequences": "…"}], "safe_to_continue": true | false, "touches": []}, the \
  recommended option first; safe_to_continue says work may go on on it before the person \
  answers, and touches names any of credentials, permissions, production or spending.\
  """

  @final_format """
  ## The scope choice

  The fixes, a fresh author and a stronger profile did not resolve it. Phrase the choice \
  a person must make about this package's scope as the decision of your JSON block, \
  with the recommended option first.\
  """

  @doc """
  The sections the next task of the loop adds to its instructions (§4, §4.1): for a
  review or diagnosis its answer format; for a fix what to fix (the review's findings,
  or the check's output); for a fresh author what failed before; and from rung (a) on,
  the diagnosis, and at (e) the default to continue on.
  """
  def sections(kind, ladder, tasks) do
    diagnosis = ladder["diagnosis"]

    [
      kind == "fix" and fix_section(ladder, tasks),
      kind in ["author", "fix", "diagnose"] and diagnosis != nil and diagnosis_section(diagnosis),
      kind == "author" and ladder["rung"] != nil and history_section("What failed before", tasks),
      kind == "author" and ladder["rung"] == "e" and default_section(ladder["decision"]),
      kind == "diagnose" and history_section("What happened", tasks),
      kind == "diagnose" and @diagnose_format,
      kind == "diagnose" and ladder["rung"] == "d" and @final_format,
      kind == "review" and @review_format
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&("\n\n" <> &1))
  end

  defp fix_section(ladder, tasks) do
    last = List.last(tasks) || %{}

    body =
      cond do
        last["task_kind"] == "review" ->
          "The review found:\n\n" <> Enum.map_join(last["findings"] || [], "\n", &("- " <> &1))

        true ->
          check_text(last["check"])
      end

    flaky =
      if ladder["flaky"], do: "\n\nThe diagnosis found a flaky test: stabilise it.", else: ""

    "## What to fix\n\n" <> body <> flaky
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

  defp default_section(%{"options" => [default | _]} = d),
    do:
      "## Decision\n\n#{d["question"]} A person decides later; continue on the recommended " <>
        "option: #{default["text"]}. #{default["rule"]}"

  defp default_section(_), do: nil

  defp history_section(heading, tasks) do
    lines =
      for t <- tasks do
        "- #{t["key"]} (#{t["task_kind"]}): #{t["outcome"]}" <> history_detail(t)
      end

    "## #{heading}\n\n" <> Enum.join(lines, "\n")
  end

  defp history_detail(%{"task_kind" => "review", "findings" => [_ | _] = f}),
    do: ", findings: " <> Enum.join(f, "; ")

  defp history_detail(%{"outcome" => "check_failed", "check" => check}),
    do: ", check: " <> String.slice(check_text(check), 0, 1200)

  defp history_detail(%{"reason" => reason}) when is_binary(reason), do: ", " <> reason
  defp history_detail(_), do: ""

  # -- The decision (rung e) ------------------------------------------------------------

  @doc """
  The proposed `decision` a diagnosis phrased, as Flow records it (§4.1 e): its options
  as the decision kind takes them (`RelaDSL.DecisionOptions`: each `adopt`, the
  recommended first, and a decline, `hold`, last), keyed by the task that phrased it so
  a replay writes it once.
  """
  def decision_write(decision, result, subject_key) do
    [default | _] = options = decision["options"]

    offered =
      Enum.map(options, &Map.put(&1, "effect", "adopt")) ++
        [
          %{
            "id" => "hold",
            "text" => "Hold the package",
            "details" => "Adopt none of these; the package stays held.",
            "effect" => "decline",
            "rule" => "",
            "consequences" => ""
          }
        ]

    definition = %{
      "question" => decision["question"],
      "options" => offered,
      "recommended" => default["id"],
      "rationale" => decision["rationale"]
    }

    key = "D-" <> result["key"]

    %{
      "id" => digest([key, "decision"]),
      "kind" => "decision",
      "content" => %{
        "op" => "create",
        "key" => key,
        "values" => %{
          "title" => String.slice(decision["question"], 0, 120),
          "decision" => default["rule"],
          "consequences" => default["consequences"],
          "options" => JSON.encode!(definition),
          "context" =>
            "Raised by Flow's strategy ladder for #{subject_key} (task #{result["key"]})" <>
              if(decision["safe_to_continue"] and not decision["authority"],
                do: "; work continues on the recommended option until a person decides.",
                else: "; the work waits for this decision."
              ),
          "status" => "proposed"
        },
        "by" => "flow"
      }
    }
  end

  defp digest(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)
end

defmodule AtlasFlow.Activities.Task do
  @moduledoc """
  Tasks: one unit of work Flow defines for the machinery a subject is assigned to, which
  a Runtime takes from Flow's work source (plan m3 §3.5, §4 A4; decision 2026-11-17 §5.3).
  Flow is the source: the Runtime polls Flow (`AtlasFlow.WorkSource`); Flow never calls a
  Runtime.

  A state with a `task` (`RelaDSL.Schema`) runs it, as `AtlasFlow.Runs.Store` drains the
  run:

  1. **Only for machinery (E1).** While the subject's owner (through the state's owner
     relation, on the projection's component when it names one) is not a fact of the
     spec's `machinery` kind, nothing is done: no task.
  2. **Intent first (obligation 2).** The task's key, `TK-<subject>-<n>`, and its intent
     (version 2, `AtlasFlow.WorkSource.Translate.intent/7`) are stored in the run
     (`pending.task`) before anything is sent, and the task fact (`records`: its kind and
     relation to the subject) is created after that. The key names no machine; it is the
     work's `work_key`.
  3. **Base.** The intent carries its base: the spec's `input` names a Code repository and
     the reference its base is resolved from (never a URL, never sent to a Runtime). The
     base comes from `AtlasFlow.Bases.cached/3` only, an ETS read: the Engine never waits
     on Code. On `:missing` Bases is asked (`request/4`), and its notify,
     `{:reconcile, kind, key}`, reconciles the subject once the base is there; on
     `:unavailable` (Code failed, or Bases is not running) nothing is asked. Either way no
     intent is made this round, and the run is unchanged; the Engine's round is the
     fallback. A held intent's base that Bases does not hold for the snapshot id the
     intent pins (`base_snapshot`; after a Flow restart its table is empty) is restored
     from that snapshot, never from its reference, so its blobs are served as they were.
  4. **Offered by Dispatch.** Once the stored run holds the intent and the task fact
     exists, the task is cast to `AtlasFlow.Dispatch` (`{:ready, key}`), which offers it
     to a Runtime of the subject's human supervisor. The cast is sent again while the
     task has no lease, or its last one was lost or ended without a result.
  5. **Result.** The run's result comes from the task fact, which `AtlasFlow.Delivery`
     writes from the Runtime's reports (`Translate.outcome/2`): once the lease is done and
     its result complete, it is put in the run (`pending.tasks`) and its branch is taken
     on the result field (`task_result`): `completed` (completed, and its check, if any,
     exited 0), `check_failed` (completed otherwise), `stuck` (refused, too large,
     invalid, or any other end; until F5 none is retried), or `abandoned`. The Engine then
     writes the task fact's `state` and nothing else: it never writes `input` again after
     the create (Dispatch writes the lease's input, fenced).

  An assignment moved away from the machinery ends the task `abandoned` and unpins its
  result (`AtlasFlow.Results.unpin/3`, a cast): a late report is recorded on the task and
  ignored by the run, because the run left the state and no longer holds its key.

  **The review → fix loop (F2; plan F2/F3 rev 3 §3.1, §3.3).** A task with `ladder: true`
  is a step of the loop. Its end does not take the result's branch: `AtlasFlow.Ladder`
  is asked what follows (`next/5`, with the subject's tasks as the run and the task facts
  know them), and the run takes the branch of that step (`author`, `review`, `fix`,
  `diagnose`, `fresh`, `stronger`, `ready`, `held`, `escalate`). The ladder it returns is
  kept in the run (`pending.ladder`, across entries), with the next task's step as
  `next`. The state that step leads to makes its intent from it, through
  `Translate.intent/7`: the **original** base (the first author's, pinned by its snapshot,
  never resolved again), the change set of the task it reviews, fixes or diagnoses (never a
  review's), and the ladder's sections after the instructions. A review's `based_on` is
  in its create; when it ends its `reviewed_revision` is the `published_revision` of the
  task whose `result_fingerprints` it reviewed, or nothing while that one is unpublished.
  Rung (e) writes nothing but the run: no `decision` fact. While the ladder waits
  (`escalate`, `held`), the state an answer leads to asks the ladder with the subject's
  `answer`, once the subject is assigned to a machinery again (E1). The profiles the
  ladder may climb to are `config :atlas_flow, :ladder_profiles` (none: rung (c) is
  skipped), its limits `:ladder_limits`.
  """

  require Logger

  alias AtlasBus.Digest
  alias AtlasFlow.{Bases, Dispatch, Ladder, Results, Talk}
  alias AtlasFlow.WorkSource.Translate

  @results ~w(completed check_failed stuck abandoned)
  @ladder_results ~w(author review fix diagnose fresh stronger ready held escalate)
  @kinds ~w(plan author review fix diagnose)
  @roles ~w(architect developer investigator)
  @profiles ~w(deep_coding independent_review deep_coding_max)
  @costs ~w(low standard high)
  # The kinds that start from the loop's latest result, and how they read it.
  @result_access %{"review" => "read", "diagnose" => "read", "fix" => "write"}
  # A ladder step's kind (`fresh` and `stronger` are authors).
  @step_kinds %{"fresh" => "author", "stronger" => "author"}

  @doc "The results a task's end gives: the four, or for a ladder task the ladder's steps."
  def results, do: @results
  def results(%{"ladder" => true}), do: @ladder_results
  def results(_spec), do: @results

  @doc "Whether this runner can run the task `spec` (as the compiled subflow gives it)."
  def valid?(spec) do
    is_map(spec) and spec["kind"] in @kinds and spec["role"] in @roles and
      spec["profile"] in @profiles and spec["cost_class"] in @costs and text?(spec["field"]) and
      spec["ladder"] in [nil, true] and input?(spec["kind"], spec["ladder"], spec["input"]) and
      check?(spec["check"]) and checked?(spec) and text?(spec["instructions"]) and
      texts?(spec["fields"] || []) and
      records?(spec["records"]) and text?(spec["machinery"])
  end

  # A Code repository and the reference its base is resolved from, nothing else: never a
  # path (D44), never a URL (a scheme, or `user@host:path`). Or, for a ladder task that
  # reviews, fixes or diagnoses, the loop's latest result, read or written as its kind is.
  defp input?(_kind, _ladder, %{"repository" => r, "base" => b} = input),
    do: map_size(input) == 2 and text?(r) and text?(b) and not url?(r) and not url?(b)

  defp input?(kind, true, %{"result" => "latest", "access" => access} = input),
    do:
      map_size(input) == 2 and Map.has_key?(@result_access, kind) and
        @result_access[kind] == access

  defp input?(_kind, _ladder, _input), do: false

  # Lesson 7 (Flow plan §11 row 7; Main's D4): bin/check is the mandatory after-check, so
  # a ladder author or fix (the fix, a fresh or stronger author) always has one, and its
  # intent always carries `after_check`.
  defp checked?(%{"ladder" => true, "kind" => kind} = spec) when kind in ["author", "fix"],
    do: spec["check"] != nil

  defp checked?(_spec), do: true

  defp check?(nil), do: true
  defp check?(command), do: is_list(command) and command != [] and texts?(command)

  defp records?(%{"kind" => k, "relation" => r} = records),
    do: map_size(records) == 2 and text?(k) and text?(r)

  defp records?(_), do: false

  defp url?(v), do: v =~ ~r/^[A-Za-z][A-Za-z0-9+.-]*:/ or v =~ ~r/^[^\/]*@[^\/]*:/

  defp texts?(l), do: is_list(l) and Enum.all?(l, &text?/1)
  defp text?(v), do: is_binary(v) and String.trim(v) != ""

  @doc "The key of the `n`th task on `subject_key`: `TK-<subject>-<n>`."
  def key(subject_key, n), do: "TK-#{subject_key}-#{n}"

  @doc """
  Who the subject is assigned to, as a task sees it: `{:machinery, key}` when its owner
  (through `owner`'s relation, on the projection's `on` component when it names one) is a
  fact of the spec's machinery kind; `:other` (nobody, or someone else); `:unavailable`
  when Facts did not say.
  """
  def assignee(spec, owner, projection, subject) do
    relation = (owner || %{})["relation"] || (projection || %{})["owner_relation"]

    with true <- is_binary(relation) || :other,
         {:ok, %{} = holder} <- holder(owner, projection, subject),
         [key] when is_binary(key) <- List.wrap(get_in(holder, ["links", relation])) do
      case Talk.transition_read(spec["machinery"], %{"key" => key, "plain" => true}) do
        %{"fact" => %{}} -> {:machinery, key}
        %{"fact" => nil} -> :other
        _ -> :unavailable
      end
    else
      :unavailable -> :unavailable
      _ -> :other
    end
  end

  defp holder(owner, %{"on" => on}, subject) when is_binary(on) do
    case {(owner || %{})["via"], List.wrap(get_in(subject, ["links", on]))} do
      {kind, [key]} when is_binary(kind) and is_binary(key) ->
        case Talk.transition_read(kind, %{"key" => key, "plain" => true}) do
          %{"fact" => fact} -> {:ok, fact}
          _ -> :unavailable
        end

      _ ->
        {:ok, nil}
    end
  end

  defp holder(_owner, _projection, subject), do: {:ok, subject}

  @doc """
  The number of the next task on the run's subject: one past the highest of its task
  records and the tasks its run holds, `{:ok, n}`; `:unavailable` when Facts did not say.
  """
  def number(spec, run) do
    subject = run["subject_key"]
    records = spec["records"]

    case Talk.transition_read(records["kind"], %{
           "linked" => %{records["relation"] => subject},
           "plain" => true
         }) do
      %{"facts" => facts} when is_list(facts) ->
        held = for t <- run["pending"]["tasks"] || [], do: t["key"]
        keys = Enum.map(facts, & &1["key"]) ++ held
        prefix = "TK-#{subject}-"

        n =
          keys
          |> Enum.flat_map(fn
            ^prefix <> n -> with {i, ""} <- Integer.parse(n), do: [i], else: (_ -> [])
            _ -> []
          end)
          |> Enum.max(fn -> 0 end)

        {:ok, n + 1}

      _ ->
        :unavailable
    end
  end

  @doc """
  The work of task `key` on `subject` (string keys): its title and instructions, profile,
  cost class and after-check. Where it starts is the intent's base, never a workspace.
  """
  def request(spec, subject, _key) do
    values = subject["values"] || %{}

    sections =
      for field <- spec["fields"] || [],
          text = values[field],
          is_binary(text) and String.trim(text) != "",
          do: "\n\n## #{field}\n\n#{text}"

    %{
      "title" => "#{spec["kind"]} #{subject["key"]}",
      "instructions" => Enum.join([spec["instructions"] | sections]),
      "profile" => spec["profile"],
      "cost_class" => spec["cost_class"]
    }
    |> then(
      &if(spec["check"], do: Map.put(&1, "after_check", %{"command" => spec["check"]}), else: &1)
    )
  end

  # The push path's capacity rule, kept only for `AtlasFlow.FakeRuntime` (test support of
  # the push client), which A5 removes together with it. Nothing in the lease path calls it.
  @doc false
  def room?(capacity, profile) when is_map(capacity) do
    free = fn part -> get_in(capacity, [part, "free"]) end

    capacity["accepting"] != false and
      get_in(capacity, ["profiles", profile, "available"]) != false and
      Enum.any?(["slots", "buffer"], &(is_integer(free.(&1)) and free.(&1) > 0))
  end

  def room?(_capacity, _profile), do: false

  @doc """
  The task's next step on `run`, in a state whose mechanism is `{:task, spec}`:

  - `:none`: nothing changes (no machinery, no base yet, waiting for its result);
  - `{:pending, intent, writes, ladder}`: the task as the run is to hold it, the record
    writes to send after the run is stored, and the run's ladder (nil: unchanged);
  - `{:result, outcome, result, writes, ladder}`: the task ended `outcome` (for a ladder
    task the ladder's step); `result` goes in the run, and `ladder` (nil for a task that
    is no ladder's) is kept as `pending.ladder`.

  `ctx`: `assignee` (`assignee/4`), `number` (a function giving `number/2`) and `now`;
  optionally `profiles` and `limits` for the ladder (else the application's).
  """
  def step(run, spec, subject, ctx) do
    intent = run["pending"]["task"]

    cond do
      ctx.assignee == :unavailable ->
        :none

      intent == nil ->
        intend(run, spec, subject, ctx)

      ctx.assignee != {:machinery, intent["machinery"]} ->
        abandon(run, intent, spec, ctx)

      not Translate.intent?(intent) ->
        # A push-path intent (version 1) is never offered: it ends stuck.
        ended(run, intent, spec, "stuck", %{"reason" => "unsupported intent"}, nil, ctx)

      true ->
        follow(run, intent, spec, ctx)
    end
  end

  defp intend(run, spec, subject, %{assignee: {:machinery, name}} = ctx) do
    with {:ok, work} <- work(run, spec, subject, ctx),
         {:ok, n} <- ctx.number.() do
      key = key(subject["key"], n)

      intent =
        spec
        |> Translate.intent(subject, key, work.base, work.change_set, name, ctx.now)
        |> update_in(["work", "instructions"], &(&1 <> Enum.join(work.sections)))
        |> then(&if(work.loop, do: Map.put(&1, "loop", work.loop), else: &1))

      record =
        write(key, ["intent"], spec["records"]["kind"], %{
          "op" => "create",
          "key" => key,
          "values" =>
            compact(%{
              "kind" => spec["kind"],
              "role" => spec["role"],
              "profile" => spec["profile"],
              "input" => JSON.encode!(spec["input"]),
              "client_key" => key,
              "state" => "waiting",
              "based_on" => work.loop && work.loop["based_on"]
            }),
          "links" => %{spec["records"]["relation"] => [subject["key"]]},
          "by" => "flow"
        })

      {:pending, intent, [record], work.ladder}
    else
      _no_base_or_unavailable -> :none
    end
  end

  defp intend(_run, _spec, _subject, _ctx), do: :none

  # Where the next task starts: a task that is no ladder's (or the loop's first author)
  # from the spec's base, as Bases holds it; a ladder step from what the ladder says.
  defp work(run, %{"ladder" => true} = spec, subject, ctx) do
    ladder = run["pending"]["ladder"]

    cond do
      match?(%{"next" => %{}}, ladder) ->
        from_step(ladder["next"], Map.delete(ladder, "next"), spec, run)

      match?(%{"awaiting" => %{}}, ladder) ->
        answered(ladder, spec, run, subject, ctx)

      spec["input"]["repository"] == nil ->
        # A review, fix or diagnose with no step to take: nothing to start from.
        :none

      true ->
        with {:ok, work} <- work(run, Map.delete(spec, "ladder"), subject, ctx),
             do: {:ok, %{work | ladder: Map.put(ladder || %{}, "repository", repository(spec))}}
    end
  end

  defp work(run, spec, _subject, _ctx) do
    %{"repository" => repository, "base" => reference} = spec["input"]

    with {:ok, base} <- base(run, repository, reference),
         do: {:ok, %{base: base, change_set: nil, sections: [], loop: nil, ladder: nil}}
  end

  # The supervisor answered while the ladder waits: the step the answer leads to, when it
  # is this state's; an answer the question does not offer, or that leads elsewhere,
  # starts nothing (the ladder asks again).
  defp answered(ladder, spec, run, subject, ctx) do
    with {:ok, views} <- views(spec, run, nil, nil),
         {{:task, step}, ladder} <-
           Ladder.next(
             ladder,
             {:answer, (subject["values"] || %{})["answer"]},
             views,
             profiles(ctx),
             limits(ctx)
           ) do
      from_step(step, ladder, spec, run, views)
    else
      _ -> :none
    end
  end

  defp from_step(step, ladder, spec, run, views \\ nil) do
    base = step["base"]

    with true <- step_kind(step) == spec["kind"],
         %{"base_id" => _, "manifest" => _, "base_snapshot" => _} <- base,
         {:ok, views} <- if(views, do: {:ok, views}, else: views(spec, run, nil, nil)) do
      {:ok,
       %{
         base: %{
           base_id: base["base_id"],
           manifest: base["manifest"],
           snapshot_id: base["base_snapshot"]
         },
         change_set: change_set(step["change_set"]),
         sections: Ladder.sections(spec["kind"], ladder, views),
         loop: compact(Map.take(step, ~w(step rung based_on reviewed))),
         ladder: ladder
       }}
    else
      _ ->
        Logger.warning("flow ladder: step #{inspect(step["step"])} does not run here")
        :none
    end
  end

  defp step_kind(step), do: @step_kinds[step["step"]] || step["kind"]

  defp change_set(%{"manifest" => m, "fingerprints" => f}) when is_binary(m) and is_binary(f),
    do: %{"manifest" => m, "fingerprints" => f}

  defp change_set(_), do: nil

  defp repository(spec), do: spec["input"]["repository"]

  defp profiles(ctx),
    do:
      Map.get_lazy(ctx, :profiles, fn ->
        Application.get_env(:atlas_flow, :ladder_profiles, [])
      end)

  defp limits(ctx),
    do:
      Map.get_lazy(ctx, :limits, fn -> Application.get_env(:atlas_flow, :ladder_limits, %{}) end)

  # The base of the spec's reference, from Bases' table only. A missing one is asked for:
  # Bases resolves it in its own task and reconciles the run's subject once it has it.
  defp base(run, repository, reference) do
    case Bases.cached(repository, reference) do
      {:ok, base} ->
        {:ok, base}

      :missing ->
        Bases.request(repository, reference, notify(run))
        :missing

      :unavailable ->
        :unavailable
    end
  end

  defp notify(run), do: {self(), {:reconcile, run["subject_kind"], run["subject_key"]}}

  # A held intent: its base kept servable, its task offered, its result read from the
  # task fact Delivery writes.
  defp follow(run, intent, spec, ctx) do
    servable(intent, repository(spec) || (run["pending"]["ladder"] || %{})["repository"])
    key = intent["key"]

    case Talk.transition_read(spec["records"]["kind"], %{"key" => key, "plain" => true}) do
      %{"fact" => %{} = fact} ->
        case Translate.outcome(fact, spec["check"] != nil) do
          {:result, outcome, detail} ->
            ended(run, intent, spec, outcome, detail, fact, ctx)

          :retry ->
            Dispatch.ready(key)
            :none

          :waiting ->
            if offerable?(fact), do: Dispatch.ready(key)
            :none
        end

      _absent_or_unavailable ->
        :none
    end
  end

  # No lease yet, or the last one was lost: Dispatch is to offer it (again).
  defp offerable?(fact) do
    v = fact["values"] || %{}
    v["lease_state"] in [nil, "", "lost"]
  end

  # After a Flow restart Bases' table is empty: the intent's base is restored from the
  # Code snapshot it was made from (`base_snapshot`, immutable by id), never by resolving
  # its reference again, so Delivery serves the same base also once the branch moved. It
  # asks whether Bases holds the manifest *for that snapshot*: whatever the reference's
  # cached base is now, and even when another snapshot (the same tree at a new revision)
  # gave the same manifest. A cast; while a restore fails, each reconcile asks again. A
  # ladder step's base is the original base, so it is restored the same way.
  defp servable(intent, repository) do
    manifest = get_in(intent, ["work", "input", "base", "manifest"])
    snapshot = intent["base_snapshot"]

    if is_binary(repository) and is_binary(manifest) and is_binary(snapshot) and
         not Bases.held?(manifest, snapshot),
       do: Bases.restore(repository, snapshot, manifest)

    :ok
  end

  defp abandon(run, intent, spec, ctx) do
    Results.unpin(intent["key"], ctx.now)
    ended(run, intent, spec, "abandoned", %{"reason" => "assignment moved away"}, nil, ctx)
  end

  # The task ended: its result for the run, and the task fact's `state`, the only field
  # the Engine writes after the create (a review's verdict and reviewed revision too).
  defp ended(run, intent, spec, outcome, detail, fact, ctx) do
    attempt = get_in(fact || %{}, ["values", "attempt"])

    result =
      compact(%{
        "key" => intent["key"],
        "machinery" => intent["machinery"],
        "attempt" => attempt,
        "outcome" => outcome,
        "kind" => detail["kind"],
        "reason" => detail["reason"],
        "check" => detail["check"] && compact(detail["check"])
      })

    if spec["ladder"] == true,
      do: ended_step(run, intent, spec, outcome, result, fact, ctx),
      else:
        {:result, outcome, result, [change(intent, spec, ["result"], %{"state" => outcome})], nil}
  end

  # A ladder task ended: the ladder says what follows. Its result keeps what the ladder
  # reads of it later (its kind, profile, base, what it reviewed and the verdict or
  # diagnosis it gave). `:none` (a superseded verdict while a review of the latest result
  # runs) leaves the task held: nothing moves.
  defp ended_step(run, intent, spec, outcome, result, fact, ctx) do
    loop = intent["loop"] || %{}
    answer = get_in(fact || %{}, ["values", "answer"])

    result =
      Map.merge(
        result,
        compact(%{
          "task_kind" => spec["kind"],
          "profile" => intent["work"]["profile"],
          "base" => intent_base(intent),
          "step" => loop["step"],
          "based_on" => loop["based_on"],
          "reviewed" => loop["reviewed"]
        })
      )
      |> Map.merge(answered_result(spec["kind"], answer))

    with {:ok, facts} <- facts(spec, run),
         {:ok, views} <- views(spec, run, result, facts),
         {step, ladder} when step != :none <-
           Ladder.next(
             run["pending"]["ladder"],
             {:ended, intent["key"]},
             views,
             profiles(ctx),
             limits(ctx)
           ) do
      {name, ladder} = taken(step, ladder)
      values = %{"state" => outcome} |> Map.merge(reviewed(spec, result, facts))
      {:result, name, result, [change(intent, spec, ["result"], values)], ladder}
    else
      _ -> :none
    end
  end

  defp taken({:task, step}, ladder), do: {step["step"], Map.put(ladder, "next", step)}
  defp taken({tag, _}, ladder), do: {Atom.to_string(tag), Map.delete(ladder, "next")}

  defp intent_base(intent) do
    base = get_in(intent, ["work", "input", "base"]) || %{}

    compact(%{
      "base_id" => base["base_id"],
      "manifest" => base["manifest"],
      "base_snapshot" => intent["base_snapshot"]
    })
  end

  defp answered_result("review", answer) do
    case Ladder.verdict(answer) do
      {:ok, verdict, findings} -> %{"verdict" => verdict, "findings" => findings}
      :error -> %{}
    end
  end

  defp answered_result("diagnose", answer),
    do: compact(%{"diagnosis" => Ladder.diagnosis(answer)})

  defp answered_result(_kind, _answer), do: %{}

  # A review's verdict, and the revision it reviewed: the `published_revision` of the task
  # whose result it was given (`based_on`), none while that one is unpublished.
  defp reviewed(%{"kind" => "review"}, result, facts) do
    revision =
      Enum.find_value(facts, fn f ->
        v = f["values"] || %{}

        if v["kind"] in ["author", "fix"] and is_binary(result["based_on"]) and
             v["result_fingerprints"] == result["based_on"],
           do: v["published_revision"]
      end)

    compact(%{"verdict" => result["verdict"], "reviewed_revision" => revision})
  end

  defp reviewed(_spec, _result, _facts), do: %{}

  # The subject's task facts, by key.
  defp facts(spec, run) do
    records = spec["records"]

    case Talk.transition_read(records["kind"], %{
           "linked" => %{records["relation"] => run["subject_key"]},
           "plain" => true
         }) do
      %{"facts" => facts} when is_list(facts) -> {:ok, facts}
      _ -> :unavailable
    end
  end

  # The run's tasks as the ladder reads them (`AtlasFlow.Ladder`): each ended one's result
  # in the run, `current` (the one ending now) last, with what Delivery wrote on its fact.
  defp views(spec, run, current, facts) do
    with {:ok, facts} <- if(facts, do: {:ok, facts}, else: facts(spec, run)) do
      by_key = Map.new(facts, &{&1["key"], &1["values"] || %{}})
      results = (run["pending"]["tasks"] || []) ++ List.wrap(current)

      {:ok,
       for r <- results, r["task_kind"] != nil do
         v = by_key[r["key"]] || %{}

         compact(%{
           "key" => r["key"],
           "kind" => r["task_kind"],
           "outcome" => r["outcome"],
           "reason" => r["reason"],
           "profile" => r["profile"],
           "base" => r["base"],
           "check" => unfinished(r["check"]),
           "based_on" => r["based_on"],
           "reviewed" => r["reviewed"],
           "answer" => v["answer"],
           "result_state" => v["result_state"],
           "result_manifest" => v["result_manifest"],
           "result_fingerprints" => v["result_fingerprints"]
         })
       end}
    end
  end

  # A check that gave no exit status did not finish (#297 case 4): the ladder reads it as
  # one (`interrupted`), so the fix is told to run the check, not shown a failure.
  defp unfinished(%{"ending" => "no_exit_status"} = check),
    do: %{check | "ending" => "interrupted"}

  defp unfinished(check), do: check

  defp change(intent, spec, tag, values),
    do:
      write(intent["key"], tag, spec["records"]["kind"], %{
        "op" => "change",
        "key" => intent["key"],
        "values" => compact(values),
        "by" => "flow"
      })

  defp write(key, tag, kind, content),
    do: %{
      "id" => Digest.of_term([key | tag]) |> String.replace_prefix("sha256:", ""),
      "kind" => kind,
      "content" => content
    }

  defp compact(map), do: Map.reject(map, fn {_, v} -> v == nil end)
end

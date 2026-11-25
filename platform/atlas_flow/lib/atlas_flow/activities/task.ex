defmodule AtlasFlow.Activities.Task do
  @moduledoc """
  Tasks: one unit of work Flow defines for the machinery a subject is assigned to, which
  a Runtime takes from Flow's work source (plan m3 §3.5, §4 A4; decision 2026-11-17 §5.3).
  Flow is the source: the Runtime polls Flow (`AtlasFlow.WorkSource`); Flow never calls a
  Runtime.

  A state with a `task` (`RelaDSL.Schema`) runs it, as `AtlasFlow.Runs.Store` drains the
  run:

  1. **For a supervisor, or for machinery (E1).** Once its flow is picked up (it has
     a human supervisor; IS-Atlas-25, `AtlasFlow.Runs.Store` asks), the task is made at
     once, naming no machinery: Dispatch offers it to that supervisor's Runtimes. Without
     one, while the subject's owner (through the state's owner relation, on the
     projection's component when it names one) is not a fact of the spec's `machinery`
     kind, nothing is done: no task.
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

  **Why it is to be done.** A spec's `parents` names fields of the subject's parents (the
  relations the model marks `parent`, `ctx.parents`), nearest first: each parent's are
  added after the subject's own `fields`, under `## <kind> <key>: <field>`. Facts not
  answering makes no intent this round.

  **A subject's review and fix.** A review or fix outside any ladder names `input:
  %{"repository", "result" => "latest"}`: its base is the run's latest result
  (`Translate.latest_result/1`), the commit its author's Runtime pushed to
  `refs/atlas/results/<key>`, which Bases resolves through Code like a branch. It works
  writable (`Translate.permissions/1`) in a Git checkout of that result. A review's
  instructions end with the review's answer format, and its verdict and findings join its
  result in the run (its verdict also on its task fact), where a publication reads them; a
  verdict of changes required ends it `changes_required` for the run. A fix's instructions
  end with that review's findings, and its answer joins its result, for the publication.
  A fix whose spec names a field of the subject, `findings`, ends with that field's text
  instead (what failed in the result's CI, say), not the review's.

  **Why it ended without a result.** A task outside any ladder whose spec names a field
  of the subject, `failure`, has Flow write there, when it ends `stuck` or `abandoned`,
  which task it was (its kind and key), the run's state it ran in, how it ended and its
  reason, so whoever its run then goes to sees why. A later task whose state resets
  that field (`set`) leaves no stale reason behind.

  **An update of an open pull.** A fix may name `input: %{"repository",
  "base", "update" => field}`, `field` the subject's field holding the web address of a
  pull the service opened: its base is `refs/atlas/updates/<number>/<base>`, which Code
  resolves to `base` merged into that pull's head, conflicts marked in the files. Not
  ready while that field holds no pull's address.

  **A proposal (slice 7).** A spec's `creates` (`%{"kind", "file"}`) asks its agent, after
  the instructions, to write what it proposes to that file at the top of the repository: a
  JSON list of `{title, description}`, and of the texts the spec's `fields` name. When the
  task completed, Flow reads the file from
  its result commit (`refs/atlas/results/<key>`, through Bases and Code) and makes one fact of that kind per entry,
  with the spec's `values` too, and its place in the list, from 1, in the spec's `order` field,
  linked to the subject through the kind's parent relation to it and numbered after the
  facts of that kind there are (the model's `ids`), `by` Flow with the run's supervisor in
  its cause; the agent never writes into Atlas. With no such file, the task ends `stuck`.
  A spec's `writes` (`%{"field", "file"}`, slice 9) asks for one text instead: Flow puts the
  file's text in that field of the subject; with no such file, or an empty one, `stuck`.

  **Read first.** A spec with `read_first: true` adds, after the subject's fields, what the
  model says is to be read first about the subject (its standing decisions and those the
  subject is based on), as the model's `read_first/2` gives it.

  **Follow-ups.** A review's spec may name a kind, `follow_ups`: its agent is asked to split
  what it finds into blocking findings (within the subject's scope; they go to the one fix
  and decide its verdict) and follow-ups (outside it), which it adds to its JSON block as
  `follow_ups`, `[{title, description}]` (`Ladder.follow_ups/1`). When the review ends,
  whatever its verdict, Flow makes one fact of that kind per follow-up under the subject's
  nearest parent, as it makes a proposal's, with the review in its cause.

  An assignment moved away from the machinery a task was made for, while its flow has no
  supervisor, ends the task `abandoned` and unpins its
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
  Rung (e) writes no `decision` fact.

  **Red CI (F3-L).** The ladder reads what Landing recorded of the result's publication
  (`review_ci`, `published_revision`, `review_url` on its task fact), so a review that
  ends on a result whose CI is red leads to a fix, not `ready`. A fix state entered with
  no step to take (from `ready`, once CI turned red; F3-M's branch) asks the ladder with
  `{:ci_failed, key}` for the latest result, and runs the fix it gives; otherwise nothing.
  While the ladder waits
  (`escalate`, `held`), the state an answer leads to asks the ladder with the subject's
  `answer`, and runs its step once the subject is assigned to a machinery again (E1). An
  answer the ladder does not take (one the question does not offer, or whose step is not
  that state's) runs nothing: the run takes `held` or `escalate` again, with or without a
  hand-back, so the supervisor is asked again. The profiles the
  ladder may climb to are `config :atlas_flow, :ladder_profiles` (none: rung (c) is
  skipped), its limits `:ladder_limits`.

  **Asking the supervisor (F2-P; Main's D1, D2, D3).** When the ladder asks (`held`,
  `escalate`), the Engine writes two fields on the subject, by `flow`, beside the task
  fact's `state`. So a subject with ladder tasks has both fields:

    * `question`: the question, as JSON (`AtlasFlow.Ladder`'s `question` map: its
      `answers`, `options`, `recommended`, `continue`, …);
    * `retry_step`: the step that `retry` leads to (the held task's again, as the
      ladder gives it for that answer, e.g. `review`), or `none` when the question does
      not offer `retry`. The subflow branches `retry` on it to the state of that step.

  At rung (e), when the recommended option is safe to continue on and touches no
  authority (the question's `continue`, D1), the run takes the `fresh` branch and runs
  that step while the ladder still waits for the answer. So the subject stays with its
  machinery, and the supervisor is only asked. Otherwise the run takes `escalate`, and
  the state it leads to hands the subject to the supervisor. Each ask resets the
  subject's `answer` to `none` in the same write, so an answer to an earlier question is
  never taken for this one.

  An answer while that work runs (Main's ruling): the default itself is recorded and
  changes nothing; another answer the question offers cancels the running task
  (`AtlasFlow.Dispatch.cancel/3`, the graceful cancel the Runtime sees on its next poll)
  and the run follows the answer, with nothing of the cancelled task's result read. Once
  a task has ended, its result is taken as always, and an answer is a normal one.
  """

  require Logger

  alias AtlasBus.Digest
  alias AtlasFlow.{Bases, Dispatch, Ladder, Results, Talk}
  alias AtlasFlow.Runs.HandOver
  alias AtlasFlow.WorkSource.Translate

  @results ~w(completed check_failed stuck abandoned)
  @ladder_results ~w(author review fix diagnose fresh stronger ready held escalate abandon)
  @kinds ~w(plan author review fix diagnose)
  @roles ~w(architect developer investigator)
  @profiles ~w(deep_coding independent_review deep_coding_max)
  @costs ~w(low standard high)
  # The kinds that start from the loop's latest result, and how they read it.
  @result_access %{"review" => "read", "diagnose" => "read", "fix" => "write"}
  # A ladder step's kind (`fresh` and `stronger` are authors).
  @step_kinds %{"fresh" => "author", "stronger" => "author"}

  @doc """
  The results a task's end gives: the four, for a review outside any ladder also `changes_required`,
  or for a ladder task the ladder's steps.
  """
  def results, do: @results
  def results(%{"ladder" => true}), do: @ladder_results

  def results(%{"kind" => "review", "input" => %{"result" => "latest"}}),
    do: @results ++ ["changes_required"]

  def results(_spec), do: @results

  @doc "Whether this runner can run the task `spec` (as the compiled subflow gives it)."
  def valid?(spec) do
    is_map(spec) and spec["kind"] in @kinds and spec["role"] in @roles and
      spec["profile"] in @profiles and spec["cost_class"] in @costs and text?(spec["field"]) and
      spec["ladder"] in [nil, true] and input?(spec["kind"], spec["ladder"], spec["input"]) and
      check?(spec["check"]) and checked?(spec) and text?(spec["instructions"]) and
      texts?(spec["fields"] || []) and texts?(spec["parents"] || []) and
      spec["read_first"] in [nil, true] and note?(spec["note"]) and
      creates?(spec["creates"]) and writes?(spec["writes"]) and
      not (spec["creates"] != nil and spec["writes"] != nil) and
      (spec["follow_ups"] == nil or text?(spec["follow_ups"])) and
      (spec["findings"] == nil or (spec["kind"] == "fix" and text?(spec["findings"]))) and
      (spec["failure"] == nil or (spec["ladder"] == nil and text?(spec["failure"]))) and
      records?(spec["records"]) and text?(spec["machinery"])
  end

  defp creates?(nil), do: true

  defp creates?(%{"kind" => kind, "file" => file} = creates),
    do:
      Enum.all?(Map.keys(creates), &(&1 in ~w(kind file fields values order discard))) and
        text?(kind) and text?(file) and texts?(creates["fields"] || []) and
        is_map(creates["values"] || %{}) and (creates["order"] == nil or text?(creates["order"])) and
        creates["discard"] in [nil, true]

  defp creates?(_creates), do: false

  defp note?(nil), do: true

  defp note?(%{"field" => field, "heading" => heading} = note),
    do: map_size(note) == 2 and text?(field) and text?(heading)

  defp note?(_note), do: false

  defp writes?(nil), do: true

  defp writes?(%{"field" => field, "file" => file} = writes),
    do: map_size(writes) == 2 and text?(field) and text?(file)

  defp writes?(_writes), do: false

  # A Code repository and the reference its base is resolved from, nothing else: never a
  # path (D44), never a URL (a scheme, or `user@host:path`). Or, for a ladder task that
  # reviews, fixes or diagnoses, the loop's latest result, read or written as its kind is.
  # Or, for a review or fix outside any ladder (a subject's), a repository and the run's latest
  # result, which Code serves as a base of that repository. Or, for a fix, a repository, a
  # base and the subject's field holding the address of a pull to update with that base.
  defp input?(_kind, _ladder, %{"repository" => r, "base" => b} = input)
       when map_size(input) == 2,
       do: text?(r) and text?(b) and not url?(r) and not url?(b)

  defp input?("fix", nil, %{"repository" => r, "base" => b, "update" => f} = input),
    do:
      map_size(input) == 3 and text?(r) and text?(b) and text?(f) and not url?(r) and not url?(b)

  defp input?(kind, true, %{"result" => "latest", "access" => access} = input),
    do:
      map_size(input) == 2 and Map.has_key?(@result_access, kind) and
        @result_access[kind] == access

  defp input?(kind, nil, %{"repository" => r, "result" => "latest"} = input)
       when kind in ["review", "fix"],
       do: map_size(input) == 2 and text?(r) and not url?(r)

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
      case Talk.read(spec["machinery"], %{"key" => key, "plain" => true}) do
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
        case Talk.read(kind, %{"key" => key, "plain" => true}) do
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

    case Talk.read(records["kind"], %{
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
      "instructions" =>
        Enum.join([spec["instructions"] | sections]) <> note(spec["note"], values),
      "profile" => spec["profile"],
      "cost_class" => spec["cost_class"]
    }
    |> then(
      &if(spec["check"], do: Map.put(&1, "after_check", %{"command" => spec["check"]}), else: &1)
    )
  end

  # The spec's `note`: the text of the subject's field under its heading, when it has one
  # (what its supervisor said when its last proposal was not accepted, say).
  defp note(%{"field" => field, "heading" => heading}, values) do
    case values[field] do
      text when is_binary(text) -> if text?(text), do: "\n\n## #{heading}\n\n#{text}", else: ""
      _ -> ""
    end
  end

  defp note(_note, _values), do: ""

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

  `ctx`: `assignee` (`assignee/4`, or `:supervised` when its flow has a human supervisor),
  `number` (a function giving `number/2`) and `now`; optionally `profiles` and `limits`
  for the ladder (else the application's).
  """
  def step(run, spec, subject, ctx) do
    intent = run["pending"]["task"]

    cond do
      ctx.assignee == :unavailable ->
        :none

      intent == nil ->
        intend(run, spec, subject, ctx)

      not held?(ctx.assignee, intent) ->
        abandon(run, intent, spec, ctx)

      not Translate.intent?(intent) ->
        # A push-path intent (version 1) is never offered: it ends stuck.
        ended(run, intent, spec, "stuck", %{"reason" => "unsupported intent"}, nil, ctx)

      true ->
        follow(run, intent, spec, subject, ctx)
    end
  end

  # A task made for a supervised flow names no machinery: it is its supervisor's, whatever
  # the subject is assigned to, and only Dispatch moves its lease (a hand-over cancels it;
  # it waits for the next pickup). One made for a machinery (E1) is abandoned once the
  # subject leaves that machinery, unless its flow is supervised.
  defp held?(_assignee, %{"machinery" => nil}), do: true
  defp held?(:supervised, _intent), do: true
  defp held?(assignee, intent), do: assignee == {:machinery, intent["machinery"]}

  defp intend(run, spec, subject, %{assignee: assignee} = ctx)
       when assignee == :supervised or
              (is_tuple(assignee) and elem(assignee, 0) == :machinery) do
    name = if assignee == :supervised, do: nil, else: elem(assignee, 1)

    with {:ok, work} <- work(run, spec, subject, ctx) |> asked_again(run, ctx),
         {:ok, parents} <- parents(spec, run["subject_kind"], subject, ctx[:parents] || %{}),
         {:ok, n} <- ctx.number.() do
      key = key(subject["key"], n)

      intent =
        spec
        |> Translate.intent(subject, key, work.base, work.change_set, name, ctx.now)
        |> update_in(
          ["work", "instructions"],
          &(&1 <>
              parents <>
              read_first(spec, subject, ctx) <>
              Enum.join(work.sections) <> proposal_format(spec) <> follow_ups_format(spec))
        )
        |> then(&if(work.loop, do: Map.put(&1, "loop", work.loop), else: &1))
        |> Translate.root_check(repository(spec) || (work.ladder || %{})["repository"])
        |> Translate.result_ref(key, work.ladder == nil)

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
      {:result, _, _, _, _} = asked -> asked
      _no_base_or_unavailable -> :none
    end
  end

  # Not with a machinery: no task. An answer the waiting ladder does not take asks again
  # all the same (F-1): nothing runs for it, so it need not wait for a hand-back.
  defp intend(run, %{"ladder" => true} = spec, subject, ctx) do
    case run["pending"]["ladder"] do
      %{"next" => %{}} ->
        :none

      %{"awaiting" => %{}} = ladder ->
        case answered(ladder, spec, run, subject, ctx) |> asked_again(run, ctx) do
          {:result, _, _, _, _} = asked -> asked
          _ -> :none
        end

      _ ->
        :none
    end
  end

  defp intend(_run, _spec, _subject, _ctx), do: :none

  # The spec's `parents` fields of each parent, walked up from the subject through the
  # parent relations (`%{kind => [[relation, parent kind]]}`), nearest first: the first
  # parent each one links to, at most 8 up.
  defp parents(%{"parents" => [_ | _] = fields}, kind, subject, relations),
    do: up(fields, kind, subject, relations, 8, "")

  defp parents(_spec, _kind, _subject, _relations), do: {:ok, ""}

  # What the model says is to be read first about the subject (`read_first: true`): the
  # standing decisions and those the subject is based on, as its `read_first` gives them.
  defp read_first(%{"read_first" => true}, subject, %{read_first: read_first})
       when is_function(read_first, 2) do
    case read_first.(subject, &Talk.read/2) do
      text when is_binary(text) and text != "" -> "\n\n## Read these first\n\n" <> text
      _ -> ""
    end
  end

  defp read_first(_spec, _subject, _ctx), do: ""

  defp up(_fields, _kind, _fact, _relations, 0, text), do: {:ok, text}

  defp up(fields, kind, fact, relations, depth, text) do
    parent =
      Enum.find_value(relations[kind] || [], fn [relation, to] ->
        case List.wrap(get_in(fact, ["links", relation])) do
          [key | _] when is_binary(key) -> {to, key}
          _ -> nil
        end
      end)

    with {to, key} <- parent,
         %{"fact" => %{} = found} <-
           Talk.read(to, %{"key" => key, "plain" => true}) do
      values = found["values"] || %{}

      sections =
        for field <- fields,
            value = values[field],
            is_binary(value) and String.trim(value) != "",
            do: "\n\n## #{to} #{key}: #{field}\n\n#{value}"

      up(fields, to, found, relations, depth - 1, text <> Enum.join(sections))
    else
      nil -> {:ok, text}
      %{"fact" => nil} -> {:ok, text}
      _ -> :unavailable
    end
  end

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
        # A review, fix or diagnose with no step to take: nothing to start from, unless
        # the latest result's CI is red (F3-L): the ladder's fix of it.
        ci_fix(run, ladder, spec, ctx)

      true ->
        with {:ok, work} <- work(run, Map.delete(spec, "ladder"), subject, ctx),
             do: {:ok, %{work | ladder: Map.put(ladder || %{}, "repository", repository(spec))}}
    end
  end

  # A task that is no ladder's starts from its spec's base reference; a subject's review or fix
  # from the run's latest result (`refs/atlas/results/<key>`), with the review's answer
  # format or the findings of the review before it.
  defp work(run, spec, subject, _ctx) do
    input = spec["input"]

    {reference, sections} =
      case input do
        %{"update" => field, "base" => base} ->
          {update_ref((subject["values"] || %{})[field], base), []}

        %{"base" => reference} ->
          {reference, []}

        %{"result" => "latest"} ->
          tasks = run["pending"]["tasks"] || []
          key = Translate.latest_result(tasks)
          {key && Translate.result_ref(key), result_sections(spec, tasks, subject)}
      end

    with true <- is_binary(reference),
         {:ok, base} <- base(run, input["repository"], reference),
         do: {:ok, %{base: base, change_set: nil, sections: sections, loop: nil, ladder: nil}}
  end

  # The base of an update of an open pull: Code's merge of `base` into the pull's head.
  defp update_ref(url, base) when is_binary(url) do
    case Regex.run(~r{/pull/(\d+)\z}, url) do
      [_, number] -> "refs/atlas/updates/" <> number <> "/" <> base
      nil -> nil
    end
  end

  defp update_ref(_url, _base), do: nil

  # A fix's spec naming `findings` fixes what that field of the subject says; any other
  # fixes the latest review's findings.
  defp result_sections(%{"kind" => "fix", "findings" => field}, _tasks, subject),
    do: ["\n\n## What to fix\n\n" <> to_string((subject["values"] || %{})[field])]

  defp result_sections(%{"kind" => "fix"}, tasks, _subject) do
    findings = (Translate.latest_review(tasks) || %{})["findings"] || []

    [
      "\n\n## What to fix\n\nThe review found:\n\n" <>
        Enum.map_join(findings, "\n", &("- " <> &1))
    ]
  end

  defp result_sections(%{"kind" => kind}, _tasks, _subject), do: Ladder.sections(kind, %{}, [])

  defp ci_fix(run, ladder, %{"kind" => "fix"} = spec, ctx) do
    with {:ok, views} <- views(spec, run, nil, nil),
         %{"key" => key} <- Ladder.latest(views),
         {{:task, step}, ladder} <-
           Ladder.next(ladder, {:ci_failed, key}, views, profiles(ctx), limits(ctx)) do
      from_step(step, ladder, spec, run, views)
    else
      _ -> :none
    end
  end

  defp ci_fix(_run, _ladder, _spec, _ctx), do: :none

  # The supervisor answered while the ladder waits: the step the answer leads to, when it
  # is this state's. An answer the question does not offer (a typo, `fresh` where it is
  # not offered, …), or one whose step does not run in this state, starts nothing: the
  # ladder asks again (`{:ask, …}`), and the run goes back to `held` or
  # `awaiting_decision` (F-1), never left in a task state with no task.
  defp answered(ladder, spec, run, subject, ctx) do
    answer = (subject["values"] || %{})["answer"]

    with {:ok, views} <- views(spec, run, nil, nil) do
      case Ladder.next(ladder, {:answer, answer}, views, profiles(ctx), limits(ctx)) do
        {{:task, step}, resumed} ->
          with :none <- from_step(step, resumed, spec, run, views),
               do: {:ask, ask(ladder), ladder, answer, views}

        {{tag, _} = asked, ladder} when tag in [:held, :escalate] ->
          {:ask, asked, ladder, answer, views}

        _ ->
          :none
      end
    end
  end

  # The question the waiting ladder asks again, as `Ladder.next/5` gives it for an answer
  # it does not take.
  defp ask(%{"awaiting" => %{"on" => "escalation", "question" => q}}), do: {:escalate, q}

  defp ask(%{"awaiting" => %{"on" => "held"} = a}),
    do: {:held, Map.take(a, ~w(reason task question))}

  # Asked again: the run takes the `held` or `escalate` branch, with the ladder still
  # waiting, and the question and `retry_step` are written again (D2, D3). Entering the
  # state resets `answer`, and its owner hands the subject to the supervisor (B-3). The
  # result joins the run's tasks as a record of the answer; it names no task.
  defp asked_again({:ask, {tag, _} = asked, ladder, answer, views}, run, ctx) do
    ladder = Map.delete(ladder, "next")
    outcome = Atom.to_string(tag)
    result = %{"outcome" => outcome, "answer" => answer, "reason" => "answer_not_taken"}
    by = {run["key"], ["question", run["entry"]]}
    {:result, outcome, result, asked(asked, ladder, by, run, views, ctx), ladder}
  end

  defp asked_again(other, _run, _ctx), do: other

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

  # The base of the spec's reference, from Bases' table only. A missing one, or one resolved
  # more than a few seconds ago (the branch may have moved), is asked for: Bases resolves it
  # in its own task and reconciles the run's subject once it has it.
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
  defp follow(run, intent, spec, subject, ctx) do
    servable(intent, repository(spec) || (run["pending"]["ladder"] || %{})["repository"])
    key = intent["key"]

    case Talk.read(spec["records"]["kind"], %{"key" => key, "plain" => true}) do
      %{"fact" => %{} = fact} ->
        case Translate.outcome(fact, spec["check"] != nil) do
          # Ended: its result is the task's own, taken as always; an answer that came
          # meanwhile is a normal answer, read on the next step.
          {:result, outcome, detail} ->
            ended(run, intent, spec, outcome, detail, fact, ctx)

          not_ended ->
            with :none <- continued_answer(run, intent, spec, subject, ctx) do
              if not_ended == :retry or offerable?(fact), do: Dispatch.ready(key)
              :none
            end
        end

      _absent_or_unavailable ->
        :none
    end
  end

  # Main's ruling on D1 (F2-P): while the loop runs on the recommended default and its
  # question is still open (`awaiting` on the escalation, with a `continue` step), the
  # supervisor's answer is read while a task of that work runs.
  #
  #   * the default itself (the recommended option): it is recorded (`answered`, and the
  #     question closed); the running task goes on, nothing else changes;
  #   * another answer the question offers: the running task is cancelled (Dispatch's
  #     graceful cancel, `lease_end_cause` `answer`), its result is unpinned, and the run
  #     takes the branch of the step the answer leads to. The cancelled task joins the
  #     run's tasks without a `task_kind`, so the ladder never reads its (partial) result.
  #     `abandon` is one too: the task is cancelled and the run takes `abandon` (its
  #     subflow leads it to an end, `stuck` for a package);
  #   * an answer the question does not offer: the work goes on.
  defp continued_answer(run, intent, %{"ladder" => true} = spec, subject, ctx) do
    ladder = run["pending"]["ladder"] || %{}
    answer = (subject["values"] || %{})["answer"]

    # An open escalation with a task running is D1's: without a `continue` step the run
    # waits in a state with no task.
    with %{"on" => "escalation", "question" => q} <- ladder["awaiting"],
         true <- is_binary(answer) and answer in (q["answers"] || []) do
      if answer == (ladder["choice"] || %{})["id"] do
        {:pending, intent, [], Map.merge(ladder, %{"awaiting" => nil, "answered" => answer})}
      else
        follow_answer(run, intent, spec, ladder, answer, ctx)
      end
    else
      _ -> :none
    end
  end

  defp continued_answer(_run, _intent, _spec, _subject, _ctx), do: :none

  defp follow_answer(run, intent, spec, ladder, answer, ctx) do
    with {:ok, views} <- views(spec, run, nil, nil),
         {name, ladder} <-
           followed(
             Ladder.next(ladder, {:answer, answer}, views, profiles(ctx), limits(ctx)),
             answer
           ) do
      Dispatch.cancel(intent["key"], "answer")
      Results.unpin(intent["key"], ctx.now)

      result =
        compact(%{
          "key" => intent["key"],
          "machinery" => intent["machinery"],
          "outcome" => "cancelled",
          "reason" => "answer",
          "answer" => answer
        })

      writes = [cancelled(intent, spec)]
      {:result, name, result, writes, ladder}
    else
      _ -> :none
    end
  end

  # The branch an answer leads to, and the ladder to keep: the step it runs next, or, for
  # `abandon` (the ladder resumes and runs nothing), the `abandon` branch.
  defp followed({{:task, step}, resumed}, _answer),
    do: {step["step"], Map.put(resumed, "next", step)}

  defp followed({:none, resumed}, "abandon"), do: {"abandon", resumed}
  defp followed(_next, _answer), do: :none

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
      else: ended_task(run, intent, spec, outcome, result, fact, ctx)
  end

  # A task that is no ladder's ended: its kind joins its result, so a publication tells the
  # subject's result from its review (`Translate.latest_result/1`); a review's verdict and
  # findings too, and its verdict goes on its task fact; a fix's answer too. A subject's review
  # that asks for changes gives the run `changes_required`; its task fact keeps how it ended.
  defp ended_task(run, intent, spec, outcome, result, fact, ctx) do
    answer = get_in(fact || %{}, ["values", "answer"])

    result =
      result
      |> Map.put("task_kind", spec["kind"])
      |> Map.merge(answered_result(spec["kind"], answer))
      |> Map.merge(if spec["kind"] == "fix", do: compact(%{"answer" => answer}), else: %{})

    asks? =
      outcome in ["completed", "check_failed"] and result["verdict"] == "changes_required" and
        "changes_required" in results(spec)

    values = %{"state" => outcome, "verdict" => result["verdict"]}
    run_outcome = if asks?, do: "changes_required", else: outcome

    with {next, made} <- proposed(spec, run_outcome, run, intent, ctx),
         {:ok, follow_ups} <- follow_ups(spec, outcome, answer, run, intent, ctx) do
      result =
        if next == run_outcome, do: result, else: Map.put(result, "reason", "no proposal")

      # What its proposal made, kept with its result, so a state that discards it
      # (`creates: [discard: true]`) deletes those and nothing added by hand.
      result =
        if made != [] and spec["creates"] != nil,
          do: Map.put(result, "made", for(w <- made, do: [w["kind"], w["content"]["key"]])),
          else: result

      {:result, next, result,
       [change(intent, spec, ["result"], values) | made ++ follow_ups] ++
         failure(spec, next, result, run), nil}
    else
      :unavailable -> :none
    end
  end

  # A task that ended without a result (`stuck` or `abandoned`) whose spec names a field
  # of its subject, `failure`: Flow writes there which task it was, in which state of the
  # run, how it ended and why, for the one who decides what follows. One write, under an
  # id of the task's key; nothing for any other end.
  defp failure(%{"failure" => field} = spec, outcome, result, run)
       when outcome in ["stuck", "abandoned"] do
    why = result["reason"] || result["kind"]

    text =
      "The #{spec["kind"]} task #{result["key"]} (in #{run["state"]}) ended #{outcome}" <>
        if(is_binary(why) and why != "", do: ": #{why}.", else: ".")

    [
      write(result["key"], ["failure"], run["subject_kind"], %{
        "op" => "change",
        "key" => run["subject_key"],
        "values" => %{field => text},
        "by" => "flow"
      })
    ]
  end

  defp failure(_spec, _outcome, _result, _run), do: []

  # What a task that proposes facts (`creates`) or writes a field of its subject
  # (`writes`) asks its agent: the file, at the top of the repository, and its form.
  defp proposal_format(%{"creates" => %{"kind" => kind, "file" => file} = creates}) do
    kind = String.replace(kind, "_", " ")
    more = Enum.map_join(creates["fields"] || [], "", &", its `#{&1}` (as the instructions say)")

    "\n\n## Your proposal\n\nWrite the #{kind}s you propose to the file `#{file}` at the top of the repository: a JSON list with one object per #{kind}, in order, each with its `title` (one line, without a code) and its `description` (what it asks, and how to tell it is done)#{more}. Atlas makes them from that file; write nothing into Atlas yourself."
  end

  defp proposal_format(%{"writes" => %{"field" => field, "file" => file}}) do
    field = String.replace(field, "_", " ")

    "\n\n## Your proposal\n\nWrite the #{field} you propose to the file `#{file}` at the top of the repository, in Markdown: the whole text, as it is to be read. Atlas puts it in its #{field}; write nothing into Atlas yourself."
  end

  defp proposal_format(_spec), do: ""

  # What a review with follow-ups (`follow_ups`) asks its agent: to split what it found.
  defp follow_ups_format(%{"follow_ups" => kind}),
    do:
      "\n\n## Follow-ups\n\nSplit what you find. Your `findings` are only what blocks: what must change for the result to do what the #{kind} asks, within its scope; they go to one fix, and only they decide your verdict. Anything outside its scope (a nice-to-have, hardening, an edge case, a neighbouring improvement) is a follow-up: add it to your JSON block as \"follow_ups\": [{\"title\": \"…\", \"description\": \"…\"}], each with its `title` (one line, without a code) and its `description` (what it asks, and how to tell it is done). Atlas makes each a new #{kind} beside this one; it is not fixed now, and a result with only follow-ups is approved."

  defp follow_ups_format(_spec), do: ""

  # A completed task that proposes facts: one create per entry of its file, under the
  # subject (the kind's parent relation to it), numbered after the facts of that kind
  # there are, by Flow for the run's supervisor. With no such file, or none Flow can read,
  # it ends stuck; `:unavailable` while its result, Code or Facts does not answer.
  defp proposed(
         %{"creates" => %{"kind" => kind}} = spec,
         "completed",
         run,
         intent,
         ctx
       ) do
    with {:ok, entries} <- proposal(run, repository(spec), intent["key"], spec["creates"]),
         [relation] <-
           for([r, to] <- (ctx[:parents] || %{})[kind] || [], to == run["subject_kind"], do: r),
         {:ok, made} <-
           make(
             kind,
             entries,
             relation,
             run["subject_key"],
             intent,
             "creates",
             "break-down",
             run,
             ctx
           ) do
      {"completed", made}
    else
      :no_proposal -> {"stuck", []}
      _ -> :unavailable
    end
  end

  # A completed task that writes a field of its subject (`writes`): the text of its file,
  # put in that field by Flow for the run's supervisor. With no such file, or an empty one,
  # it ends stuck; `:unavailable` while its result or Code does not answer.
  defp proposed(
         %{"writes" => %{"field" => field, "file" => file}} = spec,
         "completed",
         run,
         intent,
         _ctx
       ) do
    with {:ok, text} <- result_file(run, repository(spec), intent["key"], file),
         true <- text?(text) || :no_proposal do
      supervisor = run["supervised_by"]
      by = if is_binary(supervisor), do: "For #{supervisor}: ", else: ""

      {"completed",
       [
         write(intent["key"], ["writes"], run["subject_kind"], %{
           "op" => "change",
           "key" => run["subject_key"],
           "values" => %{field => String.trim(text)},
           "by" => "flow",
           "cause" => "#{by}written by #{intent["key"]}"
         })
       ]}
    else
      :no_proposal -> {"stuck", []}
      _ -> :unavailable
    end
  end

  defp proposed(_spec, outcome, _run, _intent, _ctx), do: {outcome, []}

  # A review's follow-ups (a spec's `follow_ups` names their kind), whatever its verdict:
  # outside the subject's scope, so never fixed now; one fact of that kind per follow-up,
  # under the subject's nearest parent (through the kind's parent relation to that parent's
  # kind). Nothing is made when the subject has no such parent; `:unavailable` while Facts
  # does not answer.
  defp follow_ups(%{"follow_ups" => kind}, outcome, answer, run, intent, ctx)
       when outcome in ["completed", "check_failed"] do
    relations = ctx[:parents] || %{}

    with [_ | _] = entries <- Ladder.follow_ups(answer),
         %{"fact" => %{} = subject} <-
           Talk.read(run["subject_kind"], %{
             "key" => run["subject_key"],
             "plain" => true
           }),
         {relation, parent} <- under(subject, run["subject_kind"], kind, relations) do
      make(kind, entries, relation, parent, intent, "follow_ups", "review", run, ctx)
    else
      [] -> {:ok, []}
      nil -> {:ok, []}
      _ -> :unavailable
    end
  end

  defp follow_ups(_spec, _outcome, _answer, _run, _intent, _ctx), do: {:ok, []}

  # The subject's nearest parent a fact of `kind` can hang under: `{relation, key}`, the
  # relation leading from `kind` to that parent's kind.
  defp under(subject, subject_kind, kind, relations) do
    Enum.find_value(relations[subject_kind] || [], fn [from, to] ->
      with [key | _] when is_binary(key) <- List.wrap(get_in(subject, ["links", from])),
           [relation | _] <- for([r, ^to] <- relations[kind] || [], do: r) do
        {relation, key}
      else
        _ -> nil
      end
    end)
  end

  # One fact of `kind` per entry, with the kind's create defaults under it (as a create by
  # hand has them), linked through `relation` to `under`, numbered after the facts of that
  # kind there are, by Flow for the run's supervisor (its cause names the task that
  # proposed them, in the `what` of the subject).
  defp make(kind, entries, relation, under, intent, tag, what, run, ctx) do
    with %{"prefix" => prefix, "digits" => digits} = ids <- (ctx[:ids] || %{})[kind],
         %{"facts" => facts} when is_list(facts) <-
           Talk.read(kind, %{"plain" => true}) do
      first = HandOver.next_number(%{"prefix" => prefix}, Enum.map(facts, & &1["key"]))
      supervisor = run["supervised_by"]
      by = if is_binary(supervisor), do: "For #{supervisor}: ", else: ""
      cause = "#{by}proposed by #{intent["key"]} in the #{what} of #{run["subject_key"]}"

      made =
        for {entry, i} <- Enum.with_index(entries) do
          key = prefix <> String.pad_leading(Integer.to_string(first + i), digits, "0")

          write(intent["key"], [tag, Integer.to_string(i)], kind, %{
            "op" => "create",
            "key" => key,
            "values" => Map.merge(ids["defaults"] || %{}, entry),
            "links" => %{relation => [under]},
            "by" => "flow",
            "cause" => cause
          })
        end

      {:ok, made}
    else
      _ -> :unavailable
    end
  end

  # The entries of the file at the top of the repository in the task's result commit
  # (`refs/atlas/results/<key>`), which Bases resolves through Code like a branch (asked
  # for, and the run reconciled once it is there): each with a title, and its description
  # when it has one. The file's blob is read from Code here, on the Engine's path: one
  # small read, once per break-down.
  # Each entry: its title and description, the texts of the creates' `fields` it has, the
  # creates' `values`, and its place in the list in the creates' `order` field.
  defp proposal(run, repository, task_key, %{"file" => file} = creates) do
    with {:ok, content} <- result_file(run, repository, task_key, file),
         {:ok, list} <- JSON.decode(content) do
      more = fn e ->
        for(f <- creates["fields"] || [], text?(e[f]), into: %{}, do: {f, String.trim(e[f])})
        |> Map.merge(creates["values"] || %{})
      end

      case for %{"title" => t} = e <- List.wrap(list),
               text?(t),
               do: Map.merge(entry(t, e["description"]), more.(e)) do
        [] -> :no_proposal
        entries -> {:ok, numbered(entries, creates["order"])}
      end
    else
      {:error, _invalid_json} -> :no_proposal
      missing_or_unavailable -> missing_or_unavailable
    end
  end

  defp numbered(entries, nil), do: entries

  defp numbered(entries, field),
    do: for({e, i} <- Enum.with_index(entries, 1), do: Map.put(e, field, i))

  # The content of the file at the top of the repository in the task's result commit:
  # `:no_proposal` when it has no such file, `:unavailable` while its result or Code does
  # not answer.
  defp result_file(run, repository, task_key, file) do
    root = Bases.root_of(repository)

    with {:ok, base} <- base(run, repository, Translate.result_ref(task_key)),
         {:ok, %{"roots" => roots}} <- read_json(base.manifest, base.snapshot_id),
         %{"sha256" => sha} <-
           Enum.find_value(roots, :no_proposal, fn r ->
             r["root"] == root && Enum.find(r["entries"] || [], &(&1["path"] == file))
           end),
         {:ok, _size, content} <- Bases.blob(sha, base.snapshot_id) do
      {:ok, IO.iodata_to_binary(Enum.to_list(content))}
    else
      :no_proposal -> :no_proposal
      {:error, _invalid_json} -> :no_proposal
      _missing_or_unavailable -> :unavailable
    end
  end

  defp read_json(sha, snapshot_id) do
    with {:ok, _size, content} <- Bases.blob(sha, snapshot_id),
         do: JSON.decode(IO.iodata_to_binary(Enum.to_list(content)))
  end

  defp entry(title, description) when is_binary(description),
    do: %{"title" => String.trim(title), "description" => description}

  defp entry(title, _description), do: %{"title" => String.trim(title)}

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

      writes = [
        change(intent, spec, ["result"], values)
        | asked(step, ladder, {intent["key"], ["question"]}, run, views, ctx)
      ]

      {:result, name, result, writes, ladder}
    else
      _ -> :none
    end
  end

  defp taken({:task, step}, ladder), do: {step["step"], Map.put(ladder, "next", step)}

  # D1: rung (e) with a safe default that touches no authority. The default runs (its
  # `continue` step) while the ladder keeps waiting for the supervisor's answer.
  defp taken({:escalate, %{"continue" => %{"step" => _} = step}}, ladder),
    do: {step["step"], Map.put(ladder, "next", step)}

  defp taken({tag, _}, ladder), do: {Atom.to_string(tag), Map.delete(ladder, "next")}

  # D2 and D3: when the ladder asks, the subject's `question` and the step `retry` leads
  # to. One write, under an id of `by` (its task's key; the run's entry when an answer is
  # asked again); nothing when the ladder does not ask.
  defp asked(step, ladder, {key, tag}, run, views, ctx) do
    case question(step) do
      nil ->
        []

      question ->
        [
          write(key, tag, run["subject_kind"], %{
            "op" => "change",
            "key" => run["subject_key"],
            # A new question: an answer to an earlier one is not this one's (D1 runs on
            # with no state that resets it).
            "values" => %{
              "question" => JSON.encode!(question),
              "retry_step" => retry_step(ladder, views, ctx),
              "answer" => "none"
            },
            "by" => "flow"
          })
        ]
    end
  end

  defp question({:held, %{"question" => %{} = q}}), do: q
  defp question({:escalate, %{} = q}), do: q
  defp question(_step), do: nil

  # The step the answer `retry` leads to, as the ladder gives it (pure: the same ladder
  # and tasks give the same step when the answer comes); `none` when the question does
  # not offer it (the ladder then asks again).
  defp retry_step(ladder, views, ctx) do
    case Ladder.next(ladder, {:answer, "retry"}, views, profiles(ctx), limits(ctx)) do
      {{:task, %{"step" => step}}, _} -> step
      _ -> "none"
    end
  end

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

    case Talk.read(records["kind"], %{
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
           "result_fingerprints" => v["result_fingerprints"],
           # What Landing recorded of its publication (F3-L): the ladder's red CI.
           "published_revision" => v["published_revision"],
           "review_url" => v["review_url"],
           "review_ci" => v["review_ci"]
         })
       end}
    end
  end

  # A check that gave no exit status did not finish (#297 case 4): the ladder reads it as
  # one (`interrupted`), so the fix is told to run the check, not shown a failure.
  defp unfinished(%{"ending" => "no_exit_status"} = check),
    do: %{check | "ending" => "interrupted"}

  defp unfinished(check), do: check

  @doc """
  The write that says `intent`'s task is cancelled, sent once the run that no longer holds
  it is stored: Dispatch's sweep then cancels its lease (`AtlasFlow.Dispatch.cancel/3`).
  """
  def cancelled(intent, spec), do: change(intent, spec, ["result"], %{"state" => "cancelled"})

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

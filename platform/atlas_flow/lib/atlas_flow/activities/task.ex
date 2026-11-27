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
     task has no lease, or its last one was lost or ended without a result, but an
     empty turn only once its run counted it (6).
  5. **Result.** The run's result comes from the task fact, which `AtlasFlow.Delivery`
     writes from the Runtime's reports (`Translate.outcome/2`): once the lease is done and
     its result complete, it is put in the run (`pending.tasks`) and its branch is taken
     on the result field (`task_result`): `completed` (completed, and its check, if any,
     exited 0), `check_failed` (completed otherwise), `stuck` (refused, too large,
     invalid, or any other end; until F5 none is retried), or `abandoned`. An ending
     without a result (returned, any interruption such as a Runtime stop, a Runtime crash
     or a restart of its machine, a check that gave no exit status, a supervision cancel,
     work Flow stopped because it was running when Flow booted) reaches no branch: the
     same task is offered again as a fresh attempt, as often as it happens. The Engine
     then writes the task fact's `state` and nothing else: it never writes `input` again
     after the create (Dispatch writes the lease's input, fenced).
  6. **A silent turn is ended (UC-Atlas-03).** A lease that ran out unrenewed (its turn
     went silent past its lease; the Runtime ends such a turn itself), or a `crashed` end
     with no answer and no result, is an empty turn (`Translate.empty/1`). By the
     rule for it (`again?/2`) the first starts the same task once more on its
     own, on a fresh attempt, with nobody asked; the second in a row ends it `abandoned`,
     its reason "its agent went silent twice", so its state's `abandoned` branch takes it
     to whoever decides (and its `failure` field says why). The count is kept in the run
     (its intent's `retried`), never beside it.

  **Why it is to be done.** A spec's `parents` names fields of the subject's parents (the
  relations the model marks `parent`, `ctx.parents`), nearest first: each parent's are
  added after the subject's own `fields`, under `## <kind> <key>: <field>`. Facts not
  answering makes no intent this round.

  **What is already under it.** A spec's `children` names fields of the facts under the
  subject: those of any kind whose parent relation (`ctx.parents`) points at the subject's
  kind and, through it, at the subject. Which ones they are is rela's: Facts' read of the
  subject answers what points at it (`"incoming"`, rela's incoming relations of the key),
  and each is read plainly, as a parent is. They follow the parents, under
  `## Already under it`, which asks the agent to propose only what is missing, each under
  `### <kind> <key>: <field>`, in key order. A subject with nothing under it gets no such
  section; Facts not answering makes no intent this round.

  **A subject's review and fix.** A review or fix names `input:
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

  **Why it ended without a result.** A task whose spec names a field
  of the subject, `failure`, has Flow write there, when it ends `stuck` or `abandoned`,
  which task it was (its kind and key), the run's state it ran in, how it ended and its
  reason, so whoever its run then goes to sees why. A later task whose state resets
  that field (`set`) leaves no stale reason behind.

  **An update of an open pull.** A fix may name `input: %{"repository",
  "base", "update" => field}`, `field` the subject's field holding the web address of a
  pull the service opened: its base is `refs/atlas/updates/<number>/<base>`, which Code
  resolves to `base` merged into that pull's head, conflicts marked in the files, or that
  head itself when it already holds `base`. Not ready while that field holds no pull's
  address. Such a fix whose spec names `findings` ends its instructions with that field's
  text, as a fix of the latest result does: a CI fix starts so from the pull's head, so its
  result lands on whatever the pull's branch holds (IS-Atlas-131).

  **A proposal (slice 7).** A spec's `creates` (`%{"kind", "file"}`) asks its agent, after
  the instructions, to write what it proposes to that file at the top of the repository: a
  JSON list of `{title, description}`, and of the texts the spec's `fields` name. When the
  task completed, Flow reads the file from
  its result commit (`refs/atlas/results/<key>`, through Bases and Code) and makes one fact of that kind per entry,
  with the spec's `values` too, and its place in the list, from 1, in the spec's `order` field,
  linked to the subject through the kind's parent relation to it and numbered after the
  facts of that kind there are (the model's `ids`), `by` Flow with the run's supervisor in
  its cause; the agent never writes into Atlas. Each is also linked to that supervisor
  through the model's producer relation (`ctx.producer`, `supervision.producer`, SC-Atlas-09)
  when its kind is one the relation leads from: whoever supervised the run that
  made it is its producer. Such a fact is never made without one (UC-Atlas-23): while the
  run has no supervisor, the task's end waits, as it does while Facts does not answer.
  With no such file, the task ends `stuck`.
  A spec's `writes` (`%{"field", "file"}`, slice 9) asks for one text instead: Flow puts the
  file's text in that field of the subject; with no such file, or an empty one, `stuck`.

  **Asking instead of guessing (UC-Atlas-24).** Beside either, a spec's `asks` (`%{"field",
  "file"}`) tells its agent that when the subject is too vague to propose from, it writes
  its questions to that file and nothing else. When the task completed and its result has
  that file, not empty, Flow, the only writer, puts its text in that field of the subject
  (`by` Flow, the run's supervisor in its cause), makes nothing of any proposal, and the
  task ends `asked`, which its state maps like any result. With no such file, or an empty
  one, the task ends as it would without `asks`.

  **Read first.** A spec with `read_first: true` adds, after the subject's fields, what the
  model says is to be read first about the subject (its standing decisions and those the
  subject is based on), as the model's `read_first/2` gives it.

  **Follow-ups.** A review's spec may name a kind, `follow_ups`: its agent is asked to split
  what it finds into blocking findings (within the subject's scope; they go to the one fix
  and decide its verdict) and follow-ups (outside it), which it adds to its JSON block as
  `follow_ups`, `[{title, description}]` (`AtlasFlow.Answers.follow_ups/1`). When the review ends,
  whatever its verdict, Flow makes one fact of that kind per follow-up under the subject's
  nearest parent, as it makes a proposal's, with the review in its cause, and linked to the
  run's supervisor as their producer as a proposal's are: their questions go to whoever
  supervised the work that found them.

  An assignment moved away from the machinery a task was made for, while its flow has no
  supervisor, ends the task `abandoned`: a late report is recorded on the task and
  ignored by the run, because the run left the state and no longer holds its key.

  **Results travel over Git (IS-Atlas-100).** A writable task's Runtime pushes its result
  commit to `refs/atlas/results/<key>` (`Translate.result_ref/2`); a later task starts from
  that commit. No task reads or offers a change set, and none is a step of a review → fix
  ladder: a subflow sequences its own author, review and fix states.
  """

  require Logger

  alias AtlasBus.Digest
  alias AtlasFlow.{Answers, Bases, Dispatch, Talk}
  alias AtlasFlow.Runs.HandOver
  alias AtlasFlow.WorkSource.Translate

  @results ~w(completed check_failed stuck abandoned)
  @kinds ~w(plan author review fix diagnose)
  @roles ~w(architect developer investigator)
  @profiles ~w(deep_coding independent_review deep_coding_max)
  @costs ~w(low standard high)

  @doc """
  The results a task's end gives: the four, for a subject's review also `changes_required`,
  for a task that may ask its questions (`asks`) also `asked`.
  """
  def results, do: @results

  def results(%{"kind" => "review", "input" => %{"result" => "latest"}}),
    do: @results ++ ["changes_required"]

  def results(%{"asks" => %{}}), do: @results ++ ["asked"]

  def results(_spec), do: @results

  @doc "Whether this runner can run the task `spec` (as the compiled subflow gives it)."
  def valid?(spec) do
    is_map(spec) and spec["kind"] in @kinds and spec["role"] in @roles and
      spec["profile"] in @profiles and spec["cost_class"] in @costs and text?(spec["field"]) and
      spec["ladder"] == nil and input?(spec["kind"], spec["input"]) and
      check?(spec["check"]) and text?(spec["instructions"]) and
      texts?(spec["fields"] || []) and texts?(spec["parents"] || []) and
      texts?(spec["children"] || []) and
      spec["read_first"] in [nil, true] and note?(spec["note"]) and
      creates?(spec["creates"]) and writes?(spec["writes"]) and
      not (spec["creates"] != nil and spec["writes"] != nil) and
      asks?(spec) and
      (spec["follow_ups"] == nil or text?(spec["follow_ups"])) and
      (spec["findings"] == nil or (spec["kind"] == "fix" and text?(spec["findings"]))) and
      (spec["failure"] == nil or text?(spec["failure"])) and
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

  # What it asks instead of proposing goes beside a proposal, to a file of its own.
  defp asks?(%{"asks" => nil}), do: true

  defp asks?(%{"asks" => %{"field" => field, "file" => file} = asks} = spec),
    do:
      map_size(asks) == 2 and text?(field) and text?(file) and spec["ladder"] == nil and
        (spec["creates"] != nil or spec["writes"] != nil) and
        file not in [spec["creates"]["file"], spec["writes"]["file"]]

  defp asks?(%{"asks" => _}), do: false
  defp asks?(_spec), do: true

  # A Code repository and the reference its base is resolved from, nothing else: never a
  # path (D44), never a URL (a scheme, or `user@host:path`). Or, for a subject's review or
  # fix, a repository and the run's latest result, which Code serves as a base of that
  # repository. Or, for a fix, a repository, a base and the subject's field holding the
  # address of a pull to update with that base.
  defp input?(_kind, %{"repository" => r, "base" => b} = input)
       when map_size(input) == 2,
       do: text?(r) and text?(b) and not url?(r) and not url?(b)

  defp input?("fix", %{"repository" => r, "base" => b, "update" => f} = input),
    do:
      map_size(input) == 3 and text?(r) and text?(b) and text?(f) and not url?(r) and not url?(b)

  defp input?(kind, %{"repository" => r, "result" => "latest"} = input)
       when kind in ["review", "fix"],
       do: map_size(input) == 2 and text?(r) and not url?(r)

  defp input?(_kind, _input), do: false

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
  records, the tasks its run holds and those of its generations before
  (`pending.former_tasks`, IS-Atlas-77), `{:ok, n}`; `:unavailable` when Facts did not
  say. A key is never used again for the same subject key: a subject made again under a
  removed one's key gets a task key of its own, never one Facts may still hold back after
  its delete.
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
        keys = Enum.map(facts, & &1["key"]) ++ held ++ (run["pending"]["former_tasks"] || [])
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
  - `{:pending, intent, writes, nil}`: the task as the run is to hold it, and the record
    writes to send after the run is stored;
  - `{:result, outcome, result, writes, nil}`: the task ended `outcome`; `result` goes in
    the run.

  (The last element, once a review → fix ladder's, is always nil.)

  `ctx`: `assignee` (`assignee/4`, or `:supervised` when its flow has a human supervisor),
  `number` (a function giving `number/2`) and `now`; optionally `limits` (`"retries"`:
  how often an empty turn is started again, default 1).
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

    with {:ok, work} <- work(run, spec, subject),
         {:ok, parents} <- parents(spec, run["subject_kind"], subject, ctx[:parents] || %{}),
         {:ok, children} <-
           children(spec, run["subject_kind"], subject, ctx[:parents] || %{}),
         {:ok, n} <- ctx.number.() do
      key = key(subject["key"], n)

      intent =
        spec
        |> Translate.intent(subject, key, work.base, name, ctx.now)
        |> update_in(
          ["work", "instructions"],
          &(&1 <>
              parents <>
              children <>
              read_first(spec, subject, ctx) <>
              Enum.join(work.sections) <>
              proposal_format(spec) <> asks_format(spec) <> follow_ups_format(spec))
        )
        |> Translate.root_check(repository(spec))
        |> Translate.result_ref(key)

      record =
        write(run, key, ["intent"], spec["records"]["kind"], %{
          "op" => "create",
          "key" => key,
          "values" =>
            compact(%{
              "kind" => spec["kind"],
              "role" => spec["role"],
              "profile" => spec["profile"],
              "input" => JSON.encode!(spec["input"]),
              "client_key" => key,
              "state" => "waiting"
            }),
          "links" => %{spec["records"]["relation"] => [subject["key"]]},
          "by" => "flow"
        })

      {:pending, intent, [record], nil}
    else
      _no_base_or_unavailable -> :none
    end
  end

  # Not with a machinery: no task.
  defp intend(_run, _spec, _subject, _ctx), do: :none

  # The spec's `parents` fields of each parent, walked up from the subject through the
  # parent relations (`%{kind => [[relation, parent kind]]}`), nearest first: the first
  # parent each one links to, at most 8 up.
  defp parents(%{"parents" => [_ | _] = fields}, kind, subject, relations),
    do: up(fields, kind, subject, relations, 8, "")

  defp parents(_spec, _kind, _subject, _relations), do: {:ok, ""}

  # The spec's `children` fields of each fact under the subject: the kinds whose parent
  # relation points at the subject's kind, and of those the facts rela says point at the
  # subject (Facts' read of it answers its `"incoming"`), each read plainly.
  defp children(%{"children" => [_ | _] = fields}, kind, subject, relations) do
    under =
      for {child, links} <- Enum.sort(relations),
          [relation, ^kind] <- links,
          do: {relation, child}

    with [_ | _] <- under,
         %{"fact" => %{}} = answer <- Talk.read(kind, %{"key" => subject["key"]}),
         {:ok, entries} <- under(fields, under, answer["incoming"] || %{}) do
      text =
        if entries == [],
          do: "",
          else:
            "\n\n## Already under it\n\nThese are under it already, and stay: propose only " <>
              "what is missing, never one of these again." <> Enum.join(entries)

      {:ok, text}
    else
      [] -> {:ok, ""}
      %{"fact" => nil} -> {:ok, ""}
      _ -> :unavailable
    end
  end

  defp children(_spec, _kind, _subject, _relations), do: {:ok, ""}

  # One entry per fact under it, through each relation, in key order: its fields.
  defp under(fields, under, incoming) do
    found =
      for {relation, child} <- under,
          key <- incoming[relation] |> List.wrap() |> Enum.filter(&is_binary/1) |> Enum.sort(),
          do: {child, key}

    Enum.reduce_while(found, {:ok, []}, fn {child, key}, {:ok, acc} ->
      case Talk.read(child, %{"key" => key, "plain" => true}) do
        %{"fact" => %{} = fact} ->
          values = fact["values"] || %{}

          sections =
            for field <- fields,
                value = values[field],
                is_binary(value) and String.trim(value) != "",
                do: "\n\n### #{child} #{key}: #{field}\n\n#{value}"

          entry = if sections == [], do: "\n\n### #{child} #{key}", else: Enum.join(sections)
          {:cont, {:ok, acc ++ [entry]}}

        # Gone since rela answered: no longer under it.
        %{"fact" => nil} ->
          {:cont, {:ok, acc}}

        _ ->
          {:halt, :unavailable}
      end
    end)
  end

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

  # Where the next task starts: its spec's base reference; a subject's review or fix from the
  # run's latest result (`refs/atlas/results/<key>`), with the review's answer format or the
  # findings of the review before it.
  defp work(run, spec, subject) do
    input = spec["input"]

    {reference, sections} =
      case input do
        %{"update" => field, "base" => base} ->
          {update_ref((subject["values"] || %{})[field], base), findings_sections(spec, subject)}

        %{"base" => reference} ->
          {reference, []}

        %{"result" => "latest"} ->
          tasks = run["pending"]["tasks"] || []
          key = Translate.latest_result(tasks)
          {key && Translate.result_ref(key), result_sections(spec, tasks, subject)}
      end

    with true <- is_binary(reference),
         {:ok, base} <- base(run, input["repository"], reference),
         do: {:ok, %{base: base, sections: sections}}
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

  defp result_sections(%{"kind" => kind}, _tasks, _subject), do: Answers.sections(kind)

  # An update of an open pull fixes what its spec's `findings` field says, when it names one
  # (a CI fix on the pull's head: what failed in its CI); else it only resolves the merge.
  defp findings_sections(%{"findings" => _} = spec, subject),
    do: result_sections(spec, [], subject)

  defp findings_sections(_spec, _subject), do: []

  defp repository(spec), do: spec["input"]["repository"]

  defp limits(ctx), do: Map.get(ctx, :limits, %{})

  # An empty turn is started once more while fewer than `limits["retries"]` (default 1)
  # were; `retried` is how many times it was started again in a row.
  defp again?(retried, limits), do: retried < (limits["retries"] || 1)

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
  defp follow(run, intent, spec, _subject, ctx) do
    servable(intent, repository(spec))
    key = intent["key"]

    case Talk.read(spec["records"]["kind"], %{"key" => key, "plain" => true}) do
      %{"fact" => %{} = fact} ->
        case Translate.outcome(fact, spec["check"] != nil) do
          # Ended: its result is the task's own, taken as always; an answer that came
          # meanwhile is a normal answer, read on the next step.
          {:result, outcome, detail} ->
            ended(run, intent, spec, outcome, detail, fact, ctx)

          {:empty, why, attempt} ->
            empty(run, intent, spec, fact, why, attempt, ctx)

          not_ended ->
            if not_ended == :retry or offerable?(fact), do: Dispatch.ready(key)
            :none
        end

      _absent_or_unavailable ->
        :none
    end
  end

  # An empty turn (`Translate.empty/1`): its lease ran out silent, or it crashed with no
  # answer and no result. The rule for an abandoned task (`again?/2`): the first is
  # started once more, the second in a row ends the task `abandoned`. The count is kept in
  # its run: the attempts started again, in the intent it holds (`pending.task["retried"]`, `Translate.retried/1`). Counting stores the
  # run first; only an attempt it holds is granted again by Dispatch, on a fresh attempt
  # of the same task (a new `task_attempt`), so a Flow restart neither resets nor doubles
  # the count: an attempt counted already is only offered again.
  defp empty(run, intent, spec, fact, why, attempt, ctx) do
    retried = Translate.retried(intent)

    cond do
      attempt in retried ->
        Dispatch.ready(intent["key"])
        :none

      again?(length(retried), limits(ctx)) ->
        {:pending, Map.put(intent, "retried", retried ++ [attempt]), [], nil}

      true ->
        reason = silent(why, length(retried) + 1)
        ended(run, intent, spec, "abandoned", %{"reason" => reason}, fact, ctx)
    end
  end

  defp silent(_why, n) when n >= 2, do: "its agent went silent #{times(n)}"
  defp silent("silent", _n), do: "its agent went silent"
  defp silent(_why, _n), do: "its agent ended with no result"

  defp times(2), do: "twice"
  defp times(n), do: "#{n} times"

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
  # gave the same manifest. A cast; while a restore fails, each reconcile asks again.
  defp servable(intent, repository) do
    manifest = get_in(intent, ["work", "input", "base", "manifest"])
    snapshot = intent["base_snapshot"]

    if is_binary(repository) and is_binary(manifest) and is_binary(snapshot) and
         not Bases.held?(manifest, snapshot),
       do: Bases.restore(repository, snapshot, manifest)

    :ok
  end

  defp abandon(run, intent, spec, ctx) do
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

    ended_task(run, intent, spec, outcome, result, fact, ctx)
  end

  # A task ended: its kind joins its result, so a publication tells the
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
        if next in [run_outcome, "asked"],
          do: result,
          else: Map.put(result, "reason", "no proposal")

      # What its proposal made, kept with its result, so a state that discards it
      # (`creates: [discard: true]`) deletes those and nothing added by hand. Questions
      # (`asked`) made nothing: their write is the subject's own field.
      result =
        if made != [] and spec["creates"] != nil and next != "asked",
          do: Map.put(result, "made", for(w <- made, do: [w["kind"], w["content"]["key"]])),
          else: result

      {:result, next, result,
       [change(run, intent, spec, ["result"], values) | made ++ follow_ups] ++
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
      write(run, result["key"], ["failure"], run["subject_kind"], %{
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

    "\n\n## Your proposal\n\nWrite the #{kind}s you propose to the file `#{file}` at the top of the repository: a JSON list with one object per #{kind}, in order, each with its `title` (one line, without a code) and its `description` (what it asks, and how to tell it is done)#{more}. For Scene, use case and issue descriptions, use Markdown to structure longer text; keep concise descriptions plain. Atlas makes them from that file; write nothing into Atlas yourself."
  end

  defp proposal_format(%{"writes" => %{"field" => field, "file" => file}}) do
    field = String.replace(field, "_", " ")

    "\n\n## Your proposal\n\nWrite the #{field} you propose to the file `#{file}` at the top of the repository, in Markdown: the whole text, as it is to be read. Atlas puts it in its #{field}; write nothing into Atlas yourself."
  end

  defp proposal_format(_spec), do: ""

  # What a task that may ask instead of proposing (`asks`) tells its agent.
  defp asks_format(%{"asks" => %{"file" => file}}),
    do:
      "\n\n## If you cannot propose yet\n\nWhen what you are given is too vague to propose from, do not guess. Write your questions instead to the file `#{file}` at the top of the repository, in Markdown, each one a question its author can answer, and write no proposal. Atlas takes them to its author, and a new pass starts with their answers; write nothing into Atlas yourself."

  defp asks_format(_spec), do: ""

  # What a review with follow-ups (`follow_ups`) asks its agent: to split what it found.
  defp follow_ups_format(%{"follow_ups" => kind}),
    do:
      "\n\n## Follow-ups\n\nSplit what you find. Your `findings` are only what blocks: what must change for the result to do what the #{kind} asks, within its scope; they go to one fix, and only they decide your verdict. Anything outside its scope (a nice-to-have, hardening, an edge case, a neighbouring improvement) is a follow-up: add it to your JSON block as \"follow_ups\": [{\"title\": \"…\", \"description\": \"…\"}], each with its `title` (one line, without a code) and its `description` (what it asks, and how to tell it is done). For Scene, use case and issue descriptions, use Markdown to structure longer text; keep concise descriptions plain. Atlas makes each a new #{kind} beside this one; it is not fixed now, and a result with only follow-ups is approved."

  defp follow_ups_format(_spec), do: ""

  # A completed task that may ask (`asks`) and whose result has its questions, not empty:
  # one write of their text in that field of the subject, by Flow for the run's supervisor,
  # nothing of its proposal, and it ends `asked`. Without them it ends as without `asks`;
  # `:unavailable` while its result or Code does not answer.
  defp proposed(
         %{"asks" => %{"field" => field, "file" => file}} = spec,
         "completed",
         run,
         intent,
         ctx
       ) do
    without = fn -> proposed(Map.delete(spec, "asks"), "completed", run, intent, ctx) end

    case result_file(run, repository(spec), intent["key"], file) do
      {:ok, text} ->
        if text?(text) do
          supervisor = run["supervised_by"]
          by = if is_binary(supervisor), do: "For #{supervisor}: ", else: ""

          {"asked",
           [
             write(run, intent["key"], ["asks"], run["subject_kind"], %{
               "op" => "change",
               "key" => run["subject_key"],
               "values" => %{field => String.trim(text)},
               "by" => "flow",
               "cause" => "#{by}asked by #{intent["key"]}"
             })
           ]}
        else
          without.()
        end

      :no_proposal ->
        without.()

      _unavailable ->
        :unavailable
    end
  end

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
         write(run, intent["key"], ["writes"], run["subject_kind"], %{
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

    with [_ | _] = entries <- Answers.follow_ups(answer),
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
  # proposed them, in the `what` of the subject), and linked to that supervisor as their
  # producer (`produced/3`). A kind that records its producer is not made while the run
  # has none: `:unavailable`, so the task's end waits for one (UC-Atlas-23).
  defp make(kind, entries, relation, under, intent, tag, what, run, ctx) do
    supervisor = run["supervised_by"]

    with {:ok, producer} <- produced(kind, supervisor, ctx),
         %{"prefix" => prefix, "digits" => digits} = ids <- (ctx[:ids] || %{})[kind],
         %{"facts" => facts} when is_list(facts) <-
           Talk.read(kind, %{"plain" => true}) do
      first = HandOver.next_number(%{"prefix" => prefix}, Enum.map(facts, & &1["key"]))
      by = if is_binary(supervisor), do: "For #{supervisor}: ", else: ""
      cause = "#{by}proposed by #{intent["key"]} in the #{what} of #{run["subject_key"]}"

      made =
        for {entry, i} <- Enum.with_index(entries) do
          mark = %{
            "task" => intent["key"],
            "tag" => tag,
            "index" => i,
            "prefix" => prefix,
            "digits" => digits,
            "number" => first + i
          }

          made(run, mark, kind, %{
            "op" => "create",
            "values" => Map.merge(ids["defaults"] || %{}, entry),
            "links" => Map.merge(%{relation => [under]}, producer),
            "by" => "flow",
            "cause" => cause
          })
        end

      {:ok, made}
    else
      _ -> :unavailable
    end
  end

  # One create a proposal or a review's follow-ups make, numbered as its mark says, under
  # an id of the run, the task, the tag, its place among them and its key: one renumbered
  # past a key that is held back (`renumber/3`) is another write, never the refused one.
  defp made(run, mark, kind, content) do
    key =
      mark["prefix"] <> String.pad_leading(Integer.to_string(mark["number"]), mark["digits"], "0")

    run
    |> write(
      mark["task"],
      [mark["tag"], Integer.to_string(mark["index"]), key],
      kind,
      Map.put(content, "key", key)
    )
    |> Map.put("numbered", mark)
  end

  @doc """
  `run`'s pending writes with the create `refused` (one a proposal or a review's
  follow-ups make, `"numbered"`; Facts refused it because its key is taken or held back
  after a delete, IS-Atlas-38) and every create made with it after it numbered from
  `first` on, in their order, each under the id of its new key. The creates before it keep
  theirs; the run's last task result names the keys they are made under now (`made`), so a
  discard deletes those. `run` as it is when `refused` is none of its.
  """
  def renumber(run, %{"numbered" => %{"task" => task, "tag" => tag, "index" => from}}, first) do
    renamed =
      for %{"numbered" => %{"task" => ^task, "tag" => ^tag, "index" => i} = mark} = w <-
            run["pending"]["writes"],
          i >= from,
          into: %{} do
        moved = made(run, Map.put(mark, "number", first + i - from), w["kind"], w["content"])
        {w["content"]["key"], moved}
      end

    writes =
      for w <- run["pending"]["writes"] do
        with %{"numbered" => %{"task" => ^task, "tag" => ^tag}} <- w,
             %{} = moved <- renamed[w["content"]["key"]] do
          moved
        else
          _ -> w
        end
      end

    keys = Map.new(renamed, fn {old, w} -> {old, w["content"]["key"]} end)

    tasks =
      for t <- run["pending"]["tasks"] || [] do
        if t["key"] == task and is_list(t["made"]),
          do: Map.put(t, "made", for([kind, key] <- t["made"], do: [kind, keys[key] || key])),
          else: t
      end

    run
    |> put_in(["pending", "writes"], writes)
    |> then(&if(run["pending"]["tasks"], do: put_in(&1, ["pending", "tasks"], tasks), else: &1))
  end

  def renumber(run, _refused, _first), do: run

  # The link from a fact a proposal (`creates`) or a review's follow-ups make to its
  # producer, the run's human supervisor, through the model's producer relation when it
  # leads from the fact's kind: `{:ok, links}`, none for a kind it does not lead from or
  # without a producer relation; `:no_supervisor` for a kind it leads from while the run
  # has no supervisor, so nothing is made with an empty producer.
  defp produced(kind, supervisor, %{producer: {relation, from}}) do
    cond do
      kind not in from -> {:ok, %{}}
      is_binary(supervisor) and supervisor != "" -> {:ok, %{relation => [supervisor]}}
      true -> :no_supervisor
    end
  end

  defp produced(_kind, _supervisor, _ctx), do: {:ok, %{}}

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

  defp answered_result("review", answer) do
    case Answers.verdict(answer) do
      {:ok, verdict, findings} -> %{"verdict" => verdict, "findings" => findings}
      :error -> %{}
    end
  end

  defp answered_result("diagnose", answer),
    do: compact(%{"diagnosis" => Answers.diagnosis(answer)})

  defp answered_result(_kind, _answer), do: %{}

  @doc """
  The write that says `intent`'s task is cancelled, sent once the run that no longer holds
  it is stored: Dispatch's sweep then cancels its lease (`AtlasFlow.Dispatch.cancel/3`).
  """
  def cancelled(run, intent, spec),
    do: change(run, intent, spec, ["result"], %{"state" => "cancelled"})

  defp change(run, intent, spec, tag, values),
    do:
      write(run, intent["key"], tag, spec["records"]["kind"], %{
        "op" => "change",
        "key" => intent["key"],
        "values" => compact(values),
        "by" => "flow"
      })

  # A write's stable id names the run (its key is a digest of its subflow, subject and
  # generation), the task and the write's tag (IS-Atlas-77): a resend of it is answered
  # from Facts' ledger, and a write of another run, or of a new generation on a subject
  # made again under a removed one's key, is never taken for one already stored.
  defp write(run, key, tag, kind, content),
    do: %{
      "id" => id(run, key, tag),
      "kind" => kind,
      "content" => content
    }

  defp id(run, key, tag),
    do: Digest.of_term([run["key"], key | tag]) |> String.replace_prefix("sha256:", "")

  defp compact(map), do: Map.reject(map, fn {_, v} -> v == nil end)
end

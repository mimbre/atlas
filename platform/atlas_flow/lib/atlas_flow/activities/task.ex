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
     (version 2, `AtlasFlow.WorkSource.Translate.intent/6`) are stored in the run
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
  """

  require Logger

  alias AtlasBus.Digest
  alias AtlasFlow.{Bases, Dispatch, Results, Talk}
  alias AtlasFlow.WorkSource.Translate

  @results ~w(completed check_failed stuck abandoned)
  @kinds ~w(plan author review fix)
  @roles ~w(architect developer)
  @profiles ~w(deep_coding independent_review)
  @costs ~w(low standard high)

  def results, do: @results

  @doc "Whether this runner can run the task `spec` (as the compiled subflow gives it)."
  def valid?(spec) do
    is_map(spec) and spec["kind"] in @kinds and spec["role"] in @roles and
      spec["profile"] in @profiles and spec["cost_class"] in @costs and text?(spec["field"]) and
      input?(spec["input"]) and check?(spec["check"]) and text?(spec["instructions"]) and
      texts?(spec["fields"] || []) and records?(spec["records"]) and text?(spec["machinery"])
  end

  # A Code repository and the reference its base is resolved from, nothing else: never a
  # path (D44), never a URL (a scheme, or `user@host:path`).
  defp input?(%{"repository" => r, "base" => b} = input),
    do: map_size(input) == 2 and text?(r) and text?(b) and not url?(r) and not url?(b)

  defp input?(_), do: false

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
  - `{:pending, intent, writes}`: the task as the run is to hold it, and the record writes
    to send after the run is stored;
  - `{:result, outcome, result, writes}`: the task ended `outcome`; `result` goes in the run.

  `ctx`: `assignee` (`assignee/4`), `number` (a function giving `number/2`) and `now`.
  """
  def step(run, spec, subject, ctx) do
    intent = run["pending"]["task"]

    cond do
      ctx.assignee == :unavailable ->
        :none

      intent == nil ->
        intend(run, spec, subject, ctx)

      ctx.assignee != {:machinery, intent["machinery"]} ->
        abandon(intent, spec, ctx)

      not Translate.intent?(intent) ->
        # A push-path intent (version 1) is never offered: it ends stuck.
        ended(intent, spec, "stuck", %{"reason" => "unsupported intent"}, nil)

      true ->
        follow(intent, spec)
    end
  end

  defp intend(run, spec, subject, %{assignee: {:machinery, name}} = ctx) do
    %{"repository" => repository, "base" => reference} = spec["input"]

    with {:ok, base} <- base(run, repository, reference),
         {:ok, n} <- ctx.number.() do
      key = key(subject["key"], n)
      intent = Translate.intent(spec, subject, key, base, name, ctx.now)

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
              "state" => "waiting"
            }),
          "links" => %{spec["records"]["relation"] => [subject["key"]]},
          "by" => "flow"
        })

      {:pending, intent, [record]}
    else
      _no_base_or_unavailable -> :none
    end
  end

  defp intend(_run, _spec, _subject, _ctx), do: :none

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
  defp follow(intent, spec) do
    servable(intent, spec)
    key = intent["key"]

    case Talk.transition_read(spec["records"]["kind"], %{"key" => key, "plain" => true}) do
      %{"fact" => %{} = fact} ->
        case Translate.outcome(fact, spec["check"] != nil) do
          {:result, outcome, detail} ->
            ended(intent, spec, outcome, detail, fact)

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
  # gave the same manifest. A cast; while a restore fails, each reconcile asks again.
  defp servable(intent, spec) do
    manifest = get_in(intent, ["work", "input", "base", "manifest"])
    snapshot = intent["base_snapshot"]

    if is_binary(manifest) and is_binary(snapshot) and not Bases.held?(manifest, snapshot),
      do: Bases.restore(spec["input"]["repository"], snapshot, manifest)

    :ok
  end

  defp abandon(intent, spec, ctx) do
    Results.unpin(intent["key"], ctx.now)
    ended(intent, spec, "abandoned", %{"reason" => "assignment moved away"}, nil)
  end

  # The task ended: its result for the run, and the task fact's `state`, the only field
  # the Engine writes after the create.
  defp ended(intent, spec, outcome, detail, fact) do
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

    {:result, outcome, result, [change(intent, spec, ["result"], %{"state" => outcome})]}
  end

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

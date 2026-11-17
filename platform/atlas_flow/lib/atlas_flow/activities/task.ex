defmodule AtlasFlow.Activities.Task do
  @moduledoc """
  Tasks: one unit of work Flow defines for the machinery a subject is assigned to, handed
  to its Runtime as work (plan 2026-11-17 §3.1, §3.5, §6 F1.3). Flow codes against
  `AtlasFlow.Runtime.Client` only: `config :atlas_flow, :runtime_client, module` (default
  `AtlasFlow.Runtime.Client.Http`); the machinery is `AtlasFlow.Runtime.Config`'s.

  A state with a `task` (`RelaDSL.Schema`) runs it, as `AtlasFlow.Runs.Store` drains the
  run:

  1. **Only for machinery (E1).** While the subject's owner (through the state's owner
     relation, on the projection's component when it names one) is not a fact of the
     spec's `machinery` kind that Flow's configuration names, nothing is done: no task.
  2. **Intent first (obligation 2).** The task's key, `TK-<subject>-<n>`, and its request
     are stored in the run (`pending.task`) before anything is sent, and the task record
     (`records`: its kind and relation to the subject) is written before the first
     `submit`. The key names no machine; it is the work's client key and its
     `Idempotency-Key`.
  3. **Backlog (obligation 1).** A task without a `work_id` is in the backlog. Before each
     submit, `find_work(key)` says whether the Runtime has it already (a lost answer); it
     is submitted only after `:not_found`, the only answer after which a submit may
     follow (obligation 4), and only while `capacity` shows its profile available. On
     `at_capacity`, or no room, it waits: for the Link's `{:capacity, c}` (the engine
     reconciles the waiting tasks it has room for, oldest first), or else until
     `Retry-After` (60 s when none is given). A transport error changes nothing: the same
     key is sent again the next time.
  4. **Snapshots by revision (obligation 5).** A submitted task follows its work: the
     snapshot the Link reported, or `get_work` (at boot, on every round). A snapshot whose
     `revision` is not newer than the one applied is passed over.
  5. **Result.** When the work's latest attempt ended, the task's result is put in the run
     (`pending.tasks`) and its branch is taken on the result field (`task_result`):
     `completed` (completed, and its check, if any, exited 0), `check_failed` (completed,
     the check failed, timed out, did not finish or did not run), `stuck` (any other
     result; until F5 none is retried), or `abandoned`.

  A `410` (`pruned`) is `stuck`, never a resubmit; `unreachable` is never lost: nothing
  moves, nothing is rerouted (obligation 4). An assignment moved away from the machinery
  ends the task `abandoned`: a late result is ignored, because the run left the state and
  no longer holds its key. The task record is a record only, which no state reads.

  The workspace is a `repository` one (`input: [repository:, base:]`) on the branch
  `flow/<key>`: a remote client never names a path on the machinery's machine (Runtime
  D44), so `folder` is never sent.
  """

  require Logger

  alias AtlasBus.Digest
  alias AtlasFlow.Runtime.Config
  alias AtlasFlow.Talk

  @results ~w(completed check_failed stuck abandoned)
  @kinds ~w(plan author review fix)
  @roles ~w(architect developer)
  @profiles ~w(deep_coding independent_review)
  @costs ~w(low standard high)
  @terminal ~w(completed failed crashed interrupted cancelled returned)
  @answer_bytes 8192
  @retry_after 60

  def results, do: @results

  @doc "The Runtime client Flow calls."
  def client, do: Application.get_env(:atlas_flow, :runtime_client, AtlasFlow.Runtime.Client.Http)

  @doc "Whether this runner can run the task `spec` (as the compiled subflow gives it)."
  def valid?(spec) do
    is_map(spec) and spec["kind"] in @kinds and spec["role"] in @roles and
      spec["profile"] in @profiles and spec["cost_class"] in @costs and text?(spec["field"]) and
      input?(spec["input"]) and check?(spec["check"]) and text?(spec["instructions"]) and
      texts?(spec["fields"] || []) and records?(spec["records"]) and text?(spec["machinery"])
  end

  # A repository and its base, nothing else: never a path (D44).
  defp input?(%{"repository" => r, "base" => b} = input),
    do: map_size(input) == 2 and text?(r) and text?(b)

  defp input?(_), do: false

  defp check?(nil), do: true
  defp check?(command), do: is_list(command) and command != [] and texts?(command)

  defp records?(%{"kind" => k, "relation" => r} = records),
    do: map_size(records) == 2 and text?(k) and text?(r)

  defp records?(_), do: false

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

  @doc "The work request of task `key` on `subject` (string keys; the key goes as header)."
  def request(spec, subject, key) do
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
      "cost_class" => spec["cost_class"],
      "workspace" => %{
        "kind" => "repository",
        "url" => spec["input"]["repository"],
        "branch" => "flow/" <> key,
        "base" => spec["input"]["base"]
      }
    }
    |> then(
      &if(spec["check"], do: Map.put(&1, "after_check", %{"command" => spec["check"]}), else: &1)
    )
  end

  @doc """
  Whether `capacity` (as `capacity/1` or the Link gives it) has room for a work of
  `profile`: accepting, the profile not unavailable, and a free slot or buffer place.
  """
  def room?(capacity, profile) when is_map(capacity) do
    free = fn part -> get_in(capacity, [part, "free"]) end

    capacity["accepting"] != false and
      get_in(capacity, ["profiles", profile, "available"]) != false and
      Enum.any?(["slots", "buffer"], &(is_integer(free.(&1)) and free.(&1) > 0))
  end

  def room?(_capacity, _profile), do: false

  @doc """
  The task's next step on `run`, in a state whose mechanism is `{:task, spec}`:

  - `:none`: nothing changes (no machinery, waiting, unreachable);
  - `{:pending, intent, writes}`: the task as the run is to hold it, and the record writes
    to send after the run is stored;
  - `{:result, outcome, result, writes}`: the task ended `outcome`; `result` goes in the run.

  `ctx`: `assignee` (`assignee/4`), `number` (a function giving `number/2`), `now`, `wake`
  (a capacity event: a waiting task asks again before its `retry_at`) and `works` (snapshots
  the Link reported, by `work_id`).
  """
  def step(run, spec, subject, ctx) do
    intent = run["pending"]["task"]

    cond do
      ctx.assignee == :unavailable ->
        :none

      intent == nil ->
        intend(spec, subject, ctx)

      ctx.assignee != {:machinery, intent["machinery"]} ->
        ended(intent, spec, "abandoned", %{"reason" => "assignment moved away"})

      true ->
        case Config.fetch(intent["machinery"]) do
          {:ok, machinery} -> remote(machinery, intent, spec, ctx)
          :error -> unconfigured(intent["machinery"])
        end
    end
  end

  defp intend(spec, subject, %{assignee: {:machinery, name}} = ctx) do
    with {:ok, _machinery} <- Config.fetch(name),
         {:ok, n} <- ctx.number.() do
      key = key(subject["key"], n)
      request = request(spec, subject, key)

      intent = %{
        "version" => 1,
        "key" => key,
        "machinery" => name,
        "request" => request,
        "created_at" => DateTime.to_iso8601(ctx.now),
        "state" => "waiting",
        "work_id" => nil,
        "revision" => nil,
        "retry_at" => nil
      }

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
      :error -> unconfigured(name)
      :unavailable -> :none
    end
  end

  defp intend(_spec, _subject, _ctx), do: :none

  defp unconfigured(name) do
    Logger.warning("flow: machinery #{name} is not configured; its tasks wait")
    :none
  end

  # No work_id yet: look the key up first, submit only after not_found.
  defp remote(machinery, %{"work_id" => nil} = intent, spec, ctx) do
    if waiting?(intent, ctx) do
      :none
    else
      case client().find_work(machinery, intent["key"]) do
        {:found, work} -> apply_work(intent, work, spec)
        {:pruned, _id, kind} -> ended(intent, spec, "stuck", %{"reason" => "pruned: #{kind}"})
        :not_found -> submit(machinery, intent, spec, ctx)
        other -> unanswered(intent, other)
      end
    end
  end

  defp remote(machinery, intent, spec, ctx) do
    reported = ctx.works[intent["work_id"]]

    answer =
      if is_map(reported) and newer?(intent, reported),
        do: {:found, reported},
        else: client().get_work(machinery, intent["work_id"])

    case answer do
      {:found, work} ->
        apply_work(intent, work, spec)

      {:pruned, _id, kind} ->
        ended(intent, spec, "stuck", %{"reason" => "pruned: #{kind}"})

      # The Runtime does not know the id: the next step asks by key, as at boot.
      :not_found ->
        {:pending, %{intent | "work_id" => nil, "revision" => nil}, []}

      other ->
        unanswered(intent, other)
    end
  end

  defp waiting?(%{"retry_at" => at}, ctx) when is_binary(at),
    do: not ctx.wake and DateTime.compare(ctx.now, AtlasFlow.Runs.Run.parse!(at)) == :lt

  defp waiting?(_intent, _ctx), do: false

  defp submit(machinery, intent, spec, ctx) do
    profile = intent["request"]["profile"]

    case client().capacity(machinery) do
      {:capacity, capacity} ->
        if room?(capacity, profile) do
          case client().submit(machinery, intent["key"], intent["request"]) do
            {tag, work} when tag in [:accepted, :existing] ->
              apply_work(intent, work, spec)

            {:at_capacity, retry_after} ->
              wait(intent, ctx, retry_after)

            {:refused, :unauthenticated} = refused ->
              unanswered(intent, refused)

            {:refused, reason} ->
              ended(intent, spec, "stuck", %{"reason" => "refused: #{reason}"})

            other ->
              unanswered(intent, other)
          end
        else
          wait(intent, ctx, capacity["retry_after"])
        end

      other ->
        unanswered(intent, other)
    end
  end

  defp wait(intent, ctx, retry_after) do
    seconds = if is_integer(retry_after) and retry_after >= 0, do: retry_after, else: @retry_after
    at = ctx.now |> DateTime.add(seconds, :second) |> DateTime.to_iso8601()
    {:pending, %{intent | "retry_at" => at}, []}
  end

  defp unanswered(intent, answer) do
    Logger.info("flow: task #{intent["key"]} on #{intent["machinery"]}: #{inspect(answer)}")
    :none
  end

  defp newer?(%{"revision" => nil}, _work), do: true

  defp newer?(%{"revision" => applied}, %{"revision" => revision})
       when is_integer(revision) and is_integer(applied),
       do: revision > applied

  defp newer?(_intent, _work), do: false

  # A snapshot of this task's work, applied by revision.
  defp apply_work(intent, work, spec) do
    own? =
      is_map(work) and is_binary(work["work_id"]) and
        work["work_id"] == (intent["work_id"] || work["work_id"]) and
        work["client_key"] in [nil, intent["key"]]

    cond do
      not own? ->
        unanswered(intent, {:not_this_work, work})

      intent["work_id"] != nil and not newer?(intent, work) ->
        :none

      true ->
        attempt = latest(work)
        updated = %{intent | "work_id" => work["work_id"], "revision" => work["revision"]}
        updated = Map.merge(updated, %{"state" => work["state"], "attempt" => attempt["attempt"]})

        case attempt["result"] do
          %{"kind" => kind} = result when kind in @terminal ->
            {outcome, check} = outcome(result, spec)

            ended(updated, spec, outcome, %{
              "kind" => kind,
              "reason" => result["reason"],
              "check" => check,
              "answer" => result["answer"]
            })

          _ ->
            moved? =
              updated["work_id"] != intent["work_id"] or updated["state"] != intent["state"]

            writes =
              if moved?,
                do: [
                  change(updated, spec, [work["work_id"], work["state"]], %{
                    "work_id" => work["work_id"],
                    "attempt" => attempt["attempt"],
                    "state" => work["state"]
                  })
                ],
                else: []

            {:pending, updated, writes}
        end
    end
  end

  defp latest(work) do
    case Enum.max_by(work["attempts"] || [], &(&1["attempt"] || 0), fn -> nil end) do
      %{} = attempt -> attempt
      nil -> %{"attempt" => nil}
    end
  end

  # How a completed work's check ended, as the task sees it (plan §4: a check that did
  # not finish is a failed one): `{outcome, check}`.
  defp outcome(%{"kind" => "completed"} = result, spec) do
    check = get_in(result, ["work_product", "check"])

    summary =
      if is_map(check),
        do: %{
          "exit_status" => check["exit_status"],
          "ending" => ending(check),
          "tail" => get_in(check, ["output", "tail"])
        }

    cond do
      spec["check"] == nil -> {"completed", summary}
      summary == nil -> {"check_failed", %{"ending" => "not_run"}}
      summary["exit_status"] == 0 and summary["ending"] == nil -> {"completed", summary}
      true -> {"check_failed", summary}
    end
  end

  defp outcome(_result, _spec), do: {"stuck", nil}

  defp ending(check) do
    cond do
      check["timed_out"] == true -> "timed_out"
      check["cancelled"] == true -> "cancelled"
      check["interrupted"] == true -> "interrupted"
      is_binary(check["error"]) -> "error: " <> check["error"]
      is_binary(check["signal"]) -> "signal: " <> check["signal"]
      check["exit_status"] == nil -> "no_exit_status"
      true -> nil
    end
  end

  # The task ended: its result for the run, and the record's last write.
  defp ended(intent, spec, outcome, detail) do
    result =
      compact(%{
        "key" => intent["key"],
        "machinery" => intent["machinery"],
        "work_id" => intent["work_id"],
        "attempt" => intent["attempt"],
        "outcome" => outcome,
        "kind" => detail["kind"],
        "reason" => detail["reason"],
        "check" => detail["check"]
      })

    check = detail["check"] || %{}

    values = %{
      "state" => outcome,
      "work_id" => intent["work_id"],
      "attempt" => intent["attempt"],
      "result_kind" => detail["kind"],
      "reason" => detail["reason"],
      "check_exit_status" => check["exit_status"],
      "check_ending" => check["ending"],
      "check_output_tail" => check["tail"],
      "answer" => answer(detail["answer"])
    }

    {:result, outcome, result, [change(intent, spec, ["result"], values)]}
  end

  defp answer(text) when is_binary(text) and byte_size(text) > @answer_bytes,
    do: text |> binary_part(0, @answer_bytes) |> String.chunk(:valid) |> hd()

  defp answer(text) when is_binary(text), do: text
  defp answer(_), do: nil

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

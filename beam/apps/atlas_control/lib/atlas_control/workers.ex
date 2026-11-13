defmodule AtlasControl.Workers do
  @moduledoc """
  Worker snapshots and durable guidance through Facts reads/writes supplied by Control.
  No harness calls, viewer-owned workers or local interaction store live here.

  `m` is the model as Control serves it (`AtlasControl.Model.catalog/2`): the turn's and
  the guidance records' names are the model's (`turn/0`, `guidance/0`), and who may read
  and submit is the environment's (its settings' `"workers"`: `read` and `submit`, each
  `%{"actors" => [key]}`).
  """

  @identity ~w(environment machine worker turn attempt)
  @capabilities ~w(queued_input durable_accept_query consumption_evidence)
  @submission ~w(client_key body cause)
  @max_body 16_384
  @finished 20

  def handle(operation, request, m, actor, read, write) do
    permission = if operation == "worker_submit", do: "submit", else: "read"

    request =
      case request["execution"] do
        %{"worker" => %{} = worker, "turn" => turn} = execution ->
          Map.put(
            request,
            "execution",
            Map.merge(worker, %{"turn" => turn, "attempt" => execution["attempt"]})
          )

        _ ->
          request
      end

    with :ok <- authorize(m, actor, permission, read) do
      case operation do
        "worker_overview" ->
          overview(m, actor, read)

        "worker_inspect" ->
          with {:ok, view} <- inspect_execution(m, actor, request["execution"], read),
               do: {:ok, %{"view" => view}}

        "worker_submit" ->
          submit(m, actor, request, read, write)

        "worker_query" ->
          query(m, actor, request, read)

        "worker_history" ->
          history(m, actor, request, read)

        "worker_receipts" ->
          receipts(m, actor, request, read)

        _ ->
          {:error, "unsupported_operation"}
      end
    end
  end

  # Grants name admitted actors, separately for read and submit. Kind is resolved
  # from Facts only to verify the actor still exists, never as a blanket grant.
  def authorize(m, %{key: actor, kind: kind}, permission, read)
      when is_binary(actor) and is_binary(kind) do
    case get_in(m.settings || %{}, ["workers", permission, "actors"]) do
      actors when is_list(actors) ->
        if Enum.all?(actors, &filled?/1) and actor in actors do
          case read.(kind, %{"key" => actor, "plain" => true}) do
            %{"fact" => %{"key" => ^actor}} -> :ok
            %{"fact" => nil} -> {:error, "forbidden"}
            _ -> {:error, "facts_unavailable"}
          end
        else
          {:error, "forbidden"}
        end

      _ ->
        {:error, "forbidden"}
    end
  end

  def authorize(_, _, _, _), do: {:error, "forbidden"}

  @doc """
  What the Workers page shows, from one read of the turns: `"running"`, the views of the
  turns whose state is the model's running value (as `worker_overview` returns them),
  newest activity first; and `"finished"`, the #{@finished} turns that ended most
  recently, newest end first, each with its exact execution, state, why it ended, when,
  and its item. A finished turn without a full execution identity cannot be opened and
  is left out.
  """
  def board(m, actor, read) do
    with :ok <- authorize(m, actor, "read", read),
         {:ok, n} <- names(m),
         {:ok, turns} <- turns(n, read),
         {:ok, running} <- running(m, actor, n, turns, read) do
      {:ok,
       %{
         "running" => Enum.sort_by(running, &recency(&1["lease_until"]), :desc),
         "finished" => finished(n, turns),
         "confirmed_at" => now()
       }}
    end
  end

  defp overview(m, actor, read) do
    with {:ok, n} <- names(m),
         {:ok, turns} <- turns(n, read),
         {:ok, rows} <- running(m, actor, n, turns, read) do
      {:ok, %{"workers" => rows, "confirmed_at" => now()}}
    end
  end

  defp turns(n, read) do
    case read.(n["kind"], %{"plain" => true}) do
      %{"facts" => turns} when is_list(turns) -> {:ok, turns}
      _ -> {:error, "facts_unavailable"}
    end
  end

  defp running(m, actor, n, turns, read) do
    # Each row is an exact execution. Never choose an arbitrary current turn
    # when two running facts claim the same worker.
    running = Enum.filter(turns, &(get_in(&1, ["values", n["state"]]) == n["running"]))

    if length(running) > 100 do
      {:error, "overview_too_large"}
    else
      Enum.reduce_while(Enum.sort_by(running, & &1["key"]), {:ok, []}, fn turn, {:ok, rows} ->
        case target_from_turn(n, turn) do
          {:ok, target} ->
            case inspect_execution(m, actor, target, read) do
              {:ok, view} -> {:cont, {:ok, [view | rows]}}
              {:error, error} -> {:halt, {:error, error}}
            end

          {:error, _} ->
            {:halt, {:error, "execution_unregistered"}}
        end
      end)
      |> case do
        {:ok, rows} -> {:ok, Enum.reverse(rows)}
        error -> error
      end
    end
  end

  # Read from the turn itself: a finished turn takes no guidance, so listing it needs
  # no execution record (opening it inspects that).
  defp finished(n, turns) do
    if filled?(n["ended"]) do
      for turn <- turns,
          get_in(turn, ["values", n["state"]]) == n["ended"],
          {:ok, target} <- [target_from_turn(n, turn)] do
        values = turn["values"] || %{}

        %{
          "execution" => %{
            "worker" => Map.take(target, ~w(environment machine worker)),
            "turn" => target["turn"],
            "attempt" => target["attempt"]
          },
          "state" => values[n["state"]],
          "reason" => values[n["why"]],
          "ended_at" => values[n["ended_at"]],
          "item" =>
            case get_in(turn, ["links", n["on"]]) do
              [key] -> key
              _ -> nil
            end
        }
      end
      |> Enum.sort_by(&{recency(&1["ended_at"]), &1["execution"]["turn"]}, :desc)
      |> Enum.take(@finished)
    else
      []
    end
  end

  # A timestamp as a sortable number; a missing or unreadable one sorts oldest.
  defp recency(value) do
    case DateTime.from_iso8601(to_string(value || "")) do
      {:ok, at, _} -> DateTime.to_unix(at, :microsecond)
      _ -> 0
    end
  end

  defp inspect_execution(m, actor, target, read) do
    with {:ok, view, _turn, _execution, _n} <- inspected(m, actor, target, read),
         do: {:ok, view}
  end

  @doc """
  What the worker page shows of `execution` (as `worker_inspect` takes it) besides its
  view: `{:ok, view, about}`, `about` with what a reader reads first, each nil when
  nothing says it: `"title"` (the turn's own, else its item's), `"status"` (running,
  finished, failed, stopped or ended), `"model"` (the turn's, else the execution's reported
  or configured one; never the placeholder `unknown`), `"started_at"` (when the execution
  was registered), `"ended_at"`, and `"newer"`: the newest other turn of the same worker
  that is newer than this one (running while this one ended, or ended after it), as
  `%{"execution", "status"}`.
  """
  def about(m, actor, execution, read) do
    with {:ok, %{"execution" => target}} <- handle_target(execution),
         :ok <- authorize(m, actor, "read", read),
         {:ok, view, turn, ex, n} <- inspected(m, actor, target, read) do
      values = turn["values"] || %{}

      {:ok, view,
       %{
         "title" => known(values[n["title"]]) || known(view["item_title"]),
         "status" => status(n, values),
         "model" =>
           Enum.find_value(
             [values[n["model"]], ex["reported_model"], ex["configured_model"]],
             &known/1
           ),
         "started_at" => known(ex["recorded_at"]),
         "ended_at" => known(values[n["ended_at"]]),
         "newer" => newer(n, turn, read)
       }}
    end
  end

  defp handle_target(%{"worker" => %{} = worker, "turn" => turn} = execution),
    do:
      {:ok,
       %{"execution" => Map.merge(worker, %{"turn" => turn, "attempt" => execution["attempt"]})}}

  defp handle_target(_), do: {:error, "invalid_target"}

  # A value worth showing: text that is neither empty nor the placeholder Runtime writes
  # for what it does not know.
  defp known(value) when is_binary(value) do
    if String.trim(value) in ["", "unknown"], do: nil, else: value
  end

  defp known(_), do: nil

  # The turn's state in plain words: the model's running value, or how it ended (the words
  # Runtime gives why: finished, failed: …, stopped or killed); any other end is "ended",
  # and a state that is neither is shown as it is.
  defp status(n, values) do
    why = to_string(values[n["why"]] || "")

    cond do
      values[n["state"]] == n["running"] -> "running"
      values[n["state"]] != n["ended"] or is_nil(n["ended"]) -> known(values[n["state"]])
      why == "finished" -> "finished"
      String.starts_with?(why, "failed") -> "failed"
      why in ["stopped", "killed"] -> "stopped"
      true -> "ended"
    end
  end

  # Among the worker's other turns: a running one when this one has ended (the most
  # recently renewed), else one that ended after this one (the latest).
  defp newer(n, turn, read) do
    with [worker] <- get_in(turn, ["links", n["by"]]),
         %{"facts" => turns} when is_list(turns) <-
           read.(n["kind"], %{"linked" => %{n["by"] => worker}, "plain" => true}) do
      values = turn["values"] || %{}
      ended = values[n["state"]] == n["ended"]
      own_end = recency(values[n["ended_at"]])

      others =
        for other <- turns,
            other["key"] != turn["key"],
            {:ok, target} <- [target_from_turn(n, other)],
            do: {other["values"] || %{}, target}

      running =
        for {v, target} <- others, ended and v[n["state"]] == n["running"], do: {v, target}

      later =
        for {v, target} <- others,
            ended and own_end > 0 and v[n["state"]] == n["ended"],
            recency(v[n["ended_at"]]) > own_end,
            do: {v, target}

      chosen =
        case running do
          [_ | _] ->
            Enum.max_by(running, fn {v, t} -> {recency(v[n["lease"]]), t["turn"]} end)

          [] when later != [] ->
            Enum.max_by(later, fn {v, t} -> {recency(v[n["ended_at"]]), t["turn"]} end)

          [] ->
            nil
        end

      case chosen do
        {v, target} ->
          %{
            "execution" => %{
              "worker" => Map.take(target, ~w(environment machine worker)),
              "turn" => target["turn"],
              "attempt" => target["attempt"]
            },
            "status" => status(n, v)
          }

        nil ->
          nil
      end
    else
      _ -> nil
    end
  end

  defp inspected(m, actor, target, read) do
    with {:ok, execution} <- execution(m, target, read),
         {:ok, n} <- names(m),
         {:ok, turn} <- fact(read, n["kind"], %{"key" => target["turn"], "plain" => true}),
         :ok <- matching_turn(n, turn, target) do
      eligibility = eligible(m, target, turn, execution, read)
      can_submit = authorize(m, actor, "submit", read) == :ok
      values = turn["values"] || %{}

      item =
        case get_in(turn, ["links", n["on"]]) do
          [key] -> key
          _ -> nil
        end

      item_view = item_view(m, n, item, read)

      {:ok,
       %{
         "execution" => %{
           "worker" => Map.take(target, ~w(environment machine worker)),
           "turn" => target["turn"],
           "attempt" => target["attempt"]
         },
         "descriptor" =>
           Map.take(
             execution,
             ~w(harness harness_version configured_model reported_model capability_version queued_input durable_accept_query consumption_evidence)
           ),
         "item" => item,
         "item_title" => item_view["title"],
         "item_to" => item_view["to"],
         "state" => values[n["state"]],
         "reason" => values[n["why"]],
         "activity" => values[n["activity"]],
         "lease_until" => values[n["lease"]],
         "outcome" => values[n["outcome"]],
         "confirmed_at" => now(),
         "guidance" => %{
           "available" => can_submit and eligibility == :ok,
           "reason" => if(can_submit, do: eligibility_reason(eligibility), else: "forbidden")
         }
       }, turn, execution, n}
    end
  end

  defp item_view(m, names, key, read) do
    with true <- is_binary(key),
         [kind] <- names["on_kinds"] || [],
         {:ok, item} <- fact(read, kind, %{"key" => key, "plain" => true}) do
      %{
        "title" => AtlasControl.Pages.label(AtlasControl.Pages.kind_view(m, kind), item),
        "to" => AtlasControl.Pages.path({:item, kind, key})
      }
    else
      _ -> %{}
    end
  end

  defp eligibility_reason(:ok), do: nil
  defp eligibility_reason({:error, reason}), do: reason

  defp submit(m, actor, request, read, write) do
    target = request["execution"]
    input = request["guidance"]

    with :ok <- valid_target(target),
         :ok <- valid_input(input),
         {:ok, ex} <- execution(m, target, read),
         {:ok, existing} <- lookup(m, actor, input["client_key"], read) do
      values =
        Map.take(target, ~w(worker turn attempt))
        |> Map.merge(input)
        |> Map.merge(%{"execution" => ex["key"], "mode" => "queued_guidance"})

      cond do
        existing != nil and not same_submission?(existing, values, actor) ->
          {:error, "immutable_conflict"}

        existing != nil ->
          {:ok, %{"interaction" => existing}}

        true ->
          with {:ok, n} <- names(m),
               {:ok, turn} <- fact(read, n["kind"], %{"key" => target["turn"], "plain" => true}),
               :ok <- eligible(m, target, turn, ex, read) do
            case write.(kind(m, "interaction"), %{
                   "op" => "submit_interaction",
                   "by" => actor.key,
                   "values" => values
                 }) do
              {:stored, %{"fact" => interaction}} ->
                if same_submission?(interaction, values, actor),
                  do: {:ok, %{"interaction" => interaction}},
                  else: {:error, "invalid_facts_reply"}

              {:refused, %{"code" => code}} when is_binary(code) ->
                {:error, code}

              _ ->
                # Timeout is not a negative acknowledgement. Query the SAME key.
                {:error, "outcome_unknown"}
            end
          end
      end
    end
  end

  defp query(m, actor, request, read) do
    with :ok <- valid_target(request["execution"]),
         {:ok, ex} <- execution(m, request["execution"], read),
         true <- filled?(request["client_key"]),
         {:ok, value} <- lookup(m, actor, request["client_key"], read) do
      cond do
        value == nil -> {:ok, %{"found" => false}}
        value["execution"] != ex["key"] -> {:error, "target_mismatch"}
        not exact?(value, request["execution"]) -> {:error, "target_mismatch"}
        true -> {:ok, %{"found" => true, "interaction" => value}}
      end
    else
      false -> {:error, "invalid_client_key"}
      error -> error
    end
  end

  defp history(m, actor, request, read) do
    with {:ok, ex} <- execution(m, request["execution"], read),
         {:ok, position} <- cursor(request["cursor"], actor, ex["key"], nil),
         {:ok, page} <-
           page(read, kind(m, "interaction"), %{
             "execution" => ex["key"],
             "after_position" => position
           }) do
      if Enum.all?(
           page["facts"],
           &(&1["execution"] == ex["key"] and exact?(&1, request["execution"]))
         ) do
        {:ok,
         %{
           "interactions" => page["facts"],
           "cursor" => next_cursor(page, actor, ex["key"], nil),
           "more" => page["more"]
         }}
      else
        {:error, "invalid_facts_reply"}
      end
    end
  end

  defp receipts(m, actor, request, read) do
    with {:ok, ex} <- execution(m, request["execution"], read),
         true <- filled?(request["interaction"]),
         {:ok, interaction} <-
           fact(read, kind(m, "interaction"), %{"key" => request["interaction"]}),
         true <-
           interaction["execution"] == ex["key"] and exact?(interaction, request["execution"]),
         {:ok, position} <- cursor(request["cursor"], actor, ex["key"], interaction["key"]),
         {:ok, page} <-
           page(read, kind(m, "receipt"), %{
             "interaction" => interaction["key"],
             "after_position" => position
           }) do
      if Enum.all?(
           page["facts"],
           &(&1["interaction"] == interaction["key"] and &1["execution"] == ex["key"] and
               exact?(&1, request["execution"]))
         ) do
        {:ok,
         %{
           "receipts" => page["facts"],
           "cursor" => next_cursor(page, actor, ex["key"], interaction["key"]),
           "more" => page["more"]
         }}
      else
        {:error, "invalid_facts_reply"}
      end
    else
      false -> {:error, "target_mismatch"}
      error -> error
    end
  end

  defp execution(m, target, read) do
    with :ok <- valid_target(target),
         {:ok, ex} <- fact(read, kind(m, "execution"), Map.take(target, ~w(turn attempt))),
         true <- Enum.all?(@identity, &(ex[&1] == target[&1])) do
      {:ok, ex}
    else
      false -> {:error, "target_mismatch"}
      error -> error
    end
  end

  defp matching_turn(n, turn, target) do
    if turn["key"] == target["turn"] and
         get_in(turn, ["values", n["machine"]]) == target["machine"] and
         get_in(turn, ["values", n["attempt"]]) == target["attempt"] and
         get_in(turn, ["links", n["by"]]) == [target["worker"]],
       do: :ok,
       else: {:error, "stale_execution"}
  end

  defp eligible(m, target, turn, ex, read) do
    with {:ok, n} <- names(m),
         true <- turn["key"] == target["turn"],
         true <- get_in(turn, ["values", n["machine"]]) == target["machine"],
         true <- get_in(turn, ["values", n["attempt"]]) == target["attempt"],
         true <- get_in(turn, ["links", n["by"]]) == [target["worker"]],
         true <- get_in(turn, ["values", n["state"]]) == n["running"],
         true <- get_in(turn, ["values", n["outcome"]]) in [nil, ""],
         {:ok, lease, _} <- DateTime.from_iso8601(get_in(turn, ["values", n["lease"]]) || ""),
         true <- DateTime.compare(lease, DateTime.utc_now()) == :gt,
         [item] <- get_in(turn, ["links", n["on"]]),
         [item_kind] <- n["on_kinds"] || [],
         {:ok, owned} <-
           fact(read, item_kind, %{"key" => item, "plain" => true, "presentation" => true}),
         :ok <- ownership(m, item_kind, owned, target["worker"]),
         %{"facts" => current} when is_list(current) <-
           read.(n["kind"], %{"linked" => %{n["by"] => target["worker"]}, "plain" => true}),
         [^turn] <- Enum.filter(current, &(get_in(&1, ["values", n["state"]]) == n["running"])) do
      if ex["capability_version"] == "1" and Enum.all?(@capabilities, &(ex[&1] == true)),
        do: :ok,
        else: {:error, "unsupported"}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      %{"error" => _} -> {:error, "facts_unavailable"}
      _ -> {:error, "stale_execution"}
    end
  end

  # The facts a turn works on are the model's (`turn/0` `items`); whether the worker owns
  # the work on one, something is to be done and no handover waits, Facts' presentation
  # of it says.
  defp ownership(m, kind, fact, worker) do
    shown = fact["presentation"] || %{}

    if Enum.any?((m.turn || %{})["items"] || [], &(&1["kind"] == kind)) and
         shown["owner"] == [worker] and shown["actionable"] == true and
         shown["handover"] == nil,
       do: :ok,
       else: {:error, "stale_execution"}
  end

  defp same_submission?(existing, values, actor),
    do:
      existing["environment"] == AtlasBus.environment() and existing["actor"] == actor.key and
        Enum.all?(values, fn {key, value} -> existing[key] == value end)

  defp exact?(value, target),
    do: Enum.all?(~w(environment worker turn attempt), &(value[&1] == target[&1]))

  defp lookup(m, actor, key, read) do
    case read.(kind(m, "interaction"), %{"actor" => actor.key, "client_key" => key}) do
      %{"fact" => %{} = fact} ->
        if fact["actor"] == actor.key and fact["client_key"] == key and
             fact["environment"] == AtlasBus.environment(),
           do: {:ok, fact},
           else: {:error, "invalid_facts_reply"}

      %{"fact" => nil} ->
        {:ok, nil}

      %{"code" => "not_found"} ->
        {:ok, nil}

      _ ->
        {:error, "facts_unavailable"}
    end
  end

  defp fact(read, kind, query) when is_binary(kind) do
    case read.(kind, query) do
      %{"fact" => %{} = fact} -> {:ok, fact}
      %{"fact" => nil} -> {:error, "not_found"}
      %{"code" => "not_found"} -> {:error, "not_found"}
      _ -> {:error, "facts_unavailable"}
    end
  end

  defp fact(_, _, _), do: {:error, "not_configured"}

  defp page(read, kind, query) do
    case read.(kind, Map.put(query, "limit", 50)) do
      %{"facts" => facts, "after_position" => position, "more" => more} = page
      when is_list(facts) and is_integer(position) and position >= 0 and is_boolean(more) ->
        if length(facts) <= 50 and (not more or position > query["after_position"]),
          do: {:ok, page},
          else: {:error, "invalid_facts_reply"}

      _ ->
        {:error, "facts_unavailable"}
    end
  end

  defp cursor(nil, _, _, _), do: {:ok, 0}

  defp cursor(value, actor, execution, interaction)
       when is_binary(value) and byte_size(value) <= 4096 do
    with {:ok, json} <- Base.url_decode64(value, padding: false),
         {:ok, [env, by, ^execution, ^interaction, position]} <- JSON.decode(json),
         true <- env == AtlasBus.environment() and by == actor.key,
         true <- is_integer(position) and position >= 0 do
      {:ok, position}
    else
      _ -> {:error, "invalid_cursor"}
    end
  end

  defp cursor(_, _, _, _), do: {:error, "invalid_cursor"}

  defp next_cursor(page, actor, execution, interaction),
    do:
      JSON.encode!([
        AtlasBus.environment(),
        actor.key,
        execution,
        interaction,
        page["after_position"]
      ])
      |> Base.url_encode64(padding: false)

  defp names(m) do
    case m.turn do
      %{} = names ->
        if Enum.all?(
             ~w(kind machine attempt by on state running lease outcome),
             &filled?(names[&1])
           ),
           do: {:ok, names},
           else: {:error, "not_configured"}

      _ ->
        {:error, "not_configured"}
    end
  end

  defp target_from_turn(n, turn) do
    with [worker] <- get_in(turn, ["links", n["by"]]) do
      target = %{
        "environment" => AtlasBus.environment(),
        "machine" => get_in(turn, ["values", n["machine"]]),
        "worker" => worker,
        "turn" => turn["key"],
        "attempt" => get_in(turn, ["values", n["attempt"]])
      }

      with :ok <- valid_target(target), do: {:ok, target}
    else
      _ -> {:error, "invalid_target"}
    end
  end

  defp valid_target(target) when is_map(target) do
    if Enum.sort(Map.keys(target)) == Enum.sort(@identity) and
         Enum.all?(@identity, &filled?(target[&1])) and
         target["environment"] == AtlasBus.environment(),
       do: :ok,
       else: {:error, "invalid_target"}
  end

  defp valid_target(_), do: {:error, "invalid_target"}

  defp valid_input(input) when is_map(input) do
    if Enum.sort(Map.keys(input)) == Enum.sort(@submission) and
         Enum.all?(@submission, &filled?(input[&1])) and byte_size(input["body"]) <= @max_body,
       do: :ok,
       else: {:error, "invalid_guidance"}
  end

  defp valid_input(_), do: {:error, "invalid_guidance"}

  defp filled?(value),
    do: is_binary(value) and String.trim(value) != "" and byte_size(value) <= 16_384

  defp kind(m, role), do: get_in(m.guidance || %{}, [role, "kind"])
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end

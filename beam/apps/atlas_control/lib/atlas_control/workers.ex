defmodule AtlasControl.Workers do
  @moduledoc """
  Worker snapshots and durable guidance through State reads/writes supplied by Control.
  No harness calls, viewer-owned workers or local interaction store live here.
  """

  @identity ~w(environment machine worker turn attempt)
  @capabilities ~w(queued_input durable_accept_query consumption_evidence)
  @submission ~w(client_key body cause)
  @max_body 16_384

  def handle(operation, request, description, actor, read, write) do
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

    with :ok <- authorize(description, actor, permission, read) do
      case operation do
        "worker_overview" ->
          overview(description, actor, read)

        "worker_inspect" ->
          with {:ok, view} <- inspect_execution(description, actor, request["execution"], read),
               do: {:ok, %{"view" => view}}

        "worker_submit" ->
          submit(description, actor, request, read, write)

        "worker_query" ->
          query(description, actor, request, read)

        "worker_history" ->
          history(description, actor, request, read)

        "worker_receipts" ->
          receipts(description, actor, request, read)

        _ ->
          {:error, "unsupported_operation"}
      end
    end
  end

  # Grants name admitted actors, separately for read and submit. Kind is resolved
  # from State only to verify the actor still exists, never as a blanket grant.
  def authorize(d, %{key: actor, kind: kind}, permission, read)
      when is_binary(actor) and is_binary(kind) do
    case get_in(d, ["guidance", "control", permission, "actors"]) do
      actors when is_list(actors) ->
        if Enum.all?(actors, &filled?/1) and actor in actors do
          case read.(kind, %{"key" => actor, "plain" => true}) do
            %{"fact" => %{"key" => ^actor}} -> :ok
            %{"fact" => nil} -> {:error, "forbidden"}
            _ -> {:error, "state_unavailable"}
          end
        else
          {:error, "forbidden"}
        end

      _ ->
        {:error, "forbidden"}
    end
  end

  def authorize(_, _, _, _), do: {:error, "forbidden"}

  defp overview(d, actor, read) do
    with {:ok, n} <- names(d),
         %{"facts" => turns} when is_list(turns) <- read.(n["kind"], %{"plain" => true}) do
      # Each row is an exact execution. Never choose an arbitrary current turn
      # when two running facts claim the same worker.
      running = Enum.filter(turns, &(get_in(&1, ["values", n["state"]]) == n["running"]))

      if length(running) > 100 do
        {:error, "overview_too_large"}
      else
        Enum.reduce_while(Enum.sort_by(running, & &1["key"]), {:ok, []}, fn turn, {:ok, rows} ->
          case target_from_turn(n, turn) do
            {:ok, target} ->
              case inspect_execution(d, actor, target, read) do
                {:ok, view} -> {:cont, {:ok, [view | rows]}}
                {:error, error} -> {:halt, {:error, error}}
              end

            {:error, _} ->
              {:halt, {:error, "execution_unregistered"}}
          end
        end)
        |> case do
          {:ok, rows} -> {:ok, %{"workers" => Enum.reverse(rows), "confirmed_at" => now()}}
          error -> error
        end
      end
    else
      {:error, _} = error -> error
      _ -> {:error, "state_unavailable"}
    end
  end

  defp inspect_execution(d, actor, target, read) do
    with {:ok, execution} <- execution(d, target, read),
         {:ok, n} <- names(d),
         {:ok, turn} <- fact(read, n["kind"], %{"key" => target["turn"], "plain" => true}),
         :ok <- matching_turn(n, turn, target) do
      eligibility = eligible(d, target, turn, execution, read)
      can_submit = authorize(d, actor, "submit", read) == :ok
      values = turn["values"] || %{}

      item =
        case get_in(turn, ["links", n["on"]]) do
          [key] -> key
          _ -> nil
        end

      item_view = item_view(d, n, item, read)

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
       }}
    end
  end

  defp item_view(d, names, key, read) do
    with true <- is_binary(key),
         [kind] <- get_in(d, ["relations", names["on"], "to"]),
         {:ok, item} <- fact(read, kind, %{"key" => key, "plain" => true}) do
      %{
        "title" => AtlasControl.Pages.label(d["entities"][kind] || %{}, item),
        "to" => AtlasControl.Pages.path({:item, kind, key})
      }
    else
      _ -> %{}
    end
  end

  defp eligibility_reason(:ok), do: nil
  defp eligibility_reason({:error, reason}), do: reason

  defp submit(d, actor, request, read, write) do
    target = request["execution"]
    input = request["guidance"]

    with :ok <- valid_target(target),
         :ok <- valid_input(input),
         {:ok, ex} <- execution(d, target, read),
         {:ok, existing} <- lookup(d, actor, input["client_key"], read) do
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
          with {:ok, n} <- names(d),
               {:ok, turn} <- fact(read, n["kind"], %{"key" => target["turn"], "plain" => true}),
               :ok <- eligible(d, target, turn, ex, read) do
            case write.(kind(d, "interaction"), %{
                   "op" => "submit_interaction",
                   "by" => actor.key,
                   "values" => values
                 }) do
              {:stored, %{"fact" => interaction}} ->
                if same_submission?(interaction, values, actor),
                  do: {:ok, %{"interaction" => interaction}},
                  else: {:error, "invalid_state_reply"}

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

  defp query(d, actor, request, read) do
    with :ok <- valid_target(request["execution"]),
         {:ok, ex} <- execution(d, request["execution"], read),
         true <- filled?(request["client_key"]),
         {:ok, value} <- lookup(d, actor, request["client_key"], read) do
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

  defp history(d, actor, request, read) do
    with {:ok, ex} <- execution(d, request["execution"], read),
         {:ok, position} <- cursor(request["cursor"], actor, ex["key"], nil),
         {:ok, page} <-
           page(read, kind(d, "interaction"), %{
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
        {:error, "invalid_state_reply"}
      end
    end
  end

  defp receipts(d, actor, request, read) do
    with {:ok, ex} <- execution(d, request["execution"], read),
         true <- filled?(request["interaction"]),
         {:ok, interaction} <-
           fact(read, kind(d, "interaction"), %{"key" => request["interaction"]}),
         true <-
           interaction["execution"] == ex["key"] and exact?(interaction, request["execution"]),
         {:ok, position} <- cursor(request["cursor"], actor, ex["key"], interaction["key"]),
         {:ok, page} <-
           page(read, kind(d, "receipt"), %{
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
        {:error, "invalid_state_reply"}
      end
    else
      false -> {:error, "target_mismatch"}
      error -> error
    end
  end

  defp execution(d, target, read) do
    with :ok <- valid_target(target),
         {:ok, ex} <- fact(read, kind(d, "execution"), Map.take(target, ~w(turn attempt))),
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

  defp eligible(d, target, turn, ex, read) do
    with {:ok, n} <- names(d),
         true <- turn["key"] == target["turn"],
         true <- get_in(turn, ["values", n["machine"]]) == target["machine"],
         true <- get_in(turn, ["values", n["attempt"]]) == target["attempt"],
         true <- get_in(turn, ["links", n["by"]]) == [target["worker"]],
         true <- get_in(turn, ["values", n["state"]]) == n["running"],
         true <- get_in(turn, ["values", n["outcome"]]) in [nil, ""],
         {:ok, lease, _} <- DateTime.from_iso8601(get_in(turn, ["values", n["lease"]]) || ""),
         true <- DateTime.compare(lease, DateTime.utc_now()) == :gt,
         [item] <- get_in(turn, ["links", n["on"]]),
         [item_kind] <- get_in(d, ["relations", n["on"], "to"]),
         {:ok, owned} <- fact(read, item_kind, %{"key" => item, "plain" => true}),
         :ok <- ownership(d, item_kind, owned, target["worker"]),
         %{"facts" => current} when is_list(current) <-
           read.(n["kind"], %{"linked" => %{n["by"] => target["worker"]}, "plain" => true}),
         [^turn] <- Enum.filter(current, &(get_in(&1, ["values", n["state"]]) == n["running"])) do
      if ex["capability_version"] == "1" and Enum.all?(@capabilities, &(ex[&1] == true)),
        do: :ok,
        else: {:error, "unsupported"}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      %{"error" => _} -> {:error, "state_unavailable"}
      _ -> {:error, "stale_execution"}
    end
  end

  defp ownership(d, kind, fact, worker) do
    flows =
      for {_name, flow} <- d["flows"] || %{},
          kind in if(flow["on"],
            do: get_in(d, ["relations", flow["on"], "to"]) || [],
            else: flow["kinds"] || []
          ),
          do: flow

    cond do
      flows == [] ->
        {:error, "stale_execution"}

      Enum.any?(flows, fn flow ->
        get_in(fact, ["links", flow["owner_relation"]]) == [worker] and
          (is_nil(flow["state_field"]) or
             get_in(fact, ["values", flow["state_field"]]) not in [nil, ""]) and
            (is_nil(flow["handover_field"]) or
               get_in(fact, ["values", flow["handover_field"]]) in [nil, ""])
      end) ->
        :ok

      true ->
        {:error, "stale_execution"}
    end
  end

  defp same_submission?(existing, values, actor),
    do:
      existing["environment"] == AtlasBus.environment() and existing["actor"] == actor.key and
        Enum.all?(values, fn {key, value} -> existing[key] == value end)

  defp exact?(value, target),
    do: Enum.all?(~w(environment worker turn attempt), &(value[&1] == target[&1]))

  defp lookup(d, actor, key, read) do
    case read.(kind(d, "interaction"), %{"actor" => actor.key, "client_key" => key}) do
      %{"fact" => %{} = fact} ->
        if fact["actor"] == actor.key and fact["client_key"] == key and
             fact["environment"] == AtlasBus.environment(),
           do: {:ok, fact},
           else: {:error, "invalid_state_reply"}

      %{"fact" => nil} ->
        {:ok, nil}

      %{"code" => "not_found"} ->
        {:ok, nil}

      _ ->
        {:error, "state_unavailable"}
    end
  end

  defp fact(read, kind, query) when is_binary(kind) do
    case read.(kind, query) do
      %{"fact" => %{} = fact} -> {:ok, fact}
      %{"fact" => nil} -> {:error, "not_found"}
      %{"code" => "not_found"} -> {:error, "not_found"}
      _ -> {:error, "state_unavailable"}
    end
  end

  defp fact(_, _, _), do: {:error, "not_configured"}

  defp page(read, kind, query) do
    case read.(kind, Map.put(query, "limit", 50)) do
      %{"facts" => facts, "after_position" => position, "more" => more} = page
      when is_list(facts) and is_integer(position) and position >= 0 and is_boolean(more) ->
        if length(facts) <= 50 and (not more or position > query["after_position"]),
          do: {:ok, page},
          else: {:error, "invalid_state_reply"}

      _ ->
        {:error, "state_unavailable"}
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

  defp names(d) do
    case get_in(d, ["runtime", "turn"]) do
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

  defp kind(d, role), do: get_in(d, ["guidance", role, "kind"])
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end

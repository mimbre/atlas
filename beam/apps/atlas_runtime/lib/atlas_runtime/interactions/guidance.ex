defmodule AtlasRuntime.Guidance do
  @moduledoc """
  Bounded exact-attempt reconciliation over State/Bus. State owns conversation history;
  this module keeps only a page cursor. Native query is authority for receipts, never
  chat, activity, or the contents of an event. Flow remains authority for ownership.

  Eligibility is a fresh snapshot, not a distributed transaction with an external port.
  Enabled ports must enforce the supplied deadline and serialize close against admission.
  Real ports remain unsupported pending their native durable evidence contracts.
  """
  alias AtlasRuntime.{Agent, Talk}

  def configured?(turn),
    do:
      is_binary(turn.names[:attempt]) and
        Enum.all?(~w(execution interaction receipt), &is_binary(kind(turn, &1)))

  def register(turn) do
    if configured?(turn) do
      descriptor =
        case Agent.describe(turn.port, context(turn), turn.port_opts) do
          {:ok, d} -> d
          _ -> %{}
        end

      supported = descriptor != %{} and Agent.runtime_input?(turn.port)

      values = %{
        "worker" => turn.agent,
        "turn" => turn.key,
        "attempt" => turn.attempt,
        "machine" => turn.machine,
        "harness" =>
          descriptor["harness"] || (turn.port_opts[:agent] || %{})["port"] || "unknown",
        "harness_version" => descriptor["harness_version"] || "unknown",
        "configured_model" =>
          descriptor["configured_model"] || (turn.port_opts[:agent] || %{})["model"] || "unknown",
        "capability_version" => descriptor["capability_version"] || "1",
        "queued_input" => supported,
        "durable_accept_query" => supported,
        "consumption_evidence" => supported
      }

      values =
        if descriptor["reported_model"],
          do: Map.put(values, "reported_model", descriptor["reported_model"]),
          else: values

      result =
        Talk.fact(
          kind(turn, "execution"),
          %{"op" => "register_execution", "values" => values},
          talk_opts(turn)
        )

      fact =
        case result do
          {:stored, %{"fact" => f}, _} ->
            f

          {:error, _} ->
            case read(turn, "execution", %{"turn" => turn.key, "attempt" => turn.attempt}) do
              %{"fact" => f} -> f
              _ -> nil
            end

          _ ->
            nil
        end

      if is_map(fact) and Map.take(fact, Map.keys(values)) == values and
           fact["environment"] == AtlasBus.environment(),
         do: {:ok, %{execution: fact, cursor: 0, supported: supported}},
         else: {:error, :execution_not_confirmed}
    else
      if Map.has_key?(turn[:description] || %{}, "guidance"),
        do: {:error, :invalid_guidance_mapping},
        else: {:ok, nil}
    end
  end

  def context(turn),
    do:
      Map.take(turn, [:key, :item, :kind, :agent, :attempt, :machine])
      |> Map.put(:environment, AtlasBus.environment())

  def round(turn, nil, _pid, _mode), do: {turn, nil}

  def round(turn, state, pid, mode) do
    case read(turn, "interaction", %{
           "execution" => state.execution["key"],
           "after_position" => state.cursor,
           "limit" => 1
         }) do
      %{"facts" => interactions, "after_position" => cursor, "more" => more} ->
        for i <- interactions, do: reconcile(turn, state, pid, mode, i)
        {turn, %{state | cursor: if(more, do: cursor, else: 0)}}

      _ ->
        {turn, state}
    end
  end

  def historical(turn, execution, cursor) do
    state = %{execution: execution, cursor: cursor, supported: execution["queued_input"] == true}

    if state.supported do
      original_context = Map.put(context(turn), :execution, execution)
      # Do not open a different/current binding as though it were the original one.
      result =
        with {:ok, descriptor} <- Agent.describe(turn.port, original_context, turn.port_opts),
             true <- compatible_descriptor?(turn, execution, descriptor) do
          Agent.recover_input(turn.port, original_context, turn.port_opts)
        else
          _ -> {:error, :uncertain}
        end

      case result do
        {:ok, pid} ->
          try do
            {_, next} = round(turn, state, pid, :closed)
            next.cursor
          after
            Agent.stop(turn.port, pid)
          end

        _ ->
          {_, next} = round(turn, state, nil, :uncertain)
          next.cursor
      end
    else
      {_, next} = round(turn, state, nil, :closed)
      next.cursor
    end
  end

  defp reconcile(turn, state, pid, mode, i) do
    identity = %{
      "environment" => AtlasBus.environment(),
      "worker" => turn.agent,
      "turn" => turn.key,
      "attempt" => turn.attempt,
      "interaction" => i["key"]
    }

    # Never trust a page/cached projection to substitute another target or execution.
    exact =
      i["environment"] == identity["environment"] and i["execution"] == state.execution["key"] and
        Enum.all?(~w(worker turn attempt), &(i[&1] == identity[&1]))

    if exact and get_in(i, ["projection", "proven"]) != "acknowledged" do
      cond do
        not state.supported ->
          receipt(turn, i, "unsupported", %{"reason" => "native_input_unsupported"})

        mode == :uncertain or not is_pid(pid) ->
          receipt(turn, i, "uncertain", %{"reason" => "native_history_unavailable"})

        not compatible?(turn, state.execution, pid) ->
          receipt(turn, i, "uncertain", %{"reason" => "capability_identity_changed"})

        true ->
          case Agent.query(turn.port, pid, identity) do
            {:ok, proof} ->
              evidence(turn, i, proof)

            {:not_admitted, ^identity} ->
              status = if mode == :closed, do: :closed, else: eligible(turn)

              case status do
                {:eligible, deadline} ->
                  # Existing closures cannot be undone by later ownership restoration.
                  if get_in(i, ["projection", "closures"]) in [nil, []] do
                    request = Map.merge(identity, Map.take(i, ~w(body mode)))

                    case Agent.accept(turn.port, pid, request, deadline) do
                      {:ok, proof} ->
                        evidence(turn, i, proof)

                        if not match?({:eligible, _}, eligible(turn)),
                          do:
                            receipt(turn, i, "uncertain", %{
                              "reason" => "eligibility_changed_during_admission"
                            })

                      {:error, :stale} ->
                        receipt(turn, i, "stale", %{"reason" => "admission_closed"})

                      {:error, :unsupported} ->
                        receipt(turn, i, "unsupported", %{"reason" => "native_input_unsupported"})

                      _ ->
                        receipt(turn, i, "uncertain", %{"reason" => "admission_unconfirmed"})
                    end
                  end

                :closed ->
                  receipt(turn, i, "stale", %{"reason" => "original_attempt_closed"})

                :paused ->
                  :ok

                :unknown ->
                  receipt(turn, i, "uncertain", %{"reason" => "eligibility_unavailable"})
              end

            _ ->
              receipt(turn, i, "uncertain", %{"reason" => "native_query_unconfirmed"})
          end
      end
    end
  end

  defp compatible?(turn, execution, pid) do
    case Agent.capabilities(turn.port, pid) do
      {:ok, d} -> compatible_descriptor?(turn, execution, d)
      _ -> false
    end
  end

  defp compatible_descriptor?(turn, execution, d) do
    identity = %{
      "environment" => AtlasBus.environment(),
      "machine" => turn.machine,
      "worker" => turn.agent,
      "turn" => turn.key,
      "attempt" => turn.attempt
    }

    Map.take(execution, Map.keys(identity)) == identity and
      Enum.all?(
        ~w(harness harness_version capability_version queued_input durable_accept_query consumption_evidence reported_model),
        &(execution[&1] == d[&1])
      ) and
      execution["configured_model"] ==
        (d["configured_model"] || (turn.port_opts[:agent] || %{})["model"] || "unknown")
  end

  def eligible(turn) do
    n = turn.names
    now = System.system_time(:millisecond)

    cond do
      turn[:leaving] != nil or now >= turn.since + turn.max or now >= turn.active + turn.silence ->
        :closed

      true ->
        with %{"fact" => %{"values" => v, "links" => links}} <-
               Talk.read(turn.turn_kind, %{"key" => turn.key, "plain" => true}, talk_opts(turn)),
             %{"fact" => %{"values" => iv, "links" => il}} <-
               Talk.read(turn.kind, %{"key" => turn.item, "plain" => true}, talk_opts(turn)) do
          flow = turn.ownership

          cond do
            v[n.state] != n.running or v[n.machine] != turn.machine or
              v[n.attempt] != turn.attempt or
              links[n.by] != [turn.agent] or links[n.on] != [turn.item] or
              (n.outcome && v[n.outcome] not in [nil, ""]) or
              il[flow["owner_relation"]] != [turn.agent] or
                (flow["state_field"] && iv[flow["state_field"]] in [nil, ""]) ->
              :closed

            flow["handover_field"] && iv[flow["handover_field"]] not in [nil, ""] ->
              :paused

            true ->
              case DateTime.from_iso8601(v[n.lease] || "") do
                {:ok, lease, _} ->
                  deadline =
                    Enum.min([
                      DateTime.to_unix(lease, :millisecond),
                      turn.since + turn.max,
                      turn.active + turn.silence
                    ])

                  if System.system_time(:millisecond) < deadline,
                    do: {:eligible, deadline},
                    else: :closed

                _ ->
                  :unknown
              end
          end
        else
          %{"fact" => nil} -> :closed
          _ -> :unknown
        end
    end
  end

  defp evidence(turn, i, proof) do
    fields = Map.take(proof, ~w(admission_id))
    receipt(turn, i, "delivered", fields)

    if proof["stage"] == "consumed",
      do:
        receipt(
          turn,
          i,
          "acknowledged",
          Map.put(fields, "consumption_id", proof["consumption_id"])
        )
  end

  defp receipt(turn, i, stage, extra) do
    # Stable immutable evidence ids make lost State acknowledgements safe to reconcile.
    id =
      :crypto.hash(
        :sha256,
        JSON.encode!([i["key"], stage, Enum.sort(extra) |> Enum.map(fn {k, v} -> [k, v] end)])
      )
      |> Base.url_encode64(padding: false)

    values =
      Map.take(i, ~w(worker turn attempt execution))
      |> Map.merge(extra)
      |> Map.merge(%{
        "interaction" => i["key"],
        "stage" => stage,
        "evidence_id" => id,
        "cause" => "Runtime exact-attempt reconciliation"
      })

    Talk.fact(
      kind(turn, "receipt"),
      %{"op" => "record_receipt", "values" => values},
      talk_opts(turn)
    )
  end

  defp read(turn, role, query), do: Talk.read(kind(turn, role), query, talk_opts(turn))
  defp kind(turn, role), do: get_in(turn[:description] || %{}, ["guidance", role, "kind"])
  defp talk_opts(turn), do: turn[:talk_opts] || []
end

defmodule AtlasTui.WorkerHistory do
  @moduledoc "Exact-execution, explicitly paged durable interaction and receipt reads."

  alias AtlasBFFContract.Wire.Control.Workers.Protocol, as: Wire
  alias AtlasTui.Blocks

  defstruct execution: nil,
            execution_key: nil,
            interactions: [],
            loaded: false,
            cursor: nil,
            more: false,
            receipt_pages: %{},
            pending: %{},
            errors: %{},
            stale: MapSet.new(),
            namespace: nil,
            sequence: 0,
            valid: false

  def new(execution) do
    normalized = normalize(execution)
    valid = exact_execution?(normalized)

    %__MODULE__{
      execution: normalized,
      valid: valid,
      namespace: "worker-history-#{System.unique_integer([:positive, :monotonic])}",
      errors:
        if(valid, do: %{}, else: %{history: "Exact execution unavailable; no history requested."})
    }
  end

  def load(%{loaded: true} = state), do: {state, []}
  def load(state), do: request(state, :history, nil, false)

  def next(%{loaded: true, more: true} = state),
    do: request(state, :history, state.cursor, false)

  def next(state), do: {state, []}

  # Refresh the first bounded page and, when it cannot describe a previously
  # exhausted frontier, probe that frontier once. Older projections stay stale.
  def refresh(state) do
    receipt_pages =
      Map.new(state.receipt_pages, fn {key, page} -> {key, %{page | stale: true}} end)

    state = %{state | pending: %{}, stale: interaction_keys(state), receipt_pages: receipt_pages}
    request(state, :history, nil, true)
  end

  # Repeated user-directed calls advance this interaction's receipt cursor only.
  def receipts(state, interaction_key) do
    if Enum.any?(state.interactions, &(&1["key"] == interaction_key)) do
      page = Map.get(state.receipt_pages, interaction_key, empty_page())

      if page.loaded and not page.more and not page.stale do
        {state, []}
      else
        cursor = if page.stale and not page.more, do: nil, else: page.cursor
        request(state, {:receipts, interaction_key}, cursor, false)
      end
    else
      {state, []}
    end
  end

  def receive(state, %{"id" => id, "op" => op} = message) do
    case Map.get(state.pending, id) do
      nil ->
        {state, []}

      request ->
        name = Atom.to_string(request.operation)

        if op in [name <> "_result", name <> "_error"] do
          case Wire.decode_reply(request.operation, message) do
            {:ok, :result, reply} -> complete(state, id, request, reply)
            {:ok, :error, reply} -> fail(state, id, request.scope, error_text(reply["error"]))
            {:invalid, reason} -> fail(state, id, request.scope, "Invalid response: #{reason}")
          end
        else
          {state, []}
        end
    end
  end

  def receive(state, _message), do: {state, []}

  def blocks(state) do
    [item("worker-history-status", "Durable guidance history", history_status(state))] ++
      Enum.flat_map(state.interactions, fn interaction ->
        key = interaction["key"]
        projection = interaction["projection"]

        fields =
          record_fields(
            interaction,
            ~w(body actor key client_key body_digest environment worker turn attempt execution mode cause recorded_at recorded_position receipt_count)
          ) ++
            [
              {"projection.proven", projection["proven"]},
              {"projection.uncertain", to_string(projection["uncertain"])},
              {"projection.closures", JSON.encode!(projection["closures"])},
              {"Projection freshness",
               if(MapSet.member?(state.stale, key),
                 do: "Stale: last known projection",
                 else: "Last fetched projection"
               )}
            ]

        title = interaction["actor"] <> " — recorded projection: " <> projection["proven"]
        title = if projection["uncertain"], do: title <> " (uncertain)", else: title

        [item("worker-history-interaction:" <> key, title, fields)] ++
          receipt_blocks(state, key)
      end)
  end

  defp request(%{valid: false} = state, _scope, _cursor, _refresh), do: {state, []}

  defp request(state, scope, cursor, refresh) do
    if Enum.any?(state.pending, fn {_id, pending} -> pending.scope == scope end) do
      {state, []}
    else
      sequence = state.sequence + 1
      id = "#{state.namespace}:#{sequence}"
      operation = if scope == :history, do: :worker_history, else: :worker_receipts
      props = %{id: id, execution: state.execution, cursor: cursor}

      props =
        case scope do
          :history -> props
          {:receipts, key} -> Map.put(props, :interaction, key)
        end

      wire = Wire.request(operation, props)
      pending = %{scope: scope, operation: operation, cursor: cursor, refresh: refresh}

      {%{state | sequence: sequence, pending: Map.put(state.pending, id, pending)}, [wire]}
    end
  end

  defp complete(state, id, %{scope: :history} = request, reply) do
    records = reply["interactions"]

    if valid_records?(state, records, nil) and
         compatible?(state.interactions, records, ~w(projection receipt_count)) and
         advancing?(request, reply) do
      preserve_frontier = request.refresh and state.loaded and reply["more"]
      probe_frontier = preserve_frontier and not state.more
      interactions = merge_records(state.interactions, records)
      stale = Enum.reduce(records, state.stale, &MapSet.delete(&2, &1["key"]))

      state = %{
        state
        | interactions: interactions,
          loaded: true,
          cursor: if(preserve_frontier, do: state.cursor, else: reply["cursor"]),
          more: if(preserve_frontier, do: state.more, else: reply["more"]),
          execution_key: execution_key(state, records),
          pending: Map.delete(state.pending, id),
          errors: Map.delete(state.errors, :history),
          stale: stale
      }

      # A first-page continuation says nothing about records after a previously
      # exhausted frontier. Probe that frontier once, never drain further pages.
      if probe_frontier do
        request(state, :history, state.cursor, false)
      else
        {state, []}
      end
    else
      fail(
        state,
        id,
        :history,
        "History unavailable: response does not match the exact execution or recorded facts."
      )
    end
  end

  defp complete(state, id, %{scope: {:receipts, key}} = request, reply) do
    records = reply["receipts"]
    page = Map.get(state.receipt_pages, key, empty_page())

    if valid_records?(state, records, key) and compatible?(page.receipts, records, []) and
         advancing?(request, reply) do
      page = %{
        page
        | receipts: merge_records(page.receipts, records),
          loaded: true,
          cursor: reply["cursor"],
          more: reply["more"],
          stale: false
      }

      {%{
         state
         | receipt_pages: Map.put(state.receipt_pages, key, page),
           pending: Map.delete(state.pending, id),
           errors: Map.delete(state.errors, request.scope)
       }, []}
    else
      fail(
        state,
        id,
        request.scope,
        "Receipts unavailable: response does not match the exact interaction or recorded facts."
      )
    end
  end

  defp fail(state, id, scope, reason) do
    state = %{
      state
      | pending: Map.delete(state.pending, id),
        errors: Map.put(state.errors, scope, reason)
    }

    state =
      case scope do
        :history ->
          %{state | stale: interaction_keys(state)}

        {:receipts, key} ->
          page = Map.get(state.receipt_pages, key, empty_page())
          %{state | receipt_pages: Map.put(state.receipt_pages, key, %{page | stale: true})}
      end

    {state, []}
  end

  defp valid_records?(state, records, interaction) do
    keys = Enum.map(records, & &1["execution"]) |> Enum.uniq()

    length(keys) <= 1 and
      Enum.all?(records, fn record ->
        record["environment"] == state.execution["worker"]["environment"] and
          record["worker"] == state.execution["worker"]["worker"] and
          record["turn"] == state.execution["turn"] and
          record["attempt"] == state.execution["attempt"] and
          filled?(record["key"]) and filled?(record["execution"]) and
          (is_nil(state.execution_key) or record["execution"] == state.execution_key) and
          (is_nil(interaction) or record["interaction"] == interaction)
      end)
  end

  defp compatible?(old, incoming, mutable) do
    known = Map.new(old, &{&1["key"], Map.drop(&1, mutable)})

    Enum.reduce_while(incoming, known, fn record, seen ->
      immutable = Map.drop(record, mutable)

      case Map.fetch(seen, record["key"]) do
        {:ok, existing} when existing != immutable -> {:halt, false}
        _ -> {:cont, Map.put(seen, record["key"], immutable)}
      end
    end) != false
  end

  defp advancing?(request, reply),
    do: not reply["more"] or (filled?(reply["cursor"]) and reply["cursor"] != request.cursor)

  defp merge_records(old, incoming) do
    Map.new(old, &{&1["key"], &1})
    |> Map.merge(Map.new(incoming, &{&1["key"], &1}))
    |> Map.values()
    |> Enum.sort_by(&{&1["recorded_position"], &1["key"]})
  end

  defp execution_key(%{execution_key: key}, _records) when not is_nil(key), do: key
  defp execution_key(_state, [record | _]), do: record["execution"]
  defp execution_key(_state, []), do: nil
  defp interaction_keys(state), do: MapSet.new(state.interactions, & &1["key"])
  defp empty_page, do: %{receipts: [], loaded: false, cursor: nil, more: false, stale: false}

  defp normalize(execution) do
    Wire.model(:runtime_execution, execution)
  rescue
    ArgumentError -> nil
  end

  defp exact_execution?(%{"worker" => worker, "turn" => turn, "attempt" => attempt}),
    do:
      Enum.all?(
        [worker["environment"], worker["machine"], worker["worker"], turn, attempt],
        &filled?/1
      )

  defp exact_execution?(_), do: false
  defp filled?(value), do: is_binary(value) and byte_size(value) > 0

  defp history_status(state) do
    status =
      cond do
        Map.has_key?(state.errors, :history) ->
          "Unavailable; last known data retained where present"

        pending?(state, :history) ->
          "Loading one history page"

        not state.loaded ->
          "History not loaded"

        state.interactions == [] ->
          "No recorded interactions in the loaded history"

        true ->
          "Loaded recorded interactions"
      end

    [{"Status", status}, {"Loaded interactions", to_string(length(state.interactions))}] ++
      if(state.loaded,
        do: [
          {"Pagination",
           if(state.more,
             do: "More history pages available; not fetched automatically",
             else: "End of history at last fetch"
           )}
        ],
        else: []
      ) ++
      error_fields(state, :history)
  end

  defp receipt_blocks(state, key) do
    scope = {:receipts, key}

    case Map.get(state.receipt_pages, key) do
      nil ->
        if pending?(state, scope),
          do: [
            item("worker-history-receipts:" <> key, "Recorded receipts", [
              {"Status", "Loading one receipt page"}
            ])
          ],
          else: []

      page ->
        status =
          cond do
            page.stale and page.loaded -> "Stale: last known receipt evidence"
            pending?(state, scope) -> "Loading one receipt page"
            not page.loaded -> "Receipts unavailable"
            page.receipts == [] -> "No recorded receipts in the loaded page"
            true -> "Recorded receipt evidence"
          end

        pagination =
          if page.loaded,
            do: [
              {"Pagination",
               if(page.more,
                 do: "More receipt pages available; not fetched automatically",
                 else: "End of receipts at last fetch"
               )}
            ],
            else: []

        [
          item(
            "worker-history-receipts:" <> key,
            "Recorded receipts",
            [{"Status", status}] ++ pagination ++ error_fields(state, scope)
          )
        ] ++
          Enum.map(page.receipts, fn receipt ->
            item(
              "worker-history-receipt:" <> receipt["key"],
              "Recorded receipt",
              record_fields(
                receipt,
                ~w(key interaction environment worker turn attempt execution stage evidence_id cause writer recorded_at recorded_position admission_id consumption_id reason)
              )
            )
          end)
    end
  end

  defp pending?(state, scope),
    do: Enum.any?(state.pending, fn {_id, request} -> request.scope == scope end)

  defp error_fields(state, scope),
    do: if(Map.has_key?(state.errors, scope), do: [{"Error", state.errors[scope]}], else: [])

  defp error_text(error),
    do: "#{error["code"]}: #{error["message"]} (retryable: #{error["retryable"]})"

  defp record_fields(record, fields),
    do: for(field <- fields, Map.has_key?(record, field), do: {field, to_string(record[field])})

  defp item(id, title, fields) do
    block =
      Blocks.decode(%{
        "type" => "item",
        "props" => %{
          "title" => title,
          "fields" =>
            Enum.map(fields, fn {label, value} -> %{"label" => label, "value" => value} end)
        }
      })

    {id, block}
  end
end

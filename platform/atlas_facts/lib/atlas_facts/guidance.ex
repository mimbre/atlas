defmodule AtlasFacts.Guidance do
  @moduledoc """
  Immutable execution, interaction and receipt operations, selected by description.

  Facts is the sole write authority. A deterministic identity is claimed with the
  backend's create-if-absent, never a client-side lookup/registry. On an existing
  identity the complete immutable payload is compared, not just its digest.
  Recovered creates retain the original server timestamp. Receipts are append-only;
  projections are rebuilt from evidence and never persisted as mutable status.

  Control is an admitted identity boundary (as for existing Control clients): only
  a Control session may assert `by`. Runtime endpoints are bound to machines by the
  Bus link. Receipt fields cannot substitute for that authenticated envelope sender.
  """
  alias AtlasFacts.{Description, Rela}

  @roles ~w(execution interaction receipt)
  @execution ~w(worker turn attempt machine harness harness_version configured_model capability_version queued_input durable_accept_query consumption_evidence)
  @interaction ~w(client_key body worker turn attempt mode execution cause)
  @receipt ~w(interaction worker turn attempt execution stage evidence_id cause)
  @stages ~w(delivered acknowledged uncertain stale unsupported rejected)
  @record_bytes %{"execution" => 8_192, "interaction" => 32_768, "receipt" => 8_192}
  @page_bytes 65_536
  @page_limit 100

  def role(description, kind) do
    Enum.find(@roles, &(get_in(description, ["guidance", &1, "kind"]) == kind))
  end

  def write(rela, description, role, envelope, content, next_position) when is_map(content) do
    with true <- envelope.environment == AtlasBus.environment(),
         {:ok, values} <- operation(rela, description, role, envelope, content),
         {:ok, fact} <- immutable(rela, description, role, values, next_position),
         {:ok, view} <- view(rela, description, role, fact) do
      {:ok, view}
    else
      false -> {:error, :wrong_environment}
      error -> error
    end
  end

  def write(_rela, _description, _role, _envelope, _content, _next_position),
    do: {:error, :invalid_operation}

  def read(rela, description, role, content) when is_map(content) do
    collection = plural(description, role)

    case content do
      %{"key" => key} when is_binary(key) ->
        with {:ok, fact} <- Rela.get(rela, collection, key),
             {:ok, view} <- view(rela, description, role, fact) do
          {:ok, %{"fact" => view}}
        end

      %{"actor" => actor, "client_key" => client_key} when role == "interaction" ->
        read(rela, description, role, %{
          "key" => identity(["interaction", AtlasBus.environment(), actor, client_key])
        })

      %{"turn" => turn, "attempt" => attempt}
      when role == "execution" and is_binary(turn) and is_binary(attempt) and
             turn != "" and attempt != "" ->
        read(rela, description, role, %{
          "key" => identity(["execution", AtlasBus.environment(), turn, attempt])
        })

      %{"execution" => execution} when role == "interaction" and is_binary(execution) ->
        read_page(rela, description, role, {"execution", execution}, content)

      %{"interaction" => interaction} when role == "receipt" and is_binary(interaction) ->
        with {:ok, parent} <- fetch(rela, description, "interaction", interaction),
             true <- parent["environment"] == AtlasBus.environment() do
          read_page(rela, description, role, {"interaction", interaction}, content)
        else
          false -> {:error, :wrong_environment}
          error -> error
        end

      _ ->
        {:error, :exact_identity_required}
    end
  end

  def read(_, _, _, _), do: {:error, :invalid_operation}

  defp read_page(rela, d, role, {field, key}, content) do
    after_position = Map.get(content, "after_position", 0)
    limit = Map.get(content, "limit", @page_limit)

    if is_integer(after_position) and after_position >= 0 and is_integer(limit) and
         limit in 1..@page_limit do
      with {:ok, facts} <- Rela.list(rela, plural(d, role)) do
        selected =
          facts
          |> Enum.filter(fn fact ->
            value = decode(d, role, fact)

            value["environment"] == AtlasBus.environment() and value[field] == key and
              value["recorded_position"] > after_position
          end)
          |> Enum.sort_by(&decode(d, role, &1)["recorded_position"])

        extra = if role == "receipt", do: %{"interaction" => key}, else: %{}
        page(selected, limit, after_position, [], extra, fn fact -> view(rela, d, role, fact) end)
      end
    else
      {:error, :invalid_page}
    end
  end

  defp page([], _limit, position, values, extra, _render),
    do: {:ok, page_content(values, position, false, extra)}

  defp page(_rest, 0, position, values, extra, _render),
    do: {:ok, page_content(values, position, true, extra)}

  defp page([fact | rest], limit, position, values, extra, render) do
    with {:ok, value} <- render.(fact) do
      next = values ++ [value]
      next_position = value["recorded_position"]
      # false is one byte longer than true, so reserve the larger representation.
      if byte_size(JSON.encode!(page_content(next, next_position, false, extra))) <= @page_bytes do
        page(rest, limit - 1, next_position, next, extra, render)
      else
        if values == [],
          do: {:error, :record_too_large},
          else: {:ok, page_content(values, position, true, extra)}
      end
    end
  end

  defp page_content(values, position, more, extra),
    do: Map.merge(extra, %{"facts" => values, "after_position" => position, "more" => more})

  @doc "Protect the authority of fenced turns, including attempts introduced by this protocol."
  def authorize_turn(rela, d, e, content) do
    turn = get_in(d, ["runtime", "turn"])

    if is_map(turn) and is_binary(turn["attempt"]) and e.kind == turn["kind"] and is_map(content) do
      authorize_fenced_turn(rela, d, e, content, turn)
    else
      :ok
    end
  end

  defp authorize_fenced_turn(rela, d, e, content, turn) do
    op = content["op"]

    with key when is_binary(key) <- content["key"],
         values when is_map(values) <- content["values"] || %{},
         {:ok, fact} <- existing_turn(rela, d, turn, key, op) do
      existing = fact.properties
      fenced = Map.has_key?(values, turn["attempt"]) or Map.has_key?(existing, turn["attempt"])
      machine = existing[turn["machine"]] || values[turn["machine"]]

      unchanged_fence =
        not Map.has_key?(existing, turn["attempt"]) or
          Enum.all?([turn["attempt"], turn["machine"]], fn field ->
            not Map.has_key?(values, field) or values[field] == existing[field]
          end)

      outcome_only =
        content["op"] == "change" and Map.keys(values) == [turn["outcome"]] and
          (content["links"] || %{}) == %{} and is_binary(e.sender) and
          String.starts_with?(e.sender, "control/session-")

      if not fenced or
           (unchanged_fence and (runtime?(e.sender, machine, content["key"]) or outcome_only)),
         do: if(op == "delete", do: {:delete, deletion_target(d, fact)}, else: :ok),
         else: {:error, :turn_authority}
    else
      {:error, :not_found} when op == "delete" -> :absent_delete
      {:error, _} = error -> error
      _ -> {:error, :invalid_operation}
    end
  end

  # Only confirmed absence is an absent fact. A timeout/503 must never erase a
  # previously established fence and then fall through to an ordinary PATCH/DELETE.
  defp existing_turn(rela, d, turn, key, op) do
    case Rela.get(rela, kind_plural(d, turn["kind"]), key) do
      {:ok, fact} -> {:ok, fact}
      {:error, :not_found} when op == "create" -> {:ok, %{properties: %{}, version: nil}}
      {:error, _} = error -> error
    end
  end

  @doc "The incarnation authorized for deletion, independent of a later absence."
  def deletion_target(d, fact) do
    turn = d["runtime"]["turn"]

    %{
      machine: fact.properties[turn["machine"]],
      attempt: fact.properties[turn["attempt"]],
      version: fact[:version]
    }
  end

  defp operation(rela, d, "execution", e, %{"op" => "register_execution", "values" => v})
       when is_map(v) do
    turn = d["runtime"]["turn"]

    with :ok <- shape(v, @execution, ~w(reported_model)),
         true <- runtime?(e.sender, v["machine"], v["turn"]),
         true <-
           Enum.all?(
             ~w(queued_input durable_accept_query consumption_evidence),
             &is_boolean(v[&1])
           ),
         {:ok, fact} <- Rela.get(rela, kind_plural(d, turn["kind"]), v["turn"]),
         true <- fact.properties[turn["machine"]] == v["machine"],
         true <- fact.properties[turn["attempt"]] == v["attempt"],
         true <- v["worker"] in Map.get(fact.links, turn["by"], []),
         true <- fact.properties[turn["state"]] == turn["running"] do
      {:ok, Map.put(v, "environment", e.environment)}
    else
      false -> {:error, :execution_authority}
      error -> error
    end
  end

  defp operation(rela, d, "interaction", e, %{
         "op" => "submit_interaction",
         "by" => actor,
         "values" => v
       })
       when is_map(v) and is_binary(actor) and actor != "" do
    with :ok <- shape(v, @interaction, []),
         true <- is_binary(e.sender) and String.starts_with?(e.sender, "control/session-"),
         values =
           v
           |> Map.put("actor", actor)
           |> Map.put("environment", e.environment)
           |> Map.put("body_digest", digest(v["body"])),
         :ok <- replay_payload(rela, d, "interaction", values),
         true <- v["mode"] == "queued_guidance",
         {:ok, execution} <- fetch(rela, d, "execution", v["execution"]),
         true <- target?(v, execution),
         true <- execution["environment"] == e.environment,
         :ok <- capable(execution) do
      # Persistence reserves no turn; admission eligibility is Runtime's responsibility.
      {:ok, values}
    else
      false -> {:error, :interaction_authority}
      error -> error
    end
  end

  defp operation(rela, d, "receipt", e, %{"op" => "record_receipt", "values" => v})
       when is_map(v) do
    with :ok <- shape(v, @receipt, ~w(admission_id consumption_id reason)),
         true <- v["stage"] in @stages,
         {:ok, interaction} <- fetch(rela, d, "interaction", v["interaction"]),
         {:ok, execution} <- fetch(rela, d, "execution", interaction["execution"]),
         true <- target?(v, interaction) and v["execution"] == interaction["execution"],
         true <- e.environment == interaction["environment"],
         true <- runtime?(e.sender, execution["machine"], interaction["turn"]),
         :ok <- evidence(v) do
      {:ok,
       v
       |> Map.put("environment", e.environment)
       |> Map.put("writer", "runtime@" <> execution["machine"])}
    else
      false -> {:error, :receipt_authority}
      error -> error
    end
  end

  defp operation(_, _, _, _, _), do: {:error, :protected_operation_required}

  defp replay_payload(rela, d, role, values) do
    case fetch(rela, d, role, key(role, values)) do
      {:error, :not_found} ->
        :ok

      {:ok, existing} ->
        if Map.drop(existing, ["key", "recorded_at", "recorded_position"]) == values,
          do: :ok,
          else: {:error, :immutable_conflict}

      error ->
        error
    end
  end

  defp capable(execution) do
    if Enum.all?(
         ~w(queued_input durable_accept_query consumption_evidence),
         &(execution[&1] == true)
       ),
       do: :ok,
       else: {:error, :unsupported}
  end

  defp evidence(%{"stage" => "acknowledged"} = v) do
    if filled?(v["admission_id"]) and filled?(v["consumption_id"]),
      do: :ok,
      else: {:error, :consumption_evidence_required}
  end

  defp evidence(%{"stage" => "delivered"} = v) do
    if filled?(v["admission_id"]), do: :ok, else: {:error, :admission_evidence_required}
  end

  defp evidence(v) do
    if filled?(v["reason"]), do: :ok, else: {:error, :reason_required}
  end

  # Restricted to the exact turn endpoint or its owning machine's reconciler.
  defp runtime?(sender, machine, turn)
       when is_binary(machine) and is_binary(sender) and is_binary(turn),
       do: sender == "runtime@" <> machine or sender == "runtime@" <> machine <> "/" <> turn

  defp runtime?(_, _, _), do: false

  defp target?(a, b), do: Enum.all?(~w(worker turn attempt), &(a[&1] == b[&1]))

  defp shape(values, required, optional) do
    cond do
      Map.keys(values) -- (required ++ optional) != [] ->
        {:error, :unknown_fields}

      Enum.any?(required, &(not filled?(values[&1]))) ->
        {:error, :required_fields}

      Enum.any?(values, fn {slot, v} ->
        if slot in ~w(queued_input durable_accept_query consumption_evidence),
          do: not is_boolean(v),
          else: not is_binary(v)
      end) ->
        {:error, :invalid_fields}

      true ->
        :ok
    end
  end

  defp filled?(v), do: is_boolean(v) or (is_binary(v) and String.trim(v) != "")

  defp immutable(rela, d, role, values, next_position) do
    key = key(role, values)
    mapping = get_in(d, ["guidance", role, "fields"])

    values =
      values
      |> Map.put("recorded_at", DateTime.utc_now() |> DateTime.to_iso8601())
      |> Map.put("recorded_position", next_position.())

    props = Map.new(values, fn {k, v} -> {Map.fetch!(mapping, k), v} end)
    spec = Description.kind(d, get_in(d, ["guidance", role, "kind"]))

    generated = [mapping["recorded_at"], mapping["recorded_position"]]

    with :ok <- Description.check(spec, props, :create) do
      case {record_size(role, Map.put(values, "key", key)),
            record_size(role, Map.put(props, "key", key))} do
        {:ok, :ok} ->
          claim(rela, spec["plural"], key, props, generated)

        _ ->
          # A valid original may sit exactly on its byte boundary. Later clock/
          # position metadata is irrelevant to replay and must not reject it.
          case compare(rela, spec["plural"], key, props, generated) do
            {:error, :not_found} -> {:error, :record_too_large}
            result -> result
          end
      end
    end
  end

  defp claim(rela, plural, key, props, generated) do
    # Atomic create is the identity claim; existing keys are never overwritten.
    case Rela.create(rela, plural, key, props, %{}) do
      {:ok, []} -> Rela.get(rela, plural, key)
      {:error, :exists} -> compare(rela, plural, key, props, generated)
      {:ok, warnings} -> {:error, {:stored_with_warnings, warnings}}
      error -> error
    end
  end

  defp compare(rela, plural, key, props, generated) do
    with {:ok, fact} <- Rela.get(rela, plural, key) do
      if Map.drop(fact.properties, generated) == Map.drop(props, generated),
        do: {:ok, fact},
        else: {:error, :immutable_conflict}
    end
  end

  defp key("execution", v), do: identity(["execution", v["environment"], v["turn"], v["attempt"]])

  defp key("interaction", v),
    do: identity(["interaction", v["environment"], v["actor"], v["client_key"]])

  defp key("receipt", v),
    do: identity(["receipt", v["environment"], v["interaction"], v["evidence_id"]])

  # Length-delimited JSON tuple; digest is an index, complete values are compared.
  defp identity(parts), do: "GI-" <> digest(JSON.encode!(parts))
  defp digest(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  defp fetch(rela, d, role, key) do
    with {:ok, fact} <- Rela.get(rela, plural(d, role), key), do: {:ok, decode(d, role, fact)}
  end

  defp plural(d, role), do: kind_plural(d, get_in(d, ["guidance", role, "kind"]))
  defp kind_plural(d, kind), do: get_in(d, ["entities", kind, "plural"])

  defp decode(d, role, fact) do
    fields = get_in(d, ["guidance", role, "fields"])

    for {slot, name} <- fields,
        Map.has_key?(fact.properties, name),
        into: %{"key" => fact.key},
        do: {slot, fact.properties[name]}
  end

  defp record_size(role, value) do
    if byte_size(JSON.encode!(value)) <= Map.fetch!(@record_bytes, role),
      do: :ok,
      else: {:error, :record_too_large}
  end

  defp view(rela, d, "interaction", fact) do
    interaction = decode(d, "interaction", fact)

    with true <- interaction["environment"] == AtlasBus.environment(),
         :ok <- record_size("interaction", interaction),
         {:ok, facts} <- Rela.list(rela, plural(d, "receipt")) do
      {count, projection} =
        Enum.reduce(facts, {0, projection_seed()}, fn fact, {count, projection} ->
          receipt = decode(d, "receipt", fact)

          if receipt["interaction"] == interaction["key"] and
               receipt["environment"] == interaction["environment"],
             do: {count + 1, project_event(receipt, projection)},
             else: {count, projection}
        end)

      {:ok,
       Map.merge(interaction, %{
         "receipt_count" => count,
         "projection" => Map.delete(projection, "admission")
       })}
    else
      false -> {:error, :wrong_environment}
      error -> error
    end
  end

  defp view(_, d, role, fact) do
    value = decode(d, role, fact)

    with true <- value["environment"] == AtlasBus.environment(),
         :ok <- record_size(role, value) do
      {:ok, value}
    else
      false -> {:error, :wrong_environment}
      error -> error
    end
  end

  @doc "Last proven stage and independent uncertainty/closure evidence; replay never regresses proof."
  def project(receipts),
    do: receipts |> Enum.reduce(projection_seed(), &project_event/2) |> Map.delete("admission")

  defp projection_seed,
    do: %{"proven" => "queued", "uncertain" => false, "closures" => [], "admission" => nil}

  # Fixed-size projection state: at most one admission id and the three closure
  # labels, regardless of how much immutable evidence remains in the backend.
  defp project_event(receipt, projection) do
    stage = receipt["stage"]

    projection =
      if stage in ~w(delivered acknowledged) do
        admission = receipt["admission_id"]

        proven =
          if stage == "acknowledged" or projection["proven"] == "acknowledged",
            do: "acknowledged",
            else: "delivered"

        %{
          projection
          | "proven" => proven,
            "uncertain" =>
              projection["uncertain"] or
                (projection["admission"] != nil and projection["admission"] != admission),
            "admission" => projection["admission"] || admission
        }
      else
        projection
      end

    projection =
      if stage == "uncertain", do: Map.put(projection, "uncertain", true), else: projection

    if stage in ~w(stale unsupported rejected),
      do: Map.update!(projection, "closures", &Enum.sort(Enum.uniq([stage | &1]))),
      else: projection
  end
end

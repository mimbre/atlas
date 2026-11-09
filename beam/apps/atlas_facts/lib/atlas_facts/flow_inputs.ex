defmodule AtlasFacts.FlowInputs do
  @moduledoc "Prepared choices, authorized by Facts and recovered before consumption."
  alias AtlasFacts.{Description, Rela}
  alias AtlasBus.Digest

  @fields ~w(request_id run flow subject_kind subject_key generation entry source_version subject_version actor roles changed_fields payload_digest status position prepared_at applied_at)
  @structured ~w(roles changed_fields)
  def fields, do: @fields
  def kind?(d, kind), do: get_in(d, ["flow_runtime", "inputs", "kind"]) == kind

  def validate(_d, nil), do: :ok

  def validate(d, c) do
    spec = Description.kind(d, c["kind"])

    valid =
      Map.keys(c) |> Enum.sort() == ~w(acl fields kind roles) and
        Map.keys(c["fields"]) |> Enum.sort() == Enum.sort(@fields) and
        length(Enum.uniq(Map.values(c["fields"]))) == length(@fields) and
        Enum.all?(c["fields"], fn {slot, field} ->
          type = if slot in ~w(entry generation position), do: "integer", else: "string"
          get_in(spec, ["properties", field, "type"]) == type
        end) and
        Enum.sort(Map.keys(c["roles"])) == Enum.sort(Map.keys(c["acl"])) and
        Enum.all?(c["roles"], fn {role, relation} ->
          is_binary(role) and is_map(c["acl"][role]) and
            Map.keys(c["acl"][role]) == ["update"] and is_list(c["acl"][role]["update"]) and
            is_map(d["relations"][relation]) and
            Enum.all?(c["acl"][role]["update"] || [], &(&1 in d["relations"][relation]["from"]))
        end)

    if valid, do: :ok, else: {:error, :invalid_input_mapping}
  rescue
    _ -> {:error, :invalid_input_mapping}
  end

  def read(rela, d, e, %{"run" => run_key}, now, position, write) do
    with true <- e.sender == d["flow_runtime"]["writer"]["sender"],
         {:ok, run} <- run(rela, d, run_key),
         {:ok, facts} <- Rela.list(rela, plural(d)) do
      facts
      |> Enum.filter(&(decode(d, &1)["run"] == run_key))
      |> Enum.reduce_while({:ok, []}, fn fact, {:ok, acc} ->
        value = decode(d, fact)

        result =
          if value["status"] == "prepared",
            do: apply_prepared(rela, d, fact, value, now, position, write),
            else: {:ok, value}

        case result do
          {:ok, v} -> {:cont, {:ok, [v | acc]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, inputs} ->
          {:ok, %{"inputs" => Enum.sort_by(inputs, & &1["position"]), "run" => run["key"]}}

        error ->
          error
      end
    else
      false -> {:error, :input_authority}
      error -> error
    end
  end

  def read(_, _, _, _, _, _, _), do: {:error, :exact_run_required}

  def write(
        rela,
        d,
        e,
        %{"op" => "submit", "by" => actor, "values" => v} = content,
        now,
        position,
        write
      )
      when is_map(v) do
    with true <- Enum.sort(Map.keys(content)) == ~w(by op values),
         true <-
           is_binary(e.sender) and String.starts_with?(e.sender, "control/session-") and
             is_binary(actor) and actor != "",
         true <- Enum.sort(Map.keys(v)) == ~w(changed_fields entry request_id run source_version),
         true <-
           is_binary(v["request_id"]) and v["request_id"] != "" and is_map(v["changed_fields"]) and
             map_size(v["changed_fields"]) > 0,
         {:ok, run} <- run(rela, d, v["run"]) do
      key = identity(v["request_id"])
      digest = Digest.of_term(Map.put(v, "actor", actor))

      case Rela.get(rela, plural(d), key) do
        {:ok, fact} ->
          existing = decode(d, fact)

          if existing["payload_digest"] == digest,
            do: apply_prepared(rela, d, fact, existing, now, position, write),
            else: {:error, :request_conflict}

        {:error, :not_found} ->
          prepare(rela, d, run, actor, v, key, digest, now, position, write)

        error ->
          error
      end
    else
      false -> {:error, :input_authority}
      error -> error
    end
  end

  def write(
        rela,
        d,
        e,
        %{"op" => "consume", "key" => key, "run" => run_key},
        _now,
        _position,
        _write
      ) do
    with true <- e.sender == d["flow_runtime"]["writer"]["sender"],
         {:ok, run} <- run(rela, d, run_key),
         {:ok, fact} <- Rela.get(rela, plural(d), key),
         value = decode(d, fact),
         true <- value["run"] == run_key and value["status"] in ~w(applied consumed),
         true <- run["last_input"]["input"] == key and run["input_cursor"] >= value["position"] do
      if value["status"] == "consumed",
        do: {:ok, value},
        else: update(rela, d, fact, Map.put(value, "status", "consumed"))
    else
      false -> {:error, :input_authority}
      error -> error
    end
  end

  def write(_, _, _, _, _, _, _), do: {:error, :protected_operation_required}

  @doc "Fence a timeout's cursor claim against a concurrently prepared human choice."
  def fence(rela, d, kind, key, values) do
    c = d["flow_runtime"]

    if c && c["inputs"] && kind == c["kind"] && values[c["fields"]["last_input"]] do
      input = JSON.decode!(values[c["fields"]["last_input"]])

      if input["due"] do
        with {:ok, current} <- run(rela, d, key),
             {:ok, facts} <- Rela.list(rela, plural(d)) do
          pending =
            Enum.any?(facts, fn fact ->
              i = decode(d, fact)

              i["run"] == key and i["entry"] == input["entry"] and
                i["status"] in ~w(prepared applied) and i["position"] > current["input_cursor"] and
                DateTime.compare(parse!(i["prepared_at"]), parse!(input["due"])) != :gt
            end)

          if pending,
            do: {:refused, ["an earlier input must be consumed before this timeout"]},
            else: :ok
        else
          _ -> {:refused, ["input ordering is unavailable"]}
        end
      else
        :ok
      end
    else
      :ok
    end
  rescue
    _ -> {:refused, ["invalid input ordering evidence"]}
  end

  defp parse!(time) do
    {:ok, utc, _} = DateTime.from_iso8601(time)
    utc
  end

  defp prepare(rela, d, run, actor, v, key, digest, now, position, write) do
    with true <-
           run["status"] == "active" and run["entry"] == v["entry"] and
             run["pending"]["writes"] == [],
         {:ok, subject} <- subject(rela, d, run),
         true <- subject.version == v["source_version"],
         roles = roles(d, run["subject_kind"], subject, actor),
         true <- roles != [],
         :ok <-
           write.authorize.(
             run["subject_kind"],
             %{
               "op" => "change",
               "key" => run["subject_key"],
               "version" => v["source_version"],
               "values" => v["changed_fields"],
               "by" => actor
             },
             v["request_id"]
           ),
         :ok <-
           Description.check(
             Description.kind(d, run["subject_kind"]),
             v["changed_fields"],
             :change
           ) do
      value =
        Map.merge(Map.take(run, ~w(flow subject_kind subject_key generation entry)), %{
          "request_id" => v["request_id"],
          "run" => run["key"],
          "source_version" => v["source_version"],
          "subject_version" => "",
          "actor" => actor,
          "roles" => roles,
          "changed_fields" => v["changed_fields"],
          "payload_digest" => digest,
          "status" => "prepared",
          "position" => position.(),
          "prepared_at" => DateTime.to_iso8601(now.()),
          "applied_at" => ""
        })

      with {:ok, []} <- Rela.create(rela, plural(d), key, encode(d, value), %{}),
           {:ok, fact} <- Rela.get(rela, plural(d), key),
           do: apply_prepared(rela, d, fact, Map.put(value, "key", key), now, position, write)
    else
      false -> {:error, :stale_or_unauthorized_input}
      error -> error
    end
  end

  defp roles(d, kind, subject, actor) do
    c = d["flow_runtime"]["inputs"]

    for {role, relation} <- c["roles"],
        kind in (c["acl"][role]["update"] || []),
        actor in (subject.links[relation] || []),
        do: role
  end

  defp apply_prepared(_rela, _d, _fact, %{"status" => status} = value, _, _, _)
       when status in ~w(applied consumed),
       do: {:ok, value}

  defp apply_prepared(rela, d, fact, value, now, _position, write) do
    with {:ok, run} <- run(rela, d, value["run"]),
         true <- run["entry"] == value["entry"] and run["status"] == "active",
         {:ok, subject} <- subject(rela, d, run),
         # The prepared record binds request id and intended values. Recovery either
         # retries that exact versioned write or proves all intended values present.
         :ok <- apply_subject(subject, value, write),
         {:ok, applied} <- subject(rela, d, run) do
      update(
        rela,
        d,
        fact,
        Map.merge(value, %{
          "status" => "applied",
          "subject_version" => applied.version,
          "applied_at" => DateTime.to_iso8601(now.())
        })
      )
    else
      false -> {:error, :prepared_input_needs_reconciliation}
      error -> error
    end
  end

  defp apply_subject(subject, value, write) do
    matches =
      Enum.all?(value["changed_fields"], fn {field, v} -> subject.properties[field] == v end)

    if subject.version == value["source_version"] or matches do
      # The receiver binds the same request id to this exact payload, including
      # after a backend commit whose acknowledgement was lost.
      write.apply.(
        value["subject_kind"],
        %{
          "op" => "change",
          "key" => value["subject_key"],
          "values" => value["changed_fields"],
          "version" => value["source_version"],
          "by" => value["actor"]
        },
        value["request_id"]
      )
    else
      {:error, :prepared_input_needs_reconciliation}
    end
  end

  defp run(rela, d, key) do
    c = d["flow_runtime"]

    with {:ok, fact} <- Rela.get(rela, Description.kind(d, c["kind"])["plural"], key) do
      values = Map.new(c["fields"], fn {slot, field} -> {slot, fact.properties[field]} end)

      {:ok,
       values
       |> Map.put("key", key)
       |> Map.update!("pending", &JSON.decode!/1)
       |> Map.update!("last_input", &JSON.decode!/1)}
    end
  end

  defp subject(rela, d, run),
    do: Rela.get(rela, Description.kind(d, run["subject_kind"])["plural"], run["subject_key"])

  defp plural(d), do: Description.kind(d, d["flow_runtime"]["inputs"]["kind"])["plural"]
  defp identity(id), do: Digest.of_term(["flow-input", id]) |> String.replace("sha256:", "")

  defp encode(d, value),
    do:
      Map.new(d["flow_runtime"]["inputs"]["fields"], fn {slot, field} ->
        {field,
         if(slot in @structured,
           do: JSON.encode!(%{"version" => 1, "value" => value[slot]}),
           else: value[slot]
         )}
      end)

  defp decode(d, fact),
    do:
      Map.new(d["flow_runtime"]["inputs"]["fields"], fn {slot, field} ->
        {slot,
         if(slot in @structured,
           do: structured!(fact.properties[field]),
           else: fact.properties[field]
         )}
      end)
      |> Map.put("key", fact.key)

  defp structured!(text) do
    case JSON.decode!(text) do
      %{"version" => 1, "value" => value} -> value
      _ -> raise ArgumentError, "unknown input field version"
    end
  end

  defp update(rela, d, fact, value) do
    with {:ok, []} <- Rela.change(rela, plural(d), fact.key, encode(d, value), fact.version, %{}),
         do: {:ok, value}
  end
end

defmodule AtlasFacts.FlowInputs do
  @moduledoc "Prepared choices, authorized by Facts and recovered before consumption."
  alias AtlasFacts.{Description, Rela}
  alias AtlasBus.Digest

  @fields ~w(request_id run flow subject_kind subject_key generation entry source_version subject_version actor roles changed_fields links payload_digest status position prepared_at applied_at)
  @structured ~w(roles changed_fields links)
  @supervision_ops ~w(pickup hand_over)
  def fields, do: @fields
  def kind?(d, kind), do: get_in(d, ["flow_runtime", "inputs", "kind"]) == kind

  def capture(rela, d, e, %{"op" => "change", "by" => actor, "key" => _key} = content) do
    c = d["flow_runtime"]

    selection =
      c &&
        Enum.find(c["selection"], fn {_, s} ->
          s["subject"] == e.kind and
            Enum.any?(s["choices"] || [], &Map.has_key?(content["values"] || %{}, &1))
        end)

    cond do
      # The run writer's own change is the output of a transition its run already took
      # (an answer a pass gave for its owner), stored with the run before it is sent:
      # never an input. The rules of the kind still decide whether it may be stored.
      selection && e.sender == c["writer"]["sender"] ->
        :ordinary

      selection && String.starts_with?(e.sender || "", "control/session-") ->
        session_capture(rela, d, e, content, selection, actor)

      selection ->
        {:error, :input_authority}

      true ->
        :ordinary
    end
  end

  def capture(_, _, _, _), do: :ordinary

  defp session_capture(rela, d, e, content, selection, actor) do
    case Rela.get(rela, plural(d), identity(e.id)) do
      {:ok, fact} ->
        value = decode(d, fact)

        if value["actor"] == actor and value["changed_fields"] == content["values"] and
             (value["links"] || %{}) == (content["links"] || %{}) do
          {:capture,
           %{
             "op" => "submit",
             "by" => actor,
             "values" => %{
               "request_id" => e.id,
               "run" => value["run"],
               "entry" => value["entry"],
               "source_version" => value["source_version"],
               "changed_fields" => value["changed_fields"],
               "links" => value["links"] || %{}
             }
           }}
        else
          {:error, :request_conflict}
        end

      {:error, :not_found} ->
        capture_new(rela, d, e, content, selection)

      other ->
        other
    end
  end

  defp capture_new(rela, d, e, content, selection) do
    c = d["flow_runtime"]
    key = content["key"]

    with {:ok, facts} <- Rela.list(rela, Description.kind(d, c["kind"])["plural"]),
         run when not is_nil(run) <-
           Enum.find(facts, fn f ->
             f.properties[c["fields"]["subject_key"]] == key and
               f.properties[c["fields"]["flow"]] == elem(selection, 0) and
               f.properties[c["fields"]["status"]] == "active"
           end),
         {:ok, subject} <- Rela.get(rela, Description.kind(d, e.kind)["plural"], key) do
      seen = content["was"] || %{}

      unchanged =
        Enum.all?(content["values"] || %{}, fn {field, _} ->
          Map.has_key?(seen, field) and seen[field] == subject.properties[field]
        end) and
          Enum.all?(content["links"] || %{}, fn {relation, _} ->
            Map.has_key?(seen, relation) and
              Enum.sort(List.wrap(seen[relation])) == Enum.sort(subject.links[relation] || [])
          end)

      source_version =
        if content["version"] == nil or content["version"] == subject.version or unchanged,
          do: subject.version,
          else: content["version"]

      {:capture,
       %{
         "op" => "submit",
         "by" => content["by"],
         "values" => %{
           "request_id" => e.id,
           "run" => run.key,
           "entry" => run.properties[c["fields"]["entry"]],
           "source_version" => source_version,
           "changed_fields" => content["values"] || %{},
           "links" => content["links"] || %{}
         }
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> :ordinary
    end
  end

  def read(rela, d, e, %{"run" => run_key}, now, position, write) do
    with true <- e.sender == d["flow_runtime"]["writer"]["sender"],
         {:ok, run} <- run(rela, d, run_key),
         {:ok, facts} <- Rela.list(rela, plural(d)) do
      facts
      |> Enum.filter(&(decode(d, &1)["run"] == run_key))
      |> Enum.reduce_while({:ok, []}, fn fact, {:ok, acc} ->
        value = decode(d, fact)

        # Completed-run reads expose retained history without reviving a choice
        # prepared before completion. Store selects executable restart intent.
        result =
          if value["status"] == "prepared" and run["status"] != "completed",
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

  # A restart changes no subject fields. The applied input itself is the durable intent,
  # bound to a completed generation; only Flow may turn it into another run.
  def write(
        rela,
        d,
        e,
        %{"op" => "restart", "by" => actor, "values" => v} = content,
        now,
        position,
        _write
      )
      when is_map(v) do
    with true <- Enum.sort(Map.keys(content)) == ~w(by op values),
         true <- is_binary(e.sender) and String.starts_with?(e.sender, "control/session-"),
         true <- is_binary(actor) and actor != "",
         true <- Enum.sort(Map.keys(v)) == ~w(request_id run),
         true <- is_binary(v["request_id"]) and v["request_id"] != "",
         {:ok, run} <- run(rela, d, v["run"]) do
      key = identity(v["request_id"])
      digest = Digest.of_term(["restart", actor, v])

      case Rela.get(rela, plural(d), key) do
        {:ok, fact} ->
          existing = decode(d, fact)

          if existing["payload_digest"] == digest,
            do: {:ok, existing},
            else: {:error, :request_conflict}

        {:error, :not_found} ->
          with :ok <- need(run["status"] == "completed", :not_completed),
               :ok <- current_generation(rela, d, run),
               {:ok, subject} <- subject(rela, d, run),
               :ok <- need(restart_allowed?(rela, d, run, subject, actor), :not_named_to_restart) do
            value =
              Map.merge(Map.take(run, ~w(flow subject_kind subject_key generation entry)), %{
                "request_id" => v["request_id"],
                "run" => run["key"],
                "source_version" => subject.version,
                "subject_version" => subject.version,
                "actor" => actor,
                "roles" => ["restart"],
                "changed_fields" => %{},
                "links" => %{},
                "payload_digest" => digest,
                "status" => "applied",
                "position" => position.(),
                "prepared_at" => DateTime.to_iso8601(now.()),
                "applied_at" => DateTime.to_iso8601(now.())
              })

            with {:ok, []} <- Rela.create(rela, plural(d), key, encode(d, value), %{}),
                 do: {:ok, Map.put(value, "key", key)}
          end

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
         true <-
           Enum.sort(Map.keys(Map.delete(v, "links"))) ==
             ~w(changed_fields entry request_id run source_version),
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

  # A pickup or hand-over (work acquisition design 2026-11-17, §5.6): a request from a
  # person at Control to become, or stop being, a run's human supervisor. Facts checks the
  # record and its sender, and keeps it applied; it writes neither the supervisor link nor
  # the subject. Flow alone consumes it and moves the link, after checking it again.
  def write(rela, d, e, %{"op" => op, "by" => actor, "values" => v} = content, now, position, _)
      when op in @supervision_ops and is_map(v) do
    with :ok <- need(Enum.sort(Map.keys(content)) == ~w(by op values), :input_shape),
         :ok <-
           need(
             is_binary(e.sender) and String.starts_with?(e.sender, "control/session-") and
               is_binary(actor) and actor != "",
             :input_authority
           ),
         :ok <- need(Enum.sort(Map.keys(v)) == supervision_values(op), :input_shape),
         :ok <- need(is_binary(v["request_id"]) and v["request_id"] != "", :input_shape),
         {:ok, s} <- supervision(d),
         {:ok, run} <- known_run(rela, d, v["run"]) do
      key = identity(v["request_id"])
      digest = Digest.of_term([op, actor, v])

      case Rela.get(rela, plural(d), key) do
        {:ok, fact} ->
          existing = decode(d, fact)

          if existing["payload_digest"] == digest,
            do: {:ok, existing},
            else: {:error, :request_conflict}

        {:error, :not_found} ->
          with :ok <- need(run["status"] == "active", :not_active),
               :ok <- current_generation(rela, d, run),
               :ok <- need(in_span?(s, run), :outside_span),
               :ok <- need(person?(rela, d, s, actor), :not_a_person),
               {:ok, supervisor} <- supervisor(rela, d, s, run),
               :ok <- acquisition(rela, d, s, op, run, supervisor, actor, v),
               {:ok, subject} <- subject(rela, d, run) do
            value =
              Map.take(run, ~w(flow subject_kind subject_key generation entry))
              |> Map.merge(%{
                "request_id" => v["request_id"],
                "run" => run["key"],
                "source_version" => subject.version,
                "subject_version" => subject.version,
                "actor" => actor,
                s["slots"]["operation"] => op,
                "roles" => [op],
                "changed_fields" => %{},
                "links" => %{},
                "payload_digest" => digest,
                "status" => "applied",
                "position" => position.(),
                "prepared_at" => DateTime.to_iso8601(now.()),
                "applied_at" => DateTime.to_iso8601(now.())
              })
              |> Map.merge(
                if(op == "hand_over", do: %{s["slots"]["hand_to"] => v["hand_to"]}, else: %{})
              )

            with {:ok, []} <- Rela.create(rela, plural(d), key, encode(d, value), %{}),
                 do: {:ok, Map.put(value, "key", key)}
          end

        error ->
          error
      end
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
    with :ok <-
           need(
             run["status"] == "active" and run["entry"] == v["entry"] and
               run["pending"]["writes"] == [],
             :input_moved_on
           ),
         :ok <- need(choice_state?(d, run), :not_waiting_for_choice),
         :ok <- need(before_deadline?(run, now.()), :answer_too_late),
         {:ok, subject} <- subject(rela, d, run),
         :ok <- need(subject.version == v["source_version"], :subject_changed),
         {:ok, held} <- part_links(rela, d, run["subject_kind"], run["subject_key"]),
         roles =
           roles(
             d,
             run["subject_kind"],
             %{subject | links: subject.links |> Map.merge(v["links"] || %{}) |> Map.merge(held)},
             actor
           ),
         :ok <- need(roles != [], :not_named_to_choose),
         :ok <-
           write.authorize.(
             run["subject_kind"],
             %{
               "op" => "change",
               "key" => run["subject_key"],
               "version" => v["source_version"],
               "values" => v["changed_fields"],
               "links" => v["links"] || %{},
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
          "links" => v["links"] || %{},
          "payload_digest" => digest,
          "status" => "prepared",
          "position" => position.(),
          "prepared_at" => DateTime.to_iso8601(now.()),
          "applied_at" => ""
        })

      with {:ok, []} <- Rela.create(rela, plural(d), key, encode(d, value), %{}),
           {:ok, fact} <- Rela.get(rela, plural(d), key),
           do: apply_prepared(rela, d, fact, Map.put(value, "key", key), now, position, write)
    end
  end

  defp need(true, _reason), do: :ok
  defp need(_, reason), do: {:error, reason}

  @doc """
  Why a choice was refused, in sentences for the one who made it: never a code. The
  relations that give a role (`inputs.roles`) are named, so the chooser knows what to set.
  """
  def reasons(reason, d \\ %{})

  def reasons({:subject_authority, {:refused, reasons}}, _d) when is_list(reasons), do: reasons
  def reasons({:subject_authority, _}, _d), do: ["Facts could not check it now; try again."]
  def reasons({:subject_write, _}, _d), do: ["Facts could not store it now; try again."]

  def reasons(:input_moved_on, _d),
    do: ["Its flow moved on meanwhile; open it again and answer what it shows now."]

  def reasons(:not_waiting_for_choice, _d),
    do: ["Its flow is not waiting for this choice now; open it again to see what it waits for."]

  def reasons(:answer_too_late, _d),
    do: ["The time to answer has passed; Flow asks again who answers it."]

  def reasons(:subject_changed, _d),
    do: ["It changed since you opened it; open it again and retry."]

  def reasons(:not_named_to_choose, d) do
    relations =
      (get_in(d, ["flow_runtime", "inputs", "roles"]) || %{})
      |> Map.values()
      |> Enum.uniq()
      |> Enum.sort()

    case relations do
      [] ->
        ["You may not make this choice."]

      _ ->
        [
          "Only the one its #{Enum.join(relations, " or ")} names may make this choice; " <>
            "name yourself there in the same change."
        ]
    end
  end

  def reasons(:input_authority, _d),
    do: ["Only Control, for the one who answers, may make this choice."]

  def reasons(:request_conflict, _d),
    do: ["This request was already sent with other content; open it again and retry."]

  def reasons(:input_shape, _d),
    do: ["Control sent this in a form Facts does not take."]

  def reasons(:supervision_undeclared, _d),
    do: ["Nobody supervises a flow here: the model declares no supervision."]

  def reasons(:unknown_run, _d),
    do: ["Its flow is not known here; open it again."]

  def reasons(:not_active, _d),
    do: ["Its flow is not running now; open it again to see where it is."]

  def reasons(:outside_span, _d),
    do: ["Its flow is not at a step a person supervises now; open it again."]

  def reasons(:not_a_person, _d),
    do: ["Only a person may pick up or hand over a flow, for themselves."]

  def reasons(:already_supervised, _d),
    do: ["Someone supervises it already; open it again to see who."]

  def reasons(:pickup_pending, _d),
    do: ["A pick up of it is on its way already; wait until its flow takes it."]

  def reasons(:not_supervisor, _d),
    do: ["Only the one who supervises it may hand it over."]

  def reasons(:hand_to_self, _d),
    do: ["Hand it over to someone else."]

  def reasons(:hand_to_not_a_person, _d),
    do: ["It can only be handed over to a person."]

  def reasons(:prepared_input_needs_reconciliation, _d),
    do: ["An earlier answer to it is still being applied; try again shortly."]

  def reasons(reason, _d) when is_atom(reason),
    do: ["Facts refused it: " <> String.replace(Atom.to_string(reason), "_", " ") <> "."]

  def reasons(_reason, _d), do: ["Facts refused it."]

  defp choice_state?(d, run) do
    states = get_in(d, ["flow_runtime", "selection", run["flow"], "choice_states"])
    states == nil or run["state"] in states
  end

  defp restart_allowed?(rela, d, run, subject, actor) do
    selection = get_in(d, ["flow_runtime", "selection", run["flow"]]) || %{}

    admitted =
      Enum.all?(selection["admission"] || %{}, fn {field, values} ->
        subject.properties[field] in values
      end)

    admitted and
      Enum.any?(selection["restart_by"] || [], fn
        "owner" ->
          p = selection["projection"] || %{}

          target =
            if p["on"] do
              with [key] <- subject.links[p["on"]],
                   [kind] <- get_in(d, ["relations", p["on"], "to"]),
                   {:ok, fact} <- Rela.get(rela, Description.kind(d, kind)["plural"], key) do
                fact
              else
                _ -> nil
              end
            else
              subject
            end

          target != nil and actor in (target.links[p["owner_relation"]] || [])

        role ->
          Enum.any?(d["actors"] || %{}, fn {name, key} ->
            to_string(name) == role and key == actor
          end)
      end)
  end

  defp supervision_values("pickup"), do: ~w(request_id run)
  defp supervision_values("hand_over"), do: ~w(hand_to request_id run)

  # The model's supervision, with the input slots its operation and hand-to fields are
  # kept in and the one kind its relation leads to (who may supervise).
  defp supervision(d) do
    s = d["flow_runtime"]["supervision"]
    fields = d["flow_runtime"]["inputs"]["fields"] || %{}
    slot = fn field -> Enum.find_value(fields, fn {slot, f} -> if f == field, do: slot end) end

    with %{"relation" => relation, "inputs" => inputs} <- s,
         [to] <- get_in(d, ["relations", relation, "to"]),
         operation when is_binary(operation) <- slot.(inputs["operation"]),
         hand_to when is_binary(hand_to) <- slot.(inputs["hand_to"]) do
      {:ok,
       Map.merge(s, %{"to" => to, "slots" => %{"operation" => operation, "hand_to" => hand_to}})}
    else
      _ -> {:error, :supervision_undeclared}
    end
  end

  defp known_run(rela, d, key) do
    case is_binary(key) && run(rela, d, key) do
      {:ok, run} -> {:ok, run}
      {:error, :not_found} -> {:error, :unknown_run}
      false -> {:error, :input_shape}
      error -> error
    end
  end

  # Inside one of the spans of its subflow, at one of that span's states.
  defp in_span?(s, run),
    do:
      Enum.any?(get_in(s, ["spans", run["flow"]]) || [], &(run["state"] in (&1["states"] || [])))

  defp person?(rela, d, s, key),
    do:
      is_binary(key) and
        match?({:ok, _}, Rela.get(rela, Description.kind(d, s["to"])["plural"], key))

  # The keys the run's supervision relation links, as stored.
  defp supervisor(rela, d, s, run) do
    c = d["flow_runtime"]

    with {:ok, fact} <- Rela.get(rela, Description.kind(d, c["kind"])["plural"], run["key"]),
         do: {:ok, (fact.links || %{})[s["relation"]] || []}
  end

  defp acquisition(rela, d, s, "pickup", run, supervisor, _actor, _v) do
    with :ok <- need(supervisor == [], :already_supervised),
         {:ok, facts} <- Rela.list(rela, plural(d)) do
      pending =
        Enum.any?(facts, fn fact ->
          i = decode(d, fact)

          i["run"] == run["key"] and i[s["slots"]["operation"]] == "pickup" and
            i["status"] in ~w(prepared applied)
        end)

      need(not pending, :pickup_pending)
    end
  end

  defp acquisition(rela, d, s, "hand_over", _run, supervisor, actor, v) do
    with :ok <- need(actor in supervisor, :not_supervisor),
         :ok <- need(v["hand_to"] != actor, :hand_to_self),
         do: need(person?(rela, d, s, v["hand_to"]), :hand_to_not_a_person)
  end

  defp current_generation(rela, d, run) do
    c = d["flow_runtime"]

    with {:ok, facts} <- Rela.list(rela, Description.kind(d, c["kind"])["plural"]) do
      newer =
        Enum.any?(facts, fn fact ->
          Enum.all?(~w(flow subject_kind subject_key), fn slot ->
            fact.properties[c["fields"][slot]] == run[slot]
          end) and fact.properties[c["fields"]["generation"]] > run["generation"]
        end)

      need(not newer, :input_moved_on)
    end
  end

  defp before_deadline?(run, now) do
    Enum.all?(get_in(run, ["deadlines", "timers"]) || [], fn t ->
      {:ok, due, _} = DateTime.from_iso8601(t["due"])
      DateTime.compare(now, due) != :gt
    end)
  end

  # The links of the facts made with the subject (its components, such as what being
  # assigned holds), as they are stored: their associations are the subject's own, so a
  # role may come through one. Stored, never as the choice sends them: naming oneself
  # there in the same change gives no role. Only the components a role of the subject's
  # kind comes through are read: a kind whose roles all lead from itself reads none.
  defp part_links(rela, d, kind, key) do
    Enum.reduce_while(granting_parts(d, kind), {:ok, %{}}, fn {to, template}, {:ok, acc} ->
      case Rela.get(
             rela,
             Description.kind(d, to)["plural"],
             String.replace(template, "{key}", key)
           ) do
        {:ok, part} -> {:cont, {:ok, Map.merge(acc, part.links || %{})}}
        {:error, :not_found} -> {:cont, {:ok, acc}}
        error -> {:halt, error}
      end
    end)
  end

  # `[{part kind, key template}]` of the components of `kind` that a relation giving one
  # of the kind's roles (under its ACL) leads from.
  defp granting_parts(d, kind) do
    c = d["flow_runtime"]["inputs"]
    # Components are model metadata, not part of Rela's public schema. The compiled
    # input mapping supplies them when Facts runs against the real schema.
    relations = Map.merge(d["relations"] || %{}, c["components"] || %{})

    from =
      for {role, relation} <- c["roles"] || %{},
          kind in (get_in(c, ["acl", role, "update"]) || []),
          part <- List.wrap((relations[relation] || %{})["from"]),
          uniq: true,
          do: part

    for {_name, %{"component" => %{"key" => template}, "to" => [to]} = spec} <-
          Enum.sort(relations),
        kind in List.wrap(spec["from"]),
        to in from,
        do: {to, template}
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
      Enum.all?(value["changed_fields"], fn {field, v} -> subject.properties[field] == v end) and
        Enum.all?(value["links"] || %{}, fn {relation, keys} ->
          Enum.sort(subject.links[relation] || []) == Enum.sort(keys)
        end)

    if subject.version == value["source_version"] or matches do
      # The receiver binds the same request id to this exact payload, including
      # after a backend commit whose acknowledgement was lost.
      write.apply.(
        value["subject_kind"],
        %{
          "op" => "change",
          "key" => value["subject_key"],
          "values" => value["changed_fields"],
          "links" => value["links"] || %{},
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
       |> Map.update("deadlines", %{"version" => 1, "timers" => []}, fn
         nil -> %{"version" => 1, "timers" => []}
         text -> JSON.decode!(text)
       end)
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
         cond do
           slot == "links" and fact.properties[field] == nil -> %{}
           slot in @structured -> structured!(fact.properties[field])
           true -> fact.properties[field]
         end}
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

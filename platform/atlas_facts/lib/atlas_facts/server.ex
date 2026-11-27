defmodule AtlasFacts.Server do
  @moduledoc """
  Facts on the Bus: the store endpoint. Generic: what a kind is, it reads from rela; what
  may be written, what a write brings along and what is worked out on a read, it asks the
  model (`AtlasFacts.Model`), wired at boot. At boot rela must serve the schema the model
  was built with (`rela_schema/0`); otherwise Facts refuses to start, and says why. Every
  fact is then loaded into memory (`AtlasFacts.Cache`): reads are answered from there,
  writes go to rela first.

  Reads do not wait behind writes (IS-Atlas-85). The Bus answers a read in the process
  that sends it (`AtlasBus.answer_reads/1`, `answer/3`), from the copy as Facts last
  published it: what a write changed is published whole, with Facts' position, before
  Facts answers the write (`AtlasFacts.Cache`), so a sender reads its own write and no read
  sees one half applied. Writes, rela's change feed, the reads that may write (a run's
  inputs) or ask rela itself (`_description`, `_flow_recovery`) are Facts' own, in order.

  - A `fact` is stored in rela and answered with one `stored` (acknowledgement and hint,
    with the fact's position) or one `refused` (final, with reasons). Never silence.
    A resent id gets its first answer again and is not stored twice. A write Facts cannot
    take yet (it has not read rela's schema and facts, or rela is not reachable) is
    refused with `code: "not_ready"`, unrecorded: the same id may be sent again later. `stored` says what
    the write changed (`changes`, one entry per fact, what it brought along included:
    `AtlasFacts.Freshness.Changes`).
  - A `read` is answered with the facts of a kind (all, or `"linked" => %{relation => key}`
    for those that point at `key`), one fact (`"key" => key`) with the keys of the facts
    that point at it and, for a copy of an outside fact, when a connector last read it
    (`"copy"`, see `AtlasFacts.Copies`), or (kind `_description`) rela's schema, as rela
    serves it. Facts carry their outgoing `links`, with the `origins` of those links (the
    fact that set each: since, by, cause; `AtlasFacts.Links`), and what the model works
    out for them (`derived/3`: `progress`, why they are `completion`, `review`, `late`):
    worked out on every read, never stored. One fact also carries the `history` of its
    links. A `_page` read (Control's only) asks for several reads at once (`"reads" =>
    [[kind, content]]`) and answers them in order from one snapshot, at one position.
    A read of facts (each answer of a `_page` too) says what it depended on
    (`deps`) and, when a value in it changes by time alone, when (`until`;
    `AtlasFacts.Freshness.Deps`). A `_position` read answers how far Facts is, its
    position alone, without reading rela (Control's reconcile).

  Fact content: `%{"op" => "create" | "change" | "delete", "key" => id,
  "values" => %{property => value}, "version" => version read before, or nil,
  "links" => %{relation => [keys]}, "cause" => why, optional, "by" => who, optional,
  "was" => %{property or relation => value or keys} on a change, optional}`.
  A fact's components (the model's `with_change/3`) are made in the same write, before
  it, and deleted with it; a component alone is not deleted while its fact exists.
  On a create the links are the fact's first; on a change each relation named is replaced
  by the keys given (`[]` removes its links), so a fact moves to another parent or an
  association is set or removed; the hint then reaches every listener of its kind, on
  the old parent's page and the new one's. The cause and who sent it are kept with
  Facts' answer and go along with the hint. A change on an old version is refused only
  when what it sets changed meanwhile: with `was` (the values and links the sender read)
  and every field and relation it sets still as it was, it is applied on the current
  version, so a write to other fields (Flow's, a connector's) never fails a user's save.
  A change may opt into `strict_version: true`: it requires a version and refuses any
  mismatch, even when the requested values are already present or only other fields
  changed. Replaying the same request id still returns its recorded ledger answer.
  A kind may declare `create(replay_identity: :field)`. Fresh creates need not have the
  field, but an equal existing fact is not proof of a retry without it: that collision
  refuses with `identity_unproven`. A different fact still refuses with `exists`, and a
  recorded request id still replays its original answer.
  """
  use GenServer

  require Logger

  alias AtlasBus.Envelope

  alias AtlasFacts.{Cache, Copies, Description, Ledger, Links, Rela}
  alias AtlasFacts.Freshness.{Changes, Deps}

  @description "_description"
  @page "_page"
  @position "_position"
  @recovery "_flow_recovery"
  # How many reads one page may ask for, and what each may say (no other query context).
  @page_reads 64
  @page_read_keys ~w(key linked plain incoming presentation)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

  @doc "Load every fact from rela again, after writes past Facts. Not a Bus operation."
  def reload(server), do: GenServer.call(server, :reload)

  @impl true
  def handle_call(:reload, _from, state) do
    published(state, fn ->
      {:reply, state.description && Cache.load(state.cache, state.description), state}
    end)
  end

  # Every message is handled on what Facts staged (`AtlasFacts.Cache`); what it changed is
  # published before anything leaves Facts (`deliver/2`) and once it is handled.
  @publisher {__MODULE__, :publisher}

  defp published(state, handle) do
    Cache.stage(state.cache)
    Process.put(@publisher, fn -> publish(state) end)
    result = handle.()
    publish(elem(result, tuple_size(result) - 1))
    Process.delete(@publisher)
    result
  end

  defp publish(state),
    do: Cache.publish(state.cache, Ledger.position(state.ledger), state.description)

  # What Facts sends (answers, hints) follows what it published.
  defp deliver(envelope, content) do
    case Process.get(@publisher) do
      nil -> :ok
      publish -> publish.()
    end

    AtlasBus.send(envelope, content)
  end

  # A lookup that could not read the store: the write is not recorded.
  @lookup_failed :atlas_facts_lookup_failed

  # The model is checked first, then rela's schema against it: a rela that cannot be
  # reached yet is read again on the first request, and checked then.
  @impl true
  def init(opts) do
    model =
      AtlasFacts.Model.check!(Keyword.get_lazy(opts, :model, &AtlasFacts.Model.configured!/0))

    rela = Cache.open(Keyword.fetch!(opts, :rela))

    case Rela.description(rela) do
      {:ok, served} ->
        case AtlasFacts.Model.mismatch(model, served) do
          nil ->
            # Warm: every fact is read before the first read is answered.
            case Cache.load(rela, served) do
              :ok ->
                start(opts, model, rela, served)

              {:error, reason} ->
                Logger.warning(
                  "Facts starts without its facts (#{inspect(reason)}); it reads them again"
                )

                start(opts, model, rela, nil)
            end

          reason ->
            Logger.error("Facts does not start: " <> reason)
            {:stop, {:schema_mismatch, reason}}
        end

      {:error, reason} ->
        Logger.warning(
          "Facts starts without rela's schema (#{inspect(reason)}); it reads it again"
        )

        start(opts, model, rela, nil)
    end
  end

  defp start(opts, model, rela, schema) do
    :ok = AtlasBus.attach(AtlasBus.store())
    dir = Keyword.fetch!(opts, :data_dir)

    state = %{
      rela: rela,
      cache: rela,
      ledger: Ledger.open(dir),
      links: Links.open(dir),
      model: model,
      description: schema,
      actors: Keyword.get_lazy(opts, :actors, &AtlasBus.Actors.configured/0),
      input_clock: Keyword.get(opts, :flow_input_clock, fn -> DateTime.utc_now() end)
    }

    :ok = publish(state)
    reader = Map.take(state, [:cache, :links, :model, :actors])
    :ok = AtlasBus.answer_reads({__MODULE__, reader})
    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    Ledger.close(state.ledger)
    Links.close(state.links)
  end

  @impl true
  def handle_info(message, state), do: published(state, fn -> handle(message, state) end)

  defp handle({:atlas_bus, %Envelope{class: class} = envelope, content}, state)
       when class in ["fact", "read"] do
    {described, state} = ensure_description(state, envelope)

    binding = Ledger.request_identity(envelope, content)

    cond do
      # Facts has not read rela's schema and facts yet (it is starting, or rela is not
      # reachable): a write is refused as not ready, unrecorded, so the same id is stored
      # once Facts is ready. A sender may wait and send it again (`not_ready`).
      class == "fact" and described == :unavailable ->
        not_ready(envelope, content, state)

      class == "fact" ->
        fact(envelope, content, binding, state)

      true ->
        dispatch(envelope, content, state)
    end
  end

  defp handle({:atlas_bus, _envelope, _content}, state), do: {:noreply, state}

  # rela's change feed (`AtlasFacts.Rela.Events`): kinds changed in rela, by Facts or by
  # another writer. Those that others write (the model's `written_past_facts/0`) are read
  # again; every fact that differs from Facts' copy is hinted as stored, by "rela", at its
  # own position.
  defp handle({:rela_changed, kinds}, %{description: description} = state)
       when is_map(description) do
    watched =
      if function_exported?(state.model, :written_past_facts, 0),
        do: state.model.written_past_facts(),
        else: []

    kinds = if kinds == :all, do: watched, else: Enum.filter(kinds, &(&1 in watched))

    for kind <- kinds,
        plural = get_in(description, ["entities", kind, "plural"]),
        changed = refreshed(state, kind, plural),
        {key, before, later} <- changed do
      entry = Changes.entry(kind, key, seen(before), seen(later))

      about = %{
        "op" => entry["op"],
        "key" => key,
        "by" => "rela",
        "cause" => "written in rela, past Facts",
        "changes" => [entry]
      }

      envelope = Envelope.new("stored", kind)
      position = Ledger.stored(state.ledger, envelope.id, about)
      :ok = deliver(%{envelope | position: position}, about)
    end

    {:noreply, state}
  end

  defp handle({:rela_changed, _kinds}, state), do: {:noreply, state}

  defp refreshed(state, kind, plural) do
    case Cache.refresh(state.cache, plural) do
      {:ok, changed} ->
        changed

      error ->
        Logger.warning(
          "Facts could not read #{kind} again after rela said it changed: #{inspect(error)}"
        )

        []
    end
  end

  defp seen(nil), do: nil
  defp seen(fact), do: %{values: fact.properties, links: fact.links}

  # Maintenance evidence is read from the owning ledger, never ordinary write replay.
  # Only the already configured machine endpoint may ask; the reply grants no write.
  defp dispatch(%Envelope{class: "read", kind: @recovery} = envelope, content, state) do
    writer = get_in(context(state), ["flow_runtime", "writer"])

    answer =
      if is_map(content) and is_map(writer) and is_binary(writer["sender"]) and
           writer["sender"] != "" and
           is_binary(writer["by"]) and writer["by"] != "" and
           envelope.sender == writer["sender"] and content["by"] == writer["by"] do
        recovery_evidence(state, content["write"], writer, content["candidate"])
      else
        %{"error" => "forbidden"}
      end

    reply(envelope, "answer", answer, nil)
    {:noreply, state}
  end

  defp dispatch(%Envelope{class: "read", kind: @page} = envelope, content, state) do
    {answer, state} = read_answer(envelope, content, state)
    reply(envelope, "answer", answer, nil)
    {:noreply, state}
  end

  defp dispatch(envelope, content, state) do
    input_protocol? = envelope.class == "fact" or match?(%{"run" => _}, content)

    if AtlasFacts.FlowInputs.kind?(context(state), envelope.kind) and input_protocol? do
      flow_input(envelope, content, state)
    else
      capture =
        if envelope.class == "fact",
          do:
            AtlasFacts.FlowInputs.capture(
              state.rela,
              context(state),
              envelope,
              content
            ),
          else: :ordinary

      case capture do
        # A choice (an answer to what a run waits for): its subject is written when the
        # input is, and the links it sets keep who set them and why (the answer's cause).
        {:capture, input} ->
          flow_input(
            %{envelope | kind: state.model.run_mapping()["inputs"]["kind"]},
            input,
            state,
            content["cause"]
          )

        {:error, reason} ->
          reply(
            envelope,
            "refused",
            %{
              "code" => guidance_code(reason),
              "reasons" => AtlasFacts.FlowInputs.reasons(reason, context(state))
            },
            nil
          )

          {:noreply, state}

        :ordinary ->
          dispatch_ordinary(envelope, content, state)
      end
    end
  end

  defp recovery_evidence(
         state,
         %{"id" => id, "kind" => kind, "content" => content},
         writer,
         candidate
       )
       when is_binary(id) and is_binary(kind) and is_map(content) do
    with {"refused", about, nil} <- Ledger.answer(state.ledger, id),
         true <- Enum.all?(~w(op key by), &(about[&1] == content[&1])),
         :ok <- recovery_preflight(state, kind, content, writer),
         :ok <- recovery_successor(state, id, kind, content, writer, candidate) do
      %{
        "receipt" => %{
          "class" => "refused",
          "content" => about,
          "position" => nil,
          "binding" => "legacy_unbound"
        }
      }
    else
      _ -> %{"error" => "recovery evidence unavailable or ineligible"}
    end
  rescue
    _ -> %{"error" => "recovery evidence unavailable or ineligible"}
  catch
    {@lookup_failed, _} -> %{"error" => "recovery evidence unavailable or ineligible"}
  end

  defp recovery_evidence(_state, _write, _writer, _candidate),
    do: %{"error" => "invalid recovery request"}

  defp recovery_successor(_state, _id, _kind, _content, _writer, nil), do: :ok

  defp recovery_successor(state, id, kind, content, writer, candidate) do
    with true <-
           is_binary(candidate["id"]) and candidate["id"] != id and candidate["kind"] == kind,
         next = candidate["content"],
         true <- Enum.all?(~w(op key by), &(next[&1] == content[&1])),
         true <- Map.keys(next["values"]) == Map.keys(content["values"]) do
      recovery_preflight(state, kind, next, writer)
    end
  end

  defp recovery_preflight(state, kind, content, writer) do
    with %{"op" => "change", "key" => key, "values" => values} <- content,
         true <- Map.keys(content) -- ~w(op key values by links) == [],
         true <- (content["links"] || %{}) == %{} and content["by"] == writer["by"],
         [{field, n}] when is_integer(n) and n >= 0 <- Map.to_list(values),
         true <- function_exported?(state.model, :__rela__, 1),
         extension = state.model.__rela__(:description).extension,
         true <-
           get_in(extension, ["entities", kind, "properties", field, "set_by"]) == [writer["by"]],
         {:ok, spec, state} <- kind_spec(state, kind),
         lookup = lookup(state, kind, spec, "change", key),
         change = Map.put(content, "links", %{}),
         [own] <- state.model.with_change(kind, change, lookup),
         true <- own == Map.merge(change, %{"as" => "fact", "kind" => kind}),
         :stored <-
           store(
             Map.merge(state, %{sender: writer["sender"], validate_only: true}),
             kind,
             spec,
             "change",
             key,
             content
           ) do
      :ok
    else
      _ -> :ineligible
    end
  end

  # What the records Facts keeps (runs and their inputs, guidance) are read by: rela's
  # schema, with the model's run mapping, turn and guidance records.
  defp context(state) do
    Map.merge(state.description || %{}, %{
      "flow_runtime" => state.model.run_mapping(),
      "actors" => state.actors || %{},
      "guidance" => state.model.guidance(),
      "runtime" => %{"turn" => state.model.turn()}
    })
  end

  defp flow_input(envelope, content, state, cause \\ nil) do
    rela = state.rela

    write = fn kind, content, request_id ->
      id = AtlasBus.Digest.of_term(["input-subject-write", request_id])

      proof = %{
        "request_id" => request_id,
        "payload_digest" => AtlasBus.Digest.of_term([kind, content])
      }

      case Ledger.answer(state.ledger, id) do
        {"stored", ^proof, _position} ->
          :ok

        nil ->
          {result, _} =
            store(Map.put(%{state | rela: rela}, :sender, envelope.sender), kind, content)

          case result do
            :stored ->
              position = Ledger.stored(state.ledger, id, proof)
              about = if is_binary(cause), do: %{"cause" => cause}, else: %{}

              about =
                if is_binary(content["by"]), do: Map.put(about, "by", content["by"]), else: about

              remember_links(state, kind, content, about, position)
              :ok

            other ->
              {:error, {:subject_write, other}}
          end

        _ ->
          {:error, :request_conflict}
      end
    end

    authorize = fn kind, content, _request_id ->
      {result, _} =
        store(
          %{state | rela: rela}
          |> Map.put(:sender, envelope.sender)
          |> Map.put(:validate_only, true),
          kind,
          content
        )

      case result do
        :stored -> :ok
        other -> {:error, {:subject_authority, other}}
      end
    end

    args = [
      rela,
      context(state),
      envelope,
      content,
      state.input_clock,
      fn -> Ledger.reserve(state.ledger) end,
      %{authorize: authorize, apply: write}
    ]

    result =
      try do
        apply(AtlasFacts.FlowInputs, if(envelope.class == "read", do: :read, else: :write), args)
      rescue
        _ -> {:error, :invalid_input_record}
      end

    case result do
      {:ok, value} when envelope.class == "read" ->
        reply(envelope, "answer", value, value["position"])

      {:ok, value} ->
        changes = changes(state, envelope.kind, content["key"] || value["key"])
        reply(envelope, "stored", Map.put(value, "changes", changes), value["position"])

      # rela was not reachable while the input was checked, before anything is written:
      # not ready, not a refusal on the merits, so the sender may send it again.
      {:error, reason}
      when envelope.class == "fact" and
             reason in [:unavailable, {:subject_authority, :unavailable}] ->
        not_ready(envelope, content, state)

      {:error, reason} ->
        reply(
          envelope,
          if(envelope.class == "read", do: "answer", else: "refused"),
          %{
            "error" => inspect(reason),
            "reasons" => AtlasFacts.FlowInputs.reasons(reason, context(state))
          },
          nil
        )
    end

    {:noreply, state}
  end

  defp dispatch_ordinary(envelope, content, state) do
    case AtlasFacts.Guidance.role(context(state), envelope.kind) do
      nil ->
        if envelope.class == "fact" do
          case AtlasFacts.Guidance.authorize_turn(
                 state.rela,
                 context(state),
                 envelope,
                 content
               ) do
            :ok ->
              ordinary(envelope, content, state)

            {:delete, target} ->
              delete_request(envelope, content, target, state)

            :absent_delete ->
              delete_request(envelope, content, :absent, state)

            {:error, reason} ->
              refusal(envelope, reason, state)
          end
        else
          ordinary(envelope, content, state)
        end

      role ->
        guidance(envelope, content, role, state)
    end
  end

  defp fact(envelope, content, binding, state) do
    if Ledger.matches_request?(state.ledger, envelope.id, binding) do
      rela = state.rela
      log = Changes.open()

      # Every write rela accepts while this fact is handled is noted, for its hint.
      recording = Changes.recorder(rela, log)

      try do
        {:noreply, state} =
          dispatch(envelope, content, Map.merge(state, %{rela: recording, changes: log}))

        {:noreply, %{Map.delete(state, :changes) | rela: rela}}
      after
        Changes.close(log)
      end
    else
      refusal(envelope, :request_conflict, state)
    end
  end

  @not_ready ["Facts is not ready yet: it is still reading its facts from rela."]

  defp not_ready(envelope, content, state) do
    about = %{"op" => content_op(content), "key" => content_key(content)}

    reply(
      envelope,
      "refused",
      Map.merge(about, %{"code" => "not_ready", "reasons" => @not_ready}),
      nil
    )

    {:noreply, state}
  end

  defp refusal(envelope, reason, state) do
    reply(envelope, "refused", %{"code" => guidance_code(reason)}, nil)
    {:noreply, state}
  end

  defp delete_request(envelope, content, target, state) do
    binding = Ledger.request_identity(envelope, content)

    if Ledger.delete_request_available?(state.ledger, envelope.id, binding) do
      if target == :absent,
        do: absent_delete(envelope, content, state),
        else: turn_delete(envelope, content, target, state)
    else
      refusal(envelope, :request_conflict, state)
    end
  end

  defp turn_delete(envelope, content, target, state) do
    binding = Ledger.request_identity(envelope, content)

    case Ledger.deletion(state.ledger, binding) do
      {:ok, %{answer: {_, _, _}}} ->
        refusal(envelope, :deleted_target_reappeared, state)

      {:ok, %{target: saved}} when saved != target ->
        refusal(envelope, :delete_target_changed, state)

      {:error, reason} ->
        refusal(envelope, reason, state)

      _ ->
        before_delete = fn fact ->
          if fact == nil or
               AtlasFacts.Guidance.deletion_target(context(state), fact) == target,
             do: Ledger.prepare_delete(state.ledger, envelope.id, binding, target),
             else: {:error, :delete_target_changed}
        end

        {:noreply, updated} =
          ordinary(envelope, content, Map.put(state, :before_delete, before_delete))

        {:noreply, Map.delete(updated, :before_delete)}
    end
  end

  defp absent_delete(envelope, content, state) do
    binding = Ledger.request_identity(envelope, content)

    case Ledger.deletion(state.ledger, binding) do
      {:ok, proof} ->
        :ok = Ledger.prepare_delete(state.ledger, envelope.id, binding, proof.target)

        case Ledger.answer(state.ledger, envelope.id) do
          {class, answer, position} ->
            if class == "stored",
              do: remember_links(state, envelope.kind, content, answer, position)

            reply(envelope, class, answer, position)

          nil ->
            # Confirmed absence plus durable validated intent: finish without a
            # backend delete, even after a commit-before-acknowledgement crash.
            answer(state, envelope, content, :stored)
        end

        {:noreply, state}

      :none ->
        refusal(envelope, :not_found, state)

      {:error, reason} ->
        refusal(envelope, reason, state)
    end
  end

  # Metadata reads fetch their own fresh snapshot in read/3. They are not entity
  # kinds to pre-validate: doing so would fetch the same backend schema twice.
  defp ensure_description(state, %Envelope{class: "read", kind: kind})
       when kind in [@description, @position, @recovery],
       do: {:ok, state}

  defp ensure_description(state, %Envelope{class: "read", kind: @page}) do
    if state.description do
      {:ok, state}
    else
      case describe(state) do
        {:ok, description} -> {:ok, %{state | description: description}}
        {:error, _} -> {:error, state}
      end
    end
  end

  defp ensure_description(state, %Envelope{kind: kind}) do
    case kind_spec(state, kind) do
      {:ok, _, state} -> {:ok, state}
      {:error, :unavailable, state} -> {:unavailable, state}
      {_, _, state} -> {:error, state}
    end
  end

  defp guidance(%Envelope{class: "read"} = envelope, content, role, state) do
    reply(envelope, "answer", guidance_read(state, role, content), nil)
    {:noreply, state}
  end

  defp guidance(envelope, content, role, state) do
    result =
      AtlasFacts.Guidance.write(state.rela, context(state), role, envelope, content, fn ->
        Ledger.reserve(state.ledger)
      end)

    case result do
      {:ok, answer} when envelope.class == "fact" ->
        position = answer["recorded_position"]

        reply(
          envelope,
          "stored",
          %{
            "key" => answer["key"],
            "fact" => answer,
            "changes" => record_changes(state, role, envelope.kind, answer)
          },
          position
        )

      {:error, reason} ->
        reply(
          envelope,
          "refused",
          %{"error" => inspect(reason), "code" => guidance_code(reason)},
          nil
        )
    end

    {:noreply, state}
  end

  defp guidance_read(state, role, content) do
    case AtlasFacts.Guidance.read(state.rela, context(state), role, content) do
      {:ok, answer} -> answer
      {:error, reason} -> %{"error" => inspect(reason), "code" => guidance_code(reason)}
    end
  end

  # A guidance record is made once and never changed: its answer, a replay's too, says it
  # was made, as the first answer did (its fields as rela holds them).
  defp record_changes(state, role, kind, answer) do
    mapping = get_in(context(state), ["guidance", role, "fields"]) || %{}

    values =
      for {name, value} <- answer,
          field = mapping[name],
          field != nil,
          into: %{},
          do: {field, value}

    [Changes.entry(kind, answer["key"], nil, %{values: values, links: %{}})]
  end

  defp guidance_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp guidance_code(_), do: "store_error"

  defp ordinary(%Envelope{class: "fact"} = envelope, content, state) do
    case Ledger.answer(state.ledger, envelope.id) do
      {class, answer, position} ->
        reply(envelope, class, answer, position)
        {:noreply, state}

      nil ->
        {result, state} = store(Map.put(state, :sender, envelope.sender), envelope.kind, content)
        state = Map.delete(state, :sender)
        answer(state, envelope, content, result)
        {:noreply, state}
    end
  end

  defp ordinary(%Envelope{class: "read"} = envelope, content, state) do
    {answer, state} = ordinary_read(envelope, content, state)
    reply(envelope, "answer", answer, nil)
    {:noreply, state}
  end

  defp ordinary_read(envelope, content, state) do
    {answer, state} = answered_read(state, envelope.kind, content || %{})
    {Map.put(answer, "position", read_position(state)), state}
  end

  # A read's answer, not sent: what Facts answers itself, and what the Bus answers in the
  # sending process (`answer/3`). The reads of a run's inputs are not among them.
  defp read_answer(%Envelope{kind: @page} = envelope, content, state) do
    if String.starts_with?(envelope.sender || "", "control/"),
      do: ordinary_read(envelope, content, state),
      else: {%{"error" => "page reads require Control", "code" => "forbidden"}, state}
  end

  defp read_answer(envelope, content, state) do
    case AtlasFacts.Guidance.role(context(state), envelope.kind) do
      nil -> ordinary_read(envelope, content, state)
      role -> {guidance_read(state, role, content), state}
    end
  end

  # The position a read is answered at: Facts' own, or the one published with the copy
  # an outside read is answered from.
  defp read_position(%{position: position}), do: position
  defp read_position(state), do: Ledger.position(state.ledger)

  @doc """
  The Bus's reader (`AtlasBus.answer_reads/1`): a read answered in the process that sent
  it, from the copy as Facts last published it (`AtlasFacts.Cache.consistently/2`), as
  Facts would answer it. `:pass` sends it to Facts: before Facts has rela's schema, for a
  kind rela does not describe, for what asks rela itself (`_description`,
  `_flow_recovery`), for a run's inputs (that read may write) and for a read of one
  fact that has no version yet, which Facts reads from rela once (`AtlasFacts.Cache`).
  """
  @pass {__MODULE__, :pass}

  def answer(reader, %Envelope{} = envelope, content) do
    case Cache.consistently(reader.cache, &answer_here(reader, &1, envelope, content)) do
      {:ok, {:answer, answer}} -> {:answer, answer}
      _ -> :pass
    end
  catch
    @pass -> :pass
    # A fact with no version yet (listed at start): Facts reads its version, once.
    {Cache, :unversioned} -> :pass
  end

  defp answer_here(_reader, %{description: nil}, _envelope, _content), do: :pass

  defp answer_here(reader, published, envelope, content) do
    state =
      Map.merge(reader, %{
        rela: reader.cache,
        ledger: nil,
        description: published.description,
        position: published.position,
        outside: true
      })

    if here?(state, envelope.kind, content) do
      {answer, _state} = read_answer(envelope, content, state)
      {:answer, answer}
    else
      :pass
    end
  end

  defp here?(_state, kind, _content) when kind in [@description, @recovery], do: false
  defp here?(_state, kind, _content) when kind in [@page, @position], do: true

  defp here?(state, kind, content) do
    context = context(state)

    cond do
      AtlasFacts.FlowInputs.kind?(context, kind) and match?(%{"run" => _}, content) -> false
      AtlasFacts.Guidance.role(context, kind) != nil -> true
      true -> match?(%{"plural" => _}, Description.kind(state.description, kind))
    end
  end

  # A read of facts says what it depended on (`AtlasFacts.Freshness.Deps`); a page says
  # it per answer, and the description and the position depend on no fact.
  defp answered_read(state, kind, content) when kind in [@description, @page, @position],
    do: read(state, kind, content)

  defp answered_read(state, kind, content) do
    {{answer, state}, frame} = Deps.collect(fn -> read(state, kind, content) end)
    {Deps.attach(answer, frame), state}
  end

  defp answer(state, envelope, content, result) do
    about = %{"op" => content_op(content), "key" => content_key(content)}
    # Who or what made the change and why ("GitHub connector, read at …"), when said.
    about =
      for name <- ["cause", "by"],
          is_binary(content[name]),
          into: about,
          do: {name, content[name]}

    case result do
      :stored ->
        about = Map.put(about, "changes", changes(state, envelope.kind, about["key"]))
        position = Ledger.stored(state.ledger, envelope.id, about)
        remember_links(state, envelope.kind, content, about, position)
        reply(envelope, "stored", about, position)

      {:refused, reasons} ->
        answer(state, envelope, content, {:refused, reasons, nil})

      # A code says why in a way a sender can act on: "exists" or "reserved" (the id is
      # taken), so a sender that made the id up can try the next one.
      {:refused, reasons, code} ->
        refusal = Map.put(about, "reasons", reasons)
        refusal = if code, do: Map.put(refusal, "code", code), else: refusal
        Ledger.refused(state.ledger, envelope.id, refusal)
        reply(envelope, "refused", refusal, nil)

      # Not recorded: the same id may be stored once rela is back.
      :unavailable ->
        refusal =
          Map.merge(about, %{"code" => "not_ready", "reasons" => ["rela is not reachable"]})

        reply(envelope, "refused", refusal, nil)

      # rela answered but failed: not recorded either, so the same id may be stored later.
      {:unavailable, reason} ->
        reply(envelope, "refused", Map.put(about, "reasons", [reason]), nil)
    end
  end

  # What the write changed (docs/design/page-freshness.md §1.2): every fact rela accepted
  # a write of while this one was handled, the fact it is about first.
  defp changes(state, kind, key), do: Changes.of(state[:changes], state.description, {kind, key})

  # The fact that set each link it names: when, by whom, why (`AtlasFacts.Links`).
  defp remember_links(state, kind, %{"op" => "delete", "key" => key}, _about, _position) do
    Cache.changing(state.cache)
    Links.forget(state.links, kind, key)
  end

  defp remember_links(state, kind, %{"key" => key, "links" => links}, about, position)
       when is_map(links) do
    Cache.changing(state.cache)

    entry =
      about
      |> Map.take(["by", "cause"])
      |> Map.merge(%{"since" => now(), "position" => position})

    for {relation, keys} <- links, do: Links.record(state.links, kind, key, relation, keys, entry)
    :ok
  end

  defp remember_links(_state, _kind, _content, _about, _position), do: :ok

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp reply(envelope, class, content, position) do
    case deliver(Envelope.reply(envelope, class, position: position), content) do
      :ok -> :ok
      error -> Logger.warning("Facts could not answer #{envelope.id}: #{inspect(error)}")
    end
  end

  # rela's schema, as rela serves it, read every time it is asked for. One that is not the
  # model's (rela was restarted with another build) is no schema Facts writes by. The
  # first one Facts has also loads every fact (`AtlasFacts.Cache`): none is answered before.
  # Outside Facts nothing asks rela: Facts answers that read.
  defp describe(%{outside: true}), do: throw(@pass)

  defp describe(state) do
    with {:ok, served} <- Rela.description(state.rela) do
      case AtlasFacts.Model.mismatch(state.model, served) do
        nil ->
          if Cache.loaded?(state.cache),
            do: {:ok, served},
            else: with(:ok <- Cache.load(state.cache, served), do: {:ok, served})

        reason ->
          Logger.error(reason)
          {:error, {:failed, reason}}
      end
    end
  end

  # Reads

  defp read(state, @description, _content) do
    case describe(state) do
      {:ok, description} -> {%{"description" => description}, %{state | description: description}}
      {:error, reason} -> {read_error(reason), state}
    end
  end

  # How far Facts is: the position every answer carries, and nothing else.
  defp read(state, @position, _content), do: {%{}, state}

  defp read(%{description: nil} = state, @page, _content),
    do: {read_error(:unavailable), state}

  # A page's reads (`"reads" => [[kind, content]]`), each answered as that read alone
  # would be, in order, from one snapshot: one position, and lists read once per page.
  defp read(state, @page, %{"reads" => reads} = content) when is_list(reads) do
    entities = state.description["entities"] || %{}

    valid? =
      map_size(content) == 1 and reads != [] and length(reads) <= @page_reads and
        Enum.all?(reads, fn
          [kind, read] when is_binary(kind) and is_map(read) ->
            is_binary(get_in(entities, [kind, "plural"])) and
              Enum.all?(Map.keys(read), &(&1 in @page_read_keys))

          _ ->
            false
        end)

    if valid? do
      key = make_ref()
      Process.put(key, %{})

      try do
        {answers, state} =
          Enum.map_reduce(reads, Map.put(state, :page_lists, key), fn [kind, read], state ->
            {answer, state} = page_answer(state, kind, read)
            {Map.put(answer, "position", read_position(state)), state}
          end)

        {%{"answers" => answers}, Map.delete(state, :page_lists)}
      after
        Process.delete(key)
      end
    else
      {answered("invalid page reads"), state}
    end
  end

  defp read(state, @page, _content),
    do: {answered("page reads require a bounded list of reads of described kinds"), state}

  defp read(state, kind, content) do
    with {:ok, spec, state} <- kind_spec(state, kind) do
      answer =
        case content do
          %{"key" => key, "plain" => true} ->
            read_plain(state, kind, spec, key)

          %{"key" => key} ->
            read_one(state, kind, spec, key, content["incoming"] != false)

          %{"linked" => linked} when is_map(linked) ->
            read_all(state, kind, spec, linked, content["plain"] != true)

          _ ->
            read_all(state, kind, spec, %{}, true)
        end

      {if(content["presentation"] == true, do: present(state, kind, answer), else: answer), state}
    else
      {:error, :unavailable, state} -> {read_error(:unavailable), state}
      {:error, reason, state} -> {%{"error" => reason, "error_kind" => "answered"}, state}
    end
  end

  # A read in a page is answered as it would be alone: a guidance record by Guidance (with
  # its own rules for what may be read), any other fact as an ordinary read.
  defp page_answer(state, kind, read) do
    case AtlasFacts.Guidance.role(context(state), kind) do
      nil ->
        answered_read(state, kind, read)

      role ->
        case AtlasFacts.Guidance.read(state.rela, context(state), role, read) do
          {:ok, answer} ->
            {answer, state}

          {:error, reason} ->
            {%{"error" => inspect(reason), "code" => guidance_code(reason)}, state}
        end
    end
  end

  # What a read could not do, and whether rela answered at all: "unreachable" (no
  # connection) or "answered" (rela said no, or failed), with rela's own words.
  defp read_error(:unavailable),
    do: %{"error" => "rela is not reachable", "error_kind" => "unreachable"}

  defp read_error({:invalid, problems}),
    do: answered("rela answered with an error: " <> Enum.join(problems, "; "))

  defp read_error({:failed, text}), do: answered(text)
  defp read_error(:not_found), do: answered("rela answered: not found")
  defp read_error(other), do: answered("rela answered with an error: #{inspect(other)}")

  defp answered(text), do: %{"error" => text, "error_kind" => "answered"}

  # `progress?` false (a plain read): the facts and their links only, no progress.
  defp read_all(state, kind, spec, linked, progress?) do
    with {:ok, linked} <- linked_keys(state, linked),
         {:ok, facts} <- collection(state, spec["plural"]),
         facts =
           Enum.filter(facts, fn fact ->
             Enum.all?(linked, fn {rel, keys} ->
               Enum.any?(fact.links[rel] || [], &(&1 in keys))
             end)
           end),
         {:ok, facts} <- if(progress?, do: with_progress(state, kind, facts), else: {:ok, facts}) do
      # Which facts are in it: every fact of the kind, or those that point at the keys.
      if linked == %{},
        do: Deps.kind(kind),
        else: for({relation, keys} <- linked, key <- keys, do: Deps.linked(relation, key))

      for fact <- facts, do: Deps.key(kind, fact.key)
      %{"facts" => Enum.map(facts, &wire(state, kind, &1))}
    else
      {:error, reason} -> read_error(reason)
    end
  end

  # `"linked" => %{relation => key}`: the facts that point at `key`. The key may also be a
  # condition on the fact the relation points at, one step on (`%{relation => key}` of
  # that fact): the facts whose Assignment points at someone, say. `%{relation => [keys]}`.
  defp linked_keys(state, linked) do
    Enum.reduce_while(linked, {:ok, %{}}, fn
      {relation, key}, {:ok, acc} when is_binary(key) ->
        {:cont, {:ok, Map.put(acc, relation, [key])}}

      {relation, %{} = inner}, {:ok, acc} ->
        with [to] <- get_in(state.description, ["relations", relation, "to"]),
             plural when is_binary(plural) <-
               get_in(state.description, ["entities", to, "plural"]),
             {:ok, facts} <- collection(state, plural) do
          # Which facts meet the condition: those that point at its keys.
          for {rel, key} <- inner, do: Deps.linked(rel, key)

          keys =
            for fact <- facts,
                Enum.all?(inner, fn {rel, key} -> key in (fact.links[rel] || []) end),
                do: fact.key

          {:cont, {:ok, Map.put(acc, relation, keys)}}
        else
          {:error, _} = error -> {:halt, error}
          _ -> {:halt, {:error, {:failed, "#{relation} does not point at one described kind"}}}
        end

      {relation, _}, _acc ->
        {:halt, {:error, {:failed, "linked #{relation} needs a key or a condition"}}}
    end)
  end

  # Only the fact, as rela has it, with its links: one call to rela, for a reader that
  # needs no progress, completion or what points at it (Flow walking up to the parents).
  defp read_plain(state, kind, spec, key) do
    Deps.key(kind, key)

    case Rela.get(state.rela, spec["plural"], key) do
      {:ok, fact} -> %{"fact" => wire(state, kind, fact)}
      {:error, :not_found} -> %{"fact" => nil}
      {:error, reason} -> read_error(reason)
    end
  end

  # `full?` false (`"incoming": false`): the fact with its progress and completion, without
  # what points at it, the kinds of its links, its history or its copy: what Flow needs.
  # One fact depends on itself, found or not: a fact made later is a change of it.
  defp read_one(state, kind, spec, key, false) do
    Deps.key(kind, key)

    with {:ok, fact} <- Rela.get(state.rela, spec["plural"], key),
         {:ok, [fact]} <- with_progress(state, kind, [fact]) do
      %{"fact" => wire(state, kind, fact)}
    else
      {:error, :not_found} -> %{"fact" => nil}
      {:error, reason} -> read_error(reason)
    end
  end

  defp read_one(state, kind, spec, key, true) do
    Deps.key(kind, key)

    with {:ok, fact} <-
           Rela.get(state.rela, spec["plural"], key),
         {:ok, [fact]} <- with_progress(state, kind, [fact]),
         {:ok, incoming} <- incoming(state, kind, spec, key) do
      wired = wire(state, kind, fact)

      wired =
        case link_kinds(state, kind, wired["links"]) do
          kinds when kinds == %{} -> wired
          kinds -> Map.put(wired, "link_kinds", kinds)
        end

      answer = %{
        "fact" => wired,
        "incoming" => incoming,
        "history" => Links.all(state.links, kind, key)
      }

      case Copies.get(kind, key) do
        nil -> answer
        copy -> Map.put(answer, "copy", copy)
      end
    else
      {:error, :not_found} -> %{"fact" => nil}
      {:error, reason} -> read_error(reason)
    end
  end

  defp incoming(state, kind, spec, key) do
    Description.incoming(state.description, kind)
    |> Enum.reduce_while({:ok, %{}}, fn {relation, _from}, {:ok, acc} ->
      Deps.linked(relation, key)

      case Rela.incoming(state.rela, spec["plural"], key, relation) do
        {:ok, keys} -> {:cont, {:ok, Map.put(acc, relation, keys)}}
        error -> {:halt, error}
      end
    end)
  end

  # The presentation of each answered fact of a kind work is written on
  # (`AtlasFacts.Presentation`), derived from the facts it depends on: the subject the work
  # is on and the subject's runs. A read of those that fails fails the answer: not knowing
  # is never "nothing to do". A fact no presenter's subject points at has none (nil).
  defp present(state, kind, answer) do
    case AtlasFacts.Presentation.of_kind(state.model.presentation(), kind) do
      [] ->
        answer

      presenters ->
        case answer do
          %{"fact" => %{} = fact} ->
            case presentation(state, presenters, fact) do
              {:ok, view} -> put_in(answer, ["fact", "presentation"], view)
              {:error, reason} -> read_error(reason)
            end

          %{"facts" => facts} when is_list(facts) ->
            Enum.reduce_while(facts, {:ok, []}, fn fact, {:ok, acc} ->
              case presentation(state, presenters, fact) do
                {:ok, view} -> {:cont, {:ok, [Map.put(fact, "presentation", view) | acc]}}
                {:error, reason} -> {:halt, {:error, reason}}
              end
            end)
            |> case do
              {:ok, presented} -> Map.put(answer, "facts", Enum.reverse(presented))
              {:error, reason} -> read_error(reason)
            end

          _ ->
            answer
        end
    end
  end

  defp presentation(state, presenters, fact) do
    Enum.reduce_while(presenters, {:ok, nil}, fn presenter, {:ok, nil} ->
      with {:ok, %{} = subject} <- presented_subject(state, presenter, fact),
           {:ok, runs} <- subject_runs(state, presenter, subject["key"]),
           completed? = fn -> subject_completed?(state, presenter["subject"], subject) end,
           view = AtlasFacts.Presentation.view(presenter, fact, subject, runs, completed?),
           {:ok, waiting} <- waiting_for(state, presenter, subject, view) do
        {:halt, {:ok, Map.put(view, "waiting_for", waiting)}}
      else
        {:ok, nil} -> {:cont, {:ok, nil}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # What the subject of an active run waits for when its subflow takes its subjects in
  # order (`AtlasBus.Order`): the key of the first of those under its parent that the
  # subflow did not finish, when that is another; nil otherwise.
  defp waiting_for(state, presenter, subject, %{"status" => "active", "flow" => flow}) do
    order = Enum.find_value(presenter["flows"] || [], &(&1["name"] == flow && &1["order"]))
    relation = order && order["within"]

    case relation && links_of(subject["raw"], relation) do
      [parent | _] ->
        Deps.linked(relation, parent)
        mapping = state.model.run_mapping()
        f = mapping["fields"]

        with {:ok, facts} <- collection(state, plural(state, presenter["subject"])),
             {:ok, runs} <- collection(state, plural(state, mapping["kind"])),
             siblings = for(s <- facts, parent in links_of(s, relation), do: s),
             {:ok, siblings} <- with_progress(state, presenter["subject"], siblings) do
          keys = MapSet.new(siblings, & &1.key)

          latest =
            for run <- runs,
                p = run.properties,
                p[f["flow"]] == flow,
                p[f["subject_kind"]] == presenter["subject"],
                p[f["subject_key"]] in keys,
                reduce: %{} do
              acc ->
                Map.update(acc, p[f["subject_key"]], p, fn held ->
                  if (p[f["generation"]] || 0) > (held[f["generation"]] || 0), do: p, else: held
                end)
            end

          {:ok,
           AtlasBus.Order.waiting_for(
             subject["key"],
             for s <- siblings do
               Deps.key(presenter["subject"], s.key)
               p = latest[s.key]
               run = p && %{"flow" => flow, "status" => p[f["status"]], "state" => p[f["state"]]}

               %{
                 "key" => s.key,
                 "order" => s.properties[order["by"]],
                 "finished" =>
                   AtlasBus.Order.finished?(order, flow, run, s[:completion]["done"] == true)
               }
             end
           )}
        end

      _ ->
        {:ok, nil}
    end
  end

  defp waiting_for(_state, _presenter, _subject, _view), do: {:ok, nil}

  # The fact the work is on: the fact itself, or the subject whose `on` points at it.
  defp presented_subject(state, presenter, fact) do
    on = presenter["on"]
    if on, do: Deps.linked(on, fact["key"])

    with {:ok, subjects} <- collection(state, plural(state, presenter["subject"])) do
      found? = fn s -> if on, do: fact["key"] in links_of(s, on), else: s.key == fact["key"] end

      case Enum.find(subjects, found?) do
        nil ->
          {:ok, nil}

        found ->
          Deps.key(presenter["subject"], found.key)
          {:ok, %{"key" => found.key, "values" => found.properties, "raw" => found}}
      end
    end
  end

  # The runs of the presenter's subflows on the subject, as the run mapping names their
  # fields: those of every generation (the presentation takes the latest), each with when
  # it entered its state (`since`), the keys its supervision relation links (`supervisor`;
  # none without supervision) and the fact that set that link (`supervisor_origin`,
  # `AtlasFacts.Links`; IS-Atlas-47).
  defp subject_runs(state, presenter, key) do
    mapping = state.model.run_mapping()
    names = for f <- presenter["flows"] || [], do: f["name"]
    supervised_by = get_in(mapping || %{}, ["supervision", "relation"])

    if mapping == nil or names == [] do
      {:ok, []}
    else
      Deps.kind(mapping["kind"])
      f = mapping["fields"]

      with {:ok, facts} <- collection(state, plural(state, mapping["kind"])) do
        runs =
          for run <- facts,
              p = run.properties,
              p[f["subject_kind"]] == presenter["subject"],
              p[f["subject_key"]] == key,
              p[f["flow"]] in names,
              do: %{
                "key" => run.key,
                "flow" => p[f["flow"]],
                "generation" => p[f["generation"]],
                "status" => p[f["status"]],
                "state" => p[f["state"]],
                "since" => f["entered_at"] && p[f["entered_at"]],
                "supervisor" => if(supervised_by, do: run.links[supervised_by] || [], else: []),
                "supervisor_origin" =>
                  supervised_by &&
                    Links.origins(state.links, mapping["kind"], run.key, run.links)[
                      supervised_by
                    ]
              }

        {:ok, runs}
      end
    end
  end

  defp subject_completed?(state, kind, %{"raw" => raw}) do
    Deps.key(kind, raw.key)

    case with_progress(state, kind, [raw]) do
      {:ok, [fact]} -> get_in(fact, [:completion, "done"]) == true
      # Not knowing is never "completed": reopened work is said to be so.
      _ -> false
    end
  end

  # What the model works out for each fact, from the facts it reads: how far it is,
  # whether it is completed, to be reviewed, late. What the model reads for them is a
  # dependency of the answer, as precisely as it asks for it (docs/design/page-freshness.md
  # F10): the facts that point at some keys (`linked`), the facts with some keys (`key`).
  # Each kind is listed from rela once per read, however often the model asks.
  defp with_progress(state, kind, facts) do
    memo = make_ref()
    Process.put(memo, %{})

    listed = fn of ->
      case Map.fetch(Process.get(memo), of) do
        {:ok, facts} ->
          {:ok, facts}

        :error ->
          with {:ok, facts} <- collection(state, plural(state, of)) do
            Process.put(memo, Map.put(Process.get(memo), of, facts))
            {:ok, facts}
          end
      end
    end

    lookup = %{
      "linked" => fn of, relation, keys ->
        for key <- keys, do: Deps.linked(relation, key)

        with {:ok, all} <- listed.(of),
             do:
               {:ok, Enum.filter(all, &Enum.any?(links_of(&1, relation), fn k -> k in keys end))}
      end,
      "facts" => fn of, keys ->
        for key <- keys, do: Deps.key(of, key)
        with {:ok, all} <- listed.(of), do: {:ok, Enum.filter(all, &(&1.key in keys))}
      end
    }

    try do
      with {:ok, derived} <- state.model.derived(kind, facts, lookup) do
        {:ok, Enum.zip_with(facts, derived, &derive/2)}
      end
    after
      Process.delete(memo)
    end
  end

  defp links_of(fact, relation), do: (fact[:links] || %{})[relation] || []

  # When a derived value changes by time alone (`until`), the answer says when.
  defp derive(fact, derived) do
    Deps.until(derived["until"])

    for {name, key} <- [
          progress: "progress",
          completion: "completion",
          review: "review",
          late: "late"
        ],
        Map.has_key?(derived, key),
        into: fact,
        do: {name, derived[key]}
  end

  # Only successful raw lists are shared inside this synchronous page request.
  defp collection(%{page_lists: key} = state, plural) do
    lists = Process.get(key)

    case Map.fetch(lists, plural) do
      {:ok, facts} ->
        {:ok, facts}

      :error ->
        case Rela.list(state.rela, plural) do
          {:ok, facts} = result ->
            Process.put(key, Map.put(lists, plural, facts))
            result

          error ->
            error
        end
    end
  end

  defp collection(state, plural), do: Rela.list(state.rela, plural)

  defp wire(state, kind, fact) do
    links = fact[:links] || %{}

    wired = %{
      "key" => fact.key,
      "values" => fact.properties,
      "links" => links,
      "origins" => Links.origins(state.links, kind, fact.key, links),
      "version" => fact.version
    }

    wired = if fact[:progress], do: Map.put(wired, "progress", fact.progress), else: wired
    wired = if fact[:completion], do: Map.put(wired, "completion", fact.completion), else: wired
    wired = if fact[:review], do: Map.put(wired, "review", fact.review), else: wired

    # Late is worked out on every read, plain ones too: it costs no read.
    late =
      if Map.has_key?(fact, :late) do
        fact.late
      else
        {:ok, [derived]} = state.model.derived(kind, [fact], %{})
        Deps.until(derived["until"])
        derived["late"]
      end

    if late == nil, do: wired, else: Map.put(wired, "late", late)
  end

  # Facts

  defp store(state, kind, %{"op" => op, "key" => key} = content) when is_binary(key) do
    case kind_spec(state, kind) do
      {:ok, spec, state} ->
        result =
          try do
            store(state, kind, spec, op, key, content)
          catch
            {@lookup_failed, error} -> failure(error)
          end

        {result, state}

      {:error, :unavailable, state} ->
        {:unavailable, state}

      {:error, reason, state} ->
        {{:refused, [reason]}, state}
    end
  end

  defp store(state, _kind, _content), do: {{:refused, ["a fact needs an op and a key"]}, state}

  # What the write makes (the model's `with_change/3`), checked by the model (`check/4`)
  # once the facts it links to are known to exist.
  defp store(state, kind, spec, op, key, content) do
    values = content["values"] || %{}

    with :ok <- strict_version(content, op),
         {:ok, _} <- Description.targets(state.description, kind, content["links"] || %{}) do
      lookup = lookup(state, kind, spec, op, key)

      change = %{
        "op" => op,
        "key" => key,
        "values" => values,
        "links" => content["links"] || %{},
        "by" => content["by"]
      }

      changes = state.model.with_change(kind, change, lookup)
      [own] = for %{"as" => "fact"} = c <- changes, do: c
      # The model may derive values on the same fact (for example an immutable
      # offered-options history). Authorization checks the caller's original change;
      # the backend stores the complete model-derived change atomically.
      values = own["values"] || values

      parts =
        for %{"as" => "component"} = c <- changes,
            do: {c["relation"], c["kind"], c["key"], c["values"]}

      replaced = for %{"as" => "replaced"} = c <- changes, do: {c["key"], c["values"]}
      # Whom the writer assists (IS-Atlas-47), for the rules that take it: who puts in a
      # fact an agent creates for them (`create.producer`, IS-Atlas-70).
      actor = %{
        "by" => content["by"],
        "sender" => state[:sender],
        "assists" => AtlasBus.Actors.assisted(content["by"])
      }

      with {:ok, targets} <- Description.targets(state.description, kind, own["links"] || %{}),
           {:ok, targets} <- target_kinds(state, op, targets),
           :ok <- targets_exist(state, op, targets),
           :ok <-
             checked(
               state.model.check(
                 kind,
                 change
                 |> Map.put("links", own["links"] || %{})
                 |> Map.put("guard_values", values),
                 actor,
                 lookup
               )
             ),
           :ok <- AtlasFacts.FlowInputs.fence(state.rela, context(state), kind, key, values) do
        if state[:validate_only] do
          case Description.check(spec, values, :change) do
            :ok -> :stored
            {:error, problems} -> {:refused, problems}
          end
        else
          guard_version = lookup["guard_version"].()
          version = content["version"] || guard_version

          state
          |> Map.put(:strict_version, content["strict_version"] == true or guard_version != nil)
          |> Map.put(:replay_identity_missing, replay_identity_missing?(spec, content["values"] || %{}))
          |> write(spec, op, key, values, version, targets, content["was"], parts)
          |> replace(state, spec, replaced, op, key)
        end
      end
    else
      {:error, problems} -> {:refused, problems}
    end
  end

  defp strict_version(%{"strict_version" => true} = content, op) do
    if op == "change" and not is_nil(content["version"]),
      do: :ok,
      else: {:error, ["strict version requires a change and a version"]}
  end

  defp strict_version(_content, _op), do: :ok

  defp checked(:ok), do: :ok
  defp checked({:refuse, reasons}), do: {:refused, reasons}

  # Facts' reader for the model's rules, on the store as it is now. The fact as stored is
  # read once, when a rule asks; a read that fails stops the write (not recorded).
  defp lookup(state, kind, spec, op, key) do
    memo = make_ref()

    current = fn ->
      case Process.get(memo) do
        {:read, fact} ->
          fact

        {:guarded, fact} ->
          fact

        nil ->
          fact =
            case current(state, spec, op, key) do
              {:ok, fact} -> fact
              error -> throw({@lookup_failed, error})
            end

          Process.put(memo, {:read, fact})
          fact
      end
    end

    %{
      "current" => current,
      "guard_current" => fn ->
        fact = current.()

        case fact do
          %{"version" => version} when is_binary(version) and version != "" ->
            Process.put(memo, {:guarded, fact})
            fact

          _ ->
            throw({@lookup_failed, {:error, :unavailable}})
        end
      end,
      "guard_version" => fn ->
        case Process.get(memo) do
          {:guarded, fact} -> fact["version"]
          _ -> nil
        end
      end,
      "fact" => fn of, at ->
        case Rela.get(state.rela, plural(state, of), at) do
          {:ok, fact} -> fact
          _ -> nil
        end
      end,
      "list" => fn of -> collection(state, plural(state, of)) end,
      "incoming" => fn of, at, relation ->
        case Rela.incoming(state.rela, plural(state, of), at, relation) do
          {:ok, keys} -> keys
          _ -> []
        end
      end,
      "fingerprint" => &AtlasBus.SubjectFingerprint.of/2,
      "kind" => kind
    }
  end

  defp current(_state, _spec, "create", _key), do: {:ok, nil}

  defp current(state, spec, _op, key) do
    case Rela.get(state.rela, spec["plural"], key) do
      {:ok, fact} ->
        {:ok, %{"values" => fact.properties, "links" => fact[:links] || %{}, "version" => fact.version}}
      {:error, :not_found} -> {:ok, nil}
      error -> error
    end
  end

  # A stored fact marks the facts it replaces in the same write. When one cannot be
  # marked, the write is not recorded, so sending it again finishes it.
  defp replace(:stored, state, spec, replaced, op, key) when op in ["create", "change"] do
    Enum.reduce_while(replaced, :stored, fn {old, set}, :stored ->
      case Rela.change(state.rela, spec["plural"], old, set, nil, %{}) do
        {:ok, []} ->
          {:cont, :stored}

        other ->
          {:halt,
           {:unavailable,
            "#{key} is stored, but #{old} is not marked yet (#{inspect(other)}); send it again"}}
      end
    end)
  end

  defp replace(result, _state, _spec, _replaced, _op, _key), do: result

  defp write(state, spec, op, key, values, version, targets, was, []) do
    if op == "delete",
      do: delete(state, spec, key, version),
      else:
        store(
          state.rela, spec, op, key, values, version, targets, was,
          state[:strict_version], state[:replay_identity_missing]
        )
  end

  # A fact with components: they are made first (the fact links to them), and when the fact
  # is then not stored, the ones made here go again.
  defp write(state, spec, "create", key, values, _version, targets, _was, parts) do
    values = Map.reject(values, fn {_, v} -> v in [nil, ""] end)
    plural = spec["plural"]

    with :ok <- both(Description.check_key(spec, key), Description.check(spec, values, :create)),
         {:ok, []} <- Rela.check_create(state.rela, plural, key, values, targets),
         {:ok, made} <- make_parts(state, parts) do
      linked =
        for {relation, kind, part, _} <- parts, into: targets, do: {relation, {kind, [part]}}

      case Rela.create(state.rela, plural, key, values, linked) do
        {:ok, _warnings} ->
          :stored

        error ->
          unmake_parts(state, made)

          case error do
            {:error, :exists} ->
              resent_create(state.rela, plural, key, values, targets, state[:replay_identity_missing])
            error -> failure(error)
          end
      end
    else
      {:ok, warnings} -> {:refused, warnings}
      {:error, :exists} ->
        resent_create(state.rela, plural, key, values, targets, state[:replay_identity_missing])
      {:refused, _} = refused -> refused
      {:refused, _, _} = refused -> refused
      error -> failure(error)
    end
  end

  # Deleted with the fact, by the keys they are made with, so a resent delete finds them too.
  defp write(state, spec, "delete", key, _values, version, _targets, _was, parts) do
    case delete(state, spec, key, version) do
      :stored ->
        Enum.reduce_while(parts, :stored, fn {_relation, kind, part, _}, :stored ->
          case Rela.delete(state.rela, plural(state, kind), part, nil) do
            :ok -> {:cont, :stored}
            {:error, :not_found} -> {:cont, :stored}
            error -> {:halt, failure(error)}
          end
        end)

      other ->
        other
    end
  end

  defp write(state, spec, op, key, values, version, targets, was, _parts),
    do:
      store(
        state.rela, spec, op, key, values, version, targets, was,
        state[:strict_version], state[:replay_identity_missing]
      )

  # Made here: `{:ok, [{kind, key}]}`; one there already with the same values is kept and
  # not made again (a resent create).
  defp make_parts(state, parts) do
    Enum.reduce_while(parts, {:ok, []}, fn {_relation, kind, part, values}, {:ok, made} ->
      spec = Description.kind(state.description, kind) || %{}

      result =
        with :ok <- Description.check(spec, values, :create) do
          case Rela.create(state.rela, spec["plural"], part, values, %{}) do
            {:ok, []} -> :made
            {:ok, warnings} -> {:refused, warnings}
            {:error, :exists} ->
              resent_create(
                state.rela, spec["plural"], part, values, %{}, replay_identity_missing?(spec, values)
              )
            error -> failure(error)
          end
        else
          {:error, problems} -> {:refused, Enum.map(problems, &"#{part}: #{&1}")}
        end

      case result do
        :made -> {:cont, {:ok, [{kind, part} | made]}}
        :stored -> {:cont, {:ok, made}}
        other -> unmake_parts(state, made) && {:halt, other}
      end
    end)
  end

  defp unmake_parts(state, made) do
    for {kind, part} <- made, do: Rela.delete(state.rela, plural(state, kind), part, nil)
    true
  end

  defp plural(state, kind), do: get_in(state.description, ["entities", kind, "plural"])

  defp store(rela, spec, "create", key, values, _version, targets, _was, _strict, missing_identity) do
    values = Map.reject(values, fn {_, v} -> v in [nil, ""] end)
    plural = spec["plural"]

    with :ok <- both(Description.check_key(spec, key), Description.check(spec, values, :create)),
         {:ok, []} <- Rela.check_create(rela, plural, key, values, targets),
         {:ok, _warnings} <- Rela.create(rela, plural, key, values, targets) do
      :stored
    else
      {:ok, warnings} -> {:refused, warnings}
      {:error, :exists} -> resent_create(rela, plural, key, values, targets, missing_identity)
      error -> failure(error)
    end
  end

  # The links of a change replace the relation's keys: a move to another parent.
  defp store(rela, spec, "change", key, values, version, targets, was, strict, _missing_identity) do
    values = Map.new(values, fn {k, v} -> {k, if(v == "", do: nil, else: v)} end)
    plural = spec["plural"]

    with :ok <- Description.check(spec, values, :change),
         {:ok, []} <- Rela.change(rela, plural, key, values, version, targets) do
      :stored
    else
      # The current rela has already stored the change; say so instead of hiding it.
      {:ok, warnings} -> {:refused, ["rela stored it with warnings: " | warnings]}
      {:error, :version_mismatch} when strict ->
        {:refused, ["#{key} changed meanwhile; open it again"]}

      {:error, :version_mismatch} ->
        changed_meanwhile(rela, plural, key, values, targets, was)
      {:error, :not_found} -> {:refused, ["#{key} does not exist (any more)"]}
      error -> failure(error)
    end
  end

  defp store(_rela, _spec, op, _key, _values, _version, _targets, _was, _strict, _missing_identity),
    do: {:refused, ["unknown op #{inspect(op)}"]}

  defp delete(state, spec, key, version) do
    before_delete = Map.get(state, :before_delete, fn _ -> :ok end)

    result =
      case Rela.get(state.rela, spec["plural"], key) do
        {:ok, %{version: current}} when version != nil and current != version ->
          {:error, :version_mismatch}

        {:ok, fact} ->
          with :ok <- before_delete.(fact),
               do: Rela.delete(state.rela, spec["plural"], key, version)

        {:error, :not_found} ->
          # Generic absence remains idempotent; protected turn absence has already
          # required trusted deletion provenance in the dispatch guard.
          before_delete.(nil)

        error ->
          error
      end

    case result do
      :ok -> :stored
      {:error, :not_found} -> :stored
      {:error, :version_mismatch} -> {:refused, ["#{key} changed meanwhile; open it again"]}
      error -> failure(error)
    end
  end

  defp both(:ok, :ok), do: :ok
  defp both(first, second), do: {:error, problems(first) ++ problems(second)}

  defp problems(:ok), do: []
  defp problems({:error, problems}), do: problems

  # A create of an existing id: the same fact sent again (stored), or a clash (refused).
  defp resent_create(rela, plural, key, values, targets, missing_identity) do
    case Rela.get(rela, plural, key) do
      {:ok, fact} ->
        cond do
          not (same?(fact, values) and same_links?(fact, targets)) ->
            {:refused, ["#{key} already exists"], "exists"}

          missing_identity ->
            {:refused, ["#{key} already exists; its create identity cannot be proven"], "identity_unproven"}

          true ->
            :stored
        end

      {:error, :not_found} ->
        {:refused,
         [
           "#{key} was deleted a moment ago; rela keeps a deleted id reserved for a few " <>
             "minutes. Try again later, or use another id."
         ], "reserved"}

      error ->
        failure(error)
    end
  end

  defp replay_identity_missing?(spec, values) do
    case get_in(spec, ["create", "replay_identity"]) do
      nil -> false
      field -> Map.get(values, field) in [nil, ""]
    end
  end

  # A change on an old version: already applied (a resend) or a real conflict.
  # A change on an old version: already applied (a resend), applied now when only other
  # fields changed meanwhile, or a real conflict.
  defp changed_meanwhile(rela, plural, key, values, targets, was, tries \\ 3) do
    case Rela.get(rela, plural, key) do
      {:ok, fact} ->
        cond do
          same?(fact, values) and same_links?(fact, targets) ->
            :stored

          tries > 0 and untouched?(fact, values, targets, was) ->
            case Rela.change(rela, plural, key, values, fact.version, targets) do
              {:ok, []} ->
                :stored

              {:ok, warnings} ->
                {:refused, ["rela stored it with warnings: " | warnings]}

              {:error, :version_mismatch} ->
                changed_meanwhile(rela, plural, key, values, targets, was, tries - 1)

              error ->
                failure(error)
            end

          true ->
            {:refused, ["#{key} changed meanwhile; open it again"]}
        end

      error ->
        failure(error)
    end
  end

  # Every field and relation the change sets still has the value its sender read.
  defp untouched?(fact, values, targets, was) when is_map(was) do
    Enum.all?(values, fn {name, _} ->
      Map.has_key?(was, name) and loose(fact.properties[name]) == loose(was[name])
    end) and
      Enum.all?(targets, fn {relation, _} ->
        Map.has_key?(was, relation) and
          Enum.sort(fact.links[relation] || []) == Enum.sort(List.wrap(was[relation]))
      end)
  end

  defp untouched?(_fact, _values, _targets, _was), do: false

  defp same_links?(fact, targets) do
    Enum.all?(targets, fn {relation, {_kind, keys}} ->
      Enum.sort(fact.links[relation] || []) == Enum.sort(keys)
    end)
  end

  # A relation that points at several kinds: which kind each
  # key is, found by reading it in each. rela takes one kind per link, so all keys of the
  # relation must be of one; a key of none, or of two, is refused.
  defp target_kinds(state, op, targets) when op in ["create", "change"] do
    Enum.reduce_while(targets, {:ok, %{}}, fn
      {relation, {kinds, keys}}, {:ok, acc} when is_list(kinds) ->
        case key_kinds(state, kinds, keys) do
          {:ok, kind} -> {:cont, {:ok, Map.put(acc, relation, {kind, keys})}}
          {:refused, _} = refused -> {:halt, refused}
        end

      {relation, target}, {:ok, acc} ->
        {:cont, {:ok, Map.put(acc, relation, target)}}
    end)
  end

  defp target_kinds(_state, _op, targets), do: {:ok, targets}

  # Removing the links: any of the kinds will do.
  defp key_kinds(_state, [kind | _], []), do: {:ok, kind}

  defp key_kinds(state, kinds, keys) do
    found =
      for key <- keys,
          into: %{},
          do: {key, Enum.filter(kinds, &kind_has?(state, &1, key))}

    case found |> Map.values() |> List.flatten() |> Enum.uniq() do
      [kind] ->
        if Enum.all?(found, fn {_, of} -> of == [kind] end),
          do: {:ok, kind},
          else: {:refused, missing_keys(found, kinds)}

      [] ->
        {:refused, missing_keys(found, kinds)}

      several ->
        {:refused,
         [
           "#{Enum.join(keys, ", ")} must all be one kind; they are #{Enum.join(several, " and ")}"
         ]}
    end
  end

  defp missing_keys(found, kinds) do
    for {key, []} <- found, do: "#{key} is not a #{Enum.join(kinds, " or ")}"
  end

  defp kind_has?(state, kind, key) do
    plural = get_in(state.description, ["entities", kind, "plural"])
    match?({:ok, _}, Rela.get(state.rela, plural, key))
  end

  # The kind of each key a fact links to through a relation that points at several kinds,
  # so a client can open it: `%{relation => %{key => kind}}`. Only for one fact.
  defp link_kinds(state, kind, links) do
    for {relation, %{"to" => [_, _ | _] = kinds, "from" => from}} <-
          state.description["relations"] || %{},
        kind in from,
        keys = links[relation] || [],
        keys != [],
        into: %{} do
      {relation,
       Map.new(keys, fn key ->
         found = Enum.find(kinds, &kind_has?(state, &1, key))
         if found, do: Deps.key(found, key)
         {key, found}
       end)}
    end
  end

  # The current rela answers 422 to a create that links to a missing fact, but stores the
  # fact anyway, without the link. So Facts checks the targets exist before it creates,
  # and before a change moves a fact, to say which one is missing.
  defp targets_exist(state, op, targets) when op in ["create", "change"] do
    missing =
      for {_relation, {kind, keys}} <- targets,
          key <- keys,
          Rela.get(state.rela, get_in(state.description, ["entities", kind, "plural"]), key) ==
            {:error, :not_found},
          do: "#{key} does not exist"

    if missing == [], do: :ok, else: {:refused, missing}
  end

  defp targets_exist(_state, _op, _targets), do: :ok

  defp same?(fact, values) do
    Enum.all?(values, fn {name, value} -> loose(fact.properties[name]) == loose(value) end)
  end

  defp loose(value) when value in [nil, ""], do: nil
  defp loose(value), do: to_string(value)

  defp failure({:error, :unavailable}), do: :unavailable
  defp failure({:error, {:failed, text}}), do: {:unavailable, text}
  defp failure({:error, {:invalid, problems}}), do: {:refused, problems}
  defp failure({:error, problems}) when is_list(problems), do: {:refused, problems}
  defp failure({:error, other}), do: {:refused, [inspect(other)]}

  # A kind rela describes has a plural (its collection). The schema is read again first,
  # in case rela was restarted since; one that is not the model's is said so.
  defp kind_spec(state, kind) do
    case state.description && Description.kind(state.description, kind) do
      %{"plural" => _} = spec ->
        {:ok, spec, state}

      _ ->
        case describe(state) do
          {:ok, description} ->
            state = %{state | description: description}

            case Description.kind(description, kind) do
              %{"plural" => _} = spec -> {:ok, spec, state}
              _ -> {:error, "rela does not describe #{inspect(kind)}", state}
            end

          {:error, {:failed, reason}} ->
            {:error, reason, state}

          {:error, _} ->
            {:error, :unavailable, state}
        end
    end
  end

  defp content_op(%{"op" => op}) when is_binary(op), do: op
  defp content_op(_), do: nil
  defp content_key(%{"key" => key}) when is_binary(key), do: key
  defp content_key(_), do: nil
end

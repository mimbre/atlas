defmodule AtlasFacts.Server do
  @moduledoc """
  Facts on the Bus: the store endpoint. Generic: what a kind is, it reads from rela.

  - A `fact` is stored in rela and answered with one `stored` (acknowledgement and hint,
    with the fact's position) or one `refused` (final, with reasons). Never silence.
    A resent id gets its first answer again and is not stored twice.
  - A `read` is answered with the facts of a kind (all, or `"linked" => %{relation => key}`
    for those that point at `key`), one fact (`"key" => key`) with the keys of the facts
    that point at it and, for a copy of an outside fact, when a connector last read it
    (`"copy"`, see `AtlasFacts.Copies`), or (kind `_description`) rela's description.
    Facts carry their outgoing `links`, with the `origins` of those links (the fact that
    set each: since, by, cause; `AtlasFacts.Links`), and their `progress` when the
    description has a rule for their kind (`AtlasFacts.Progress`), and why they are
    completed (`completion`, `AtlasFacts.Completion`): worked out on every read, never
    stored. One fact also carries the `history` of its links.

  Fact content: `%{"op" => "create" | "change" | "delete", "key" => id,
  "values" => %{property => value}, "version" => version read before, or nil,
  "links" => %{relation => [keys]}, "cause" => why, optional, "by" => who, optional,
  "was" => %{property or relation => value or keys} on a change, optional}`.
  A fact's components (`AtlasFacts.Components`, its Assignment) are made in the same write,
  before it, and deleted with it; a component alone is not deleted while its fact exists.
  On a create the links are the fact's first; on a change each relation named is replaced
  by the keys given (`[]` removes its links), so a fact moves to another parent or an
  association is set or removed; the hint then reaches every listener of its kind, on
  the old parent's page and the new one's. The cause and who sent it are kept with
  Facts' answer and go along with the hint. A change on an old version is refused only
  when what it sets changed meanwhile: with `was` (the values and links the sender read)
  and every field and relation it sets still as it was, it is applied on the current
  version, so a write to other fields (Flow's, a connector's) never fails a user's save.
  """
  use GenServer

  require Logger

  alias AtlasBus.Envelope

  alias AtlasFacts.{
    Components,
    Copies,
    Description,
    Flows,
    Guards,
    Late,
    Ledger,
    Links,
    Progress,
    Rela
  }

  @description "_description"
  @page "_page"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

  @impl true
  def init(opts) do
    :ok = AtlasBus.attach(AtlasBus.store())
    dir = Keyword.fetch!(opts, :data_dir)

    {:ok,
     %{
       rela: Keyword.fetch!(opts, :rela),
       ledger: Ledger.open(dir),
       links: Links.open(dir),
       description: nil,
       extra: Keyword.get(opts, :description_extra)
     }}
  end

  @impl true
  def terminate(_reason, state) do
    Ledger.close(state.ledger)
    Links.close(state.links)
  end

  @impl true
  def handle_info({:atlas_bus, %Envelope{class: class} = envelope, content}, state)
      when class in ["fact", "read"] do
    {_, state} = ensure_description(state, envelope)

    binding = Ledger.request_identity(envelope, content)

    if class == "fact" and not Ledger.matches_request?(state.ledger, envelope.id, binding),
      do: refusal(envelope, :request_conflict, state),
      else: dispatch(envelope, content, state)
  end

  def handle_info({:atlas_bus, _envelope, _content}, state), do: {:noreply, state}

  defp dispatch(%Envelope{class: "read", kind: @page} = envelope, content, state) do
    if String.starts_with?(envelope.sender || "", "control/") do
      ordinary(envelope, content, state)
    else
      reply(
        envelope,
        "answer",
        %{"error" => "page reads require Control", "code" => "forbidden"},
        nil
      )

      {:noreply, state}
    end
  end

  defp dispatch(envelope, content, state) do
    case AtlasFacts.Guidance.role(state.description || %{}, envelope.kind) do
      nil ->
        if envelope.class == "fact" do
          case AtlasFacts.Guidance.authorize_turn(
                 state.rela,
                 state.description || %{},
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
               AtlasFacts.Guidance.deletion_target(state.description, fact) == target,
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
  defp ensure_description(state, %Envelope{class: "read", kind: @description}),
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
      {_, _, state} -> {:error, state}
    end
  end

  defp guidance(envelope, content, role, state) do
    result =
      if envelope.class == "fact",
        do:
          AtlasFacts.Guidance.write(state.rela, state.description, role, envelope, content, fn ->
            Ledger.reserve(state.ledger)
          end),
        else: AtlasFacts.Guidance.read(state.rela, state.description, role, content)

    case result do
      {:ok, answer} when envelope.class == "fact" ->
        position = answer["recorded_position"]
        reply(envelope, "stored", %{"key" => answer["key"], "fact" => answer}, position)

      {:ok, answer} ->
        reply(envelope, "answer", answer, nil)

      {:error, reason} ->
        class = if envelope.class == "read", do: "answer", else: "refused"

        reply(
          envelope,
          class,
          %{"error" => inspect(reason), "code" => guidance_code(reason)},
          nil
        )
    end

    {:noreply, state}
  end

  defp guidance_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp guidance_code(_), do: "store_error"

  defp ordinary(%Envelope{class: "fact"} = envelope, content, state) do
    case Ledger.answer(state.ledger, envelope.id) do
      {class, answer, position} ->
        reply(envelope, class, answer, position)
        {:noreply, state}

      nil ->
        {result, state} = store(state, envelope.kind, content)
        answer(state, envelope, content, result)
        {:noreply, state}
    end
  end

  defp ordinary(%Envelope{class: "read"} = envelope, content, state) do
    {answer, state} = read(state, envelope.kind, content || %{})
    reply(envelope, "answer", Map.put(answer, "position", Ledger.position(state.ledger)), nil)
    {:noreply, state}
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
        reply(envelope, "refused", Map.put(about, "reasons", ["rela is not reachable"]), nil)

      # rela answered but failed: not recorded either, so the same id may be stored later.
      {:unavailable, reason} ->
        reply(envelope, "refused", Map.put(about, "reasons", [reason]), nil)
    end
  end

  # The fact that set each link it names: when, by whom, why (`AtlasFacts.Links`).
  defp remember_links(state, kind, %{"op" => "delete", "key" => key}, _about, _position),
    do: Links.forget(state.links, kind, key)

  defp remember_links(state, kind, %{"key" => key, "links" => links}, about, position)
       when is_map(links) do
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
    case AtlasBus.send(Envelope.reply(envelope, class, position: position), content) do
      :ok -> :ok
      error -> Logger.warning("Facts could not answer #{envelope.id}: #{inspect(error)}")
    end
  end

  # rela's description, with Atlas's additions (`rela/atlas.json`) merged in, key by key.
  # The file is read every time, so a change to it needs no restart.
  defp describe(state) do
    with {:ok, description} <- Rela.description(state.rela) do
      description = Description.merge(description, extra(state.extra))

      # Flow definitions are checked before anyone runs them (rule 4).
      if is_map(description["flows"]),
        do: {:ok, Map.put(description, "flow_problems", Flows.check(description))},
        else: {:ok, description}
    end
  end

  defp extra(nil), do: %{}

  defp extra(path) do
    with {:ok, json} <- File.read(path),
         {:ok, extra} <- JSON.decode(json) do
      Map.drop(extra, ["_about"])
    else
      error ->
        Logger.warning(
          "Facts could not read #{path}: #{inspect(error)}; using rela's description alone"
        )

        %{}
    end
  end

  # Reads

  defp read(state, @description, _content) do
    case describe(state) do
      {:ok, description} -> {%{"description" => description}, %{state | description: description}}
      {:error, reason} -> {read_error(reason), state}
    end
  end

  defp read(%{description: nil} = state, @page, _content),
    do: {read_error(:unavailable), state}

  defp read(state, @page, %{"kinds" => kinds} = content) when is_list(kinds) do
    entities = state.description["entities"] || %{}

    valid? =
      map_size(content) == 1 and kinds != [] and length(kinds) <= map_size(entities) and
        Enum.all?(kinds, fn kind ->
          is_binary(kind) and is_binary(get_in(entities, [kind, "plural"])) and
            AtlasFacts.Guidance.role(state.description, kind) == nil
        end)

    if valid? do
      key = make_ref()
      Process.put(key, %{})

      try do
        {answers, state} =
          Enum.map_reduce(kinds, Map.put(state, :page_lists, key), fn kind, state ->
            {answer, state} = read(state, kind, %{})
            {Map.put(answer, "position", Ledger.position(state.ledger)), state}
          end)

        {%{"answers" => answers}, Map.delete(state, :page_lists)}
      after
        Process.delete(key)
      end
    else
      {answered("invalid ordinary page collection reads"), state}
    end
  end

  defp read(state, @page, _content),
    do: {answered("page reads require a bounded list of ordinary kinds"), state}

  defp read(state, kind, content) do
    with {:ok, spec, state} <- kind_spec(state, kind) do
      case content do
        %{"key" => key, "plain" => true} ->
          {read_plain(state, kind, spec, key), state}

        %{"key" => key} ->
          {read_one(state, kind, spec, key, content["incoming"] != false), state}

        %{"linked" => linked} when is_map(linked) ->
          {read_all(state, kind, spec, linked, content["plain"] != true), state}

        _ ->
          {read_all(state, kind, spec, %{}, true), state}
      end
    else
      {:error, :unavailable, state} -> {read_error(:unavailable), state}
      {:error, reason, state} -> {%{"error" => reason, "error_kind" => "answered"}, state}
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
             {:ok, facts} <- Rela.list(state.rela, plural) do
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
    case Rela.get(state.rela, spec["plural"], key) do
      {:ok, fact} -> %{"fact" => wire(state, kind, fact)}
      {:error, :not_found} -> %{"fact" => nil}
      {:error, reason} -> read_error(reason)
    end
  end

  # `full?` false (`"incoming": false`): the fact with its progress and completion, without
  # what points at it, the kinds of its links, its history or its copy: what Flow needs.
  defp read_one(state, kind, spec, key, false) do
    with {:ok, fact} <- Rela.get(state.rela, spec["plural"], key),
         {:ok, [fact]} <- with_progress(state, kind, [fact]) do
      %{"fact" => wire(state, kind, fact)}
    else
      {:error, :not_found} -> %{"fact" => nil}
      {:error, reason} -> read_error(reason)
    end
  end

  defp read_one(state, kind, spec, key, true) do
    with {:ok, fact} <- Rela.get(state.rela, spec["plural"], key),
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
      case Rela.incoming(state.rela, spec["plural"], key, relation) do
        {:ok, keys} -> {:cont, {:ok, Map.put(acc, relation, keys)}}
        error -> {:halt, error}
      end
    end)
  end

  # How far each fact is, from the facts under it, as the description's rule says.
  defp with_progress(state, kind, facts) do
    Progress.annotate(state.description, kind, facts, fn of ->
      collection(state, get_in(state.description, ["entities", of, "plural"]))
    end)
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

    # Late is worked out on every read, plain ones too: it costs no read.
    case Late.of(state.description, kind, fact[:properties]) do
      nil -> wired
      late -> Map.put(wired, "late", late)
    end
  end

  # Facts

  defp store(state, kind, %{"op" => op, "key" => key} = content) when is_binary(key) do
    case kind_spec(state, kind) do
      {:ok, spec, state} ->
        values = content["values"] || %{}

        result =
          case Description.targets(state.description, kind, content["links"] || %{}) do
            {:ok, targets} ->
              with {:ok, targets} <- target_kinds(state, op, targets),
                   :ok <- targets_exist(state, op, targets),
                   :ok <- not_a_part(state, kind, op, key),
                   rules = Guards.of(state.description, kind),
                   :ok <- guarded(state, spec, rules, op, key, values, targets, content["by"]) do
                parts = Components.of(state.description, kind, key)
                was = content["was"]

                state
                |> write(spec, op, key, values, content["version"], targets, was, parts)
                |> replace(state, spec, rules, op, key)
              end

            {:error, problems} ->
              {:refused, problems}
          end

        {result, state}

      {:error, :unavailable, state} ->
        {:unavailable, state}

      {:error, reason, state} ->
        {{:refused, [reason]}, state}
    end
  end

  defp store(state, _kind, _content), do: {{:refused, ["a fact needs an op and a key"]}, state}

  # The kind's write rules (`AtlasFacts.Guards`), on the fact as it is stored now.
  defp guarded(_state, _spec, rules, _op, _key, _values, _targets, _writer) when rules == %{},
    do: :ok

  # `writer`: who sent the write, as Control says (`by`).
  defp guarded(state, spec, rules, op, key, values, targets, writer) do
    with {:ok, current} <- current(state, spec, op, key) do
      values = Map.new(values, fn {k, v} -> {k, if(v == "", do: nil, else: v)} end)
      links = Map.new(targets, fn {relation, {_kind, keys}} -> {relation, keys} end)

      Guards.check(rules, op, key, current, values, links, %{
        "writer" => writer,
        "kind_of" => &linked_kind(state, &1, &2),
        "fetch" => fn old ->
          case Rela.get(state.rela, spec["plural"], old) do
            {:ok, fact} -> fact.properties
            _ -> nil
          end
        end,
        "incoming" => fn relation ->
          case Rela.incoming(state.rela, spec["plural"], key, relation) do
            {:ok, keys} -> keys
            _ -> []
          end
        end
      })
    end
  end

  defp current(_state, _spec, "create", _key), do: {:ok, nil}

  defp current(state, spec, _op, key) do
    case Rela.get(state.rela, spec["plural"], key) do
      {:ok, fact} -> {:ok, %{"values" => fact.properties, "links" => fact[:links] || %{}}}
      {:error, :not_found} -> {:ok, nil}
      error -> failure(error)
    end
  end

  defp linked_kind(state, relation, key) do
    kinds = get_in(state.description, ["relations", relation, "to"]) || []
    Enum.find(kinds, &kind_has?(state, &1, key))
  end

  # A stored fact that replaces others marks them in the same write (`replaces.set`). When
  # one cannot be marked, the write is not recorded, so sending it again finishes it.
  defp replace(:stored, state, spec, %{"replaces" => %{"set" => set}} = rules, op, key)
       when op in ["create", "change"] do
    fetch = fn old ->
      case Rela.get(state.rela, spec["plural"], old) do
        {:ok, fact} -> fact
        _ -> nil
      end
    end

    case fetch.(key) do
      %{} = fact ->
        stored = %{"values" => fact.properties, "links" => fact[:links] || %{}}

        rules
        |> Guards.replaced(stored, &(fetch.(&1) && fetch.(&1).properties))
        |> Enum.reduce_while(:stored, fn old, :stored ->
          case Rela.change(state.rela, spec["plural"], old, set, nil, %{}) do
            {:ok, []} ->
              {:cont, :stored}

            other ->
              {:halt,
               {:unavailable,
                "#{key} is stored, but #{old} is not marked yet (#{inspect(other)}); send it again"}}
          end
        end)

      nil ->
        {:unavailable, "#{key} is stored, but could not be read again; send it again"}
    end
  end

  defp replace(result, _state, _spec, _rules, _op, _key), do: result

  defp write(state, spec, op, key, values, version, targets, was, []) do
    if op == "delete",
      do: delete(state, spec, key, version),
      else: store(state.rela, spec, op, key, values, version, targets, was)
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
            {:error, :exists} -> resent_create(state.rela, plural, key, values, targets)
            error -> failure(error)
          end
      end
    else
      {:ok, warnings} -> {:refused, warnings}
      {:error, :exists} -> resent_create(state.rela, plural, key, values, targets)
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
    do: store(state.rela, spec, op, key, values, version, targets, was)

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
            {:error, :exists} -> resent_create(state.rela, spec["plural"], part, values, %{})
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

  # A component goes with its fact, never alone while that fact exists.
  defp not_a_part(state, kind, "delete", key) do
    owners =
      for {relation, _from} <- Components.owners(state.description, kind),
          {:ok, keys} <- [Rela.incoming(state.rela, plural(state, kind), key, relation)],
          owner <- keys,
          do: owner

    case owners do
      [] -> :ok
      _ -> {:refused, ["#{key} goes with #{Enum.join(owners, ", ")}; delete that instead"]}
    end
  end

  defp not_a_part(_state, _kind, _op, _key), do: :ok

  defp store(rela, spec, "create", key, values, _version, targets, _was) do
    values = Map.reject(values, fn {_, v} -> v in [nil, ""] end)
    plural = spec["plural"]

    with :ok <- both(Description.check_key(spec, key), Description.check(spec, values, :create)),
         {:ok, []} <- Rela.check_create(rela, plural, key, values, targets),
         {:ok, _warnings} <- Rela.create(rela, plural, key, values, targets) do
      :stored
    else
      {:ok, warnings} -> {:refused, warnings}
      {:error, :exists} -> resent_create(rela, plural, key, values, targets)
      error -> failure(error)
    end
  end

  # The links of a change replace the relation's keys: a move to another parent.
  defp store(rela, spec, "change", key, values, version, targets, was) do
    values = Map.new(values, fn {k, v} -> {k, if(v == "", do: nil, else: v)} end)
    plural = spec["plural"]

    with :ok <- Description.check(spec, values, :change),
         {:ok, []} <- Rela.change(rela, plural, key, values, version, targets) do
      :stored
    else
      # The current rela has already stored the change; say so instead of hiding it.
      {:ok, warnings} -> {:refused, ["rela stored it with warnings: " | warnings]}
      {:error, :version_mismatch} -> changed_meanwhile(rela, plural, key, values, targets, was)
      {:error, :not_found} -> {:refused, ["#{key} does not exist (any more)"]}
      error -> failure(error)
    end
  end

  defp store(_rela, _spec, op, _key, _values, _version, _targets, _was),
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
  defp resent_create(rela, plural, key, values, targets) do
    case Rela.get(rela, plural, key) do
      {:ok, fact} ->
        if same?(fact, values) and same_links?(fact, targets),
          do: :stored,
          else: {:refused, ["#{key} already exists"], "exists"}

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
      {relation, Map.new(keys, fn key -> {key, Enum.find(kinds, &kind_has?(state, &1, key))} end)}
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

  # A kind rela describes has a plural (its collection). One that only Atlas's additions
  # (rela/atlas.json) name is one rela does not know: it runs an older description than
  # this build. The description is read again first, in case rela was restarted since.
  defp kind_spec(state, kind) do
    case state.description && Description.kind(state.description, kind) do
      %{"plural" => _} = spec ->
        {:ok, spec, state}

      _ ->
        case describe(state) do
          {:ok, description} ->
            state = %{state | description: description}

            case Description.kind(description, kind) do
              nil -> {:error, "rela does not describe #{inspect(kind)}", state}
              %{"plural" => _} = spec -> {:ok, spec, state}
              _ -> {:error, older(kind), state}
            end

          {:error, _} ->
            {:error, :unavailable, state}
        end
    end
  end

  defp older(kind) do
    "rela does not know #{kind}: its description is older than this build; " <>
      "run atlas-ops restart --env #{AtlasBus.environment()}"
  end

  defp content_op(%{"op" => op}) when is_binary(op), do: op
  defp content_op(_), do: nil
  defp content_key(%{"key" => key}) when is_binary(key), do: key
  defp content_key(_), do: nil
end

defmodule AtlasControl.FakeStore do
  @moduledoc """
  A stand-in for Facts on the Bus, for Control's tests: answers reads (one at a time, or
  a page of them, `_page`, each with what it depended on, `deps`), stores facts in
  memory, answers every fact with stored or refused (a stored says what changed,
  `changes`). What it knows of kinds (which fields are required, which relations point
  at a kind) is the neutral model's (`AtlasControl.Shop`, or the `model:` it is started
  with).
  """
  use GenServer

  alias AtlasBus.Envelope

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts[:model] || AtlasControl.Shop, name: __MODULE__)

  def put(key, values, kind \\ "widget", links \\ %{}),
    do: GenServer.call(__MODULE__, {:put, kind, key, values, links})

  @doc "What Facts presents of the work on `key` (as it derives it from the runs)."
  def present(kind, key, presentation),
    do: GenServer.call(__MODULE__, {:present, kind, key, presentation})

  @doc "The fact that set a link, as Facts answers it in `origins`."
  def origin(kind, key, relation, origin),
    do: GenServer.call(__MODULE__, {:origin, kind, key, relation, origin})

  @doc "Every fact content Facts was sent, oldest first."
  def sent, do: GenServer.call(__MODULE__, :sent)

  def link(part, widget), do: put(part, %{"title" => part}, "part", %{"of_widget" => [widget]})
  def silent(on?), do: GenServer.call(__MODULE__, {:silent, on?})

  @doc """
  A hint of a write someone else made, as Facts sends it to every listener of `kind`:
  `changes` as a `stored` says them, at the next position. Nothing is stored.
  """
  def hint(kind, key, changes, by \\ "someone"),
    do: GenServer.call(__MODULE__, {:hint, kind, key, changes, by})

  @doc "How many reads it was sent (a page read is one), and of which kinds: `[kind]`."
  def reads, do: GenServer.call(__MODULE__, :reads)

  @doc """
  Leave reads unanswered: `true` for every kind, a list for those kinds (a page that reads
  one of them too), `false` for none.
  """
  def silent_reads(kinds), do: GenServer.call(__MODULE__, {:silent_reads, kinds})

  @doc "Tell `pid` `{:unanswered, id}` of each read it leaves unanswered, as it leaves it."
  def tell_unanswered(pid), do: GenServer.call(__MODULE__, {:tell_unanswered, pid})

  @doc "The content of the last fact it was sent."
  def last_fact, do: GenServer.call(__MODULE__, :last_fact)

  @doc """
  Say on every read answer from now on that a value in it changes by time alone at `at`
  (an ISO 8601 instant, as Facts says it in `until`); nil: none.
  """
  def until(at), do: GenServer.call(__MODULE__, {:until, at})

  @doc "Make a key taken without listing it, as rela does for a key deleted a moment ago."
  def reserve(key), do: GenServer.call(__MODULE__, {:reserve, key})

  @doc "Refuse every fact about `key` with `reason`, as a rule in rela would."
  def refuse(key, reason), do: GenServer.call(__MODULE__, {:refuse, key, reason})

  @impl true
  def init(model) do
    :ok = AtlasBus.attach(AtlasBus.store())

    {:ok,
     %{
       model: AtlasControl.Model.catalog(model),
       facts: %{},
       position: 0,
       silent: false,
       silent_reads: %{},
       tell_unanswered: nil,
       reserved: MapSet.new(),
       last: nil,
       refusing: %{},
       origins: %{},
       presentations: %{},
       sent: [],
       reads: [],
       until: nil
     }}
  end

  @impl true
  def handle_call({:put, kind, key, values, links}, _from, s),
    do: {:reply, :ok, put_in(s.facts[{kind, key}], {values, 0, links})}

  def handle_call({:present, kind, key, presentation}, _from, s),
    do: {:reply, :ok, put_in(s.presentations[{kind, key}], presentation)}

  def handle_call({:silent, on?}, _from, s), do: {:reply, :ok, %{s | silent: on?}}

  def handle_call({:silent_reads, kinds}, _from, s) do
    silent =
      case kinds do
        true -> :all
        false -> %{}
        kinds -> Map.new(kinds, &{&1, true})
      end

    {:reply, :ok, %{s | silent_reads: silent}}
  end

  def handle_call({:tell_unanswered, pid}, _from, s),
    do: {:reply, :ok, %{s | tell_unanswered: pid}}

  def handle_call(:last_fact, _from, s), do: {:reply, s.last, s}

  def handle_call({:origin, kind, key, relation, origin}, _from, s),
    do: {:reply, :ok, put_in(s.origins[{kind, key, relation}], origin)}

  def handle_call(:sent, _from, s), do: {:reply, Enum.reverse(s.sent), s}
  def handle_call(:reads, _from, s), do: {:reply, Enum.reverse(s.reads), s}

  def handle_call({:hint, kind, key, changes, by}, _from, s) do
    s = %{s | position: s.position + 1}
    envelope = %{AtlasBus.Envelope.new("stored", kind) | position: s.position}
    content = %{"op" => "change", "key" => key, "by" => by, "changes" => changes}
    {:reply, AtlasBus.send(envelope, content), s}
  end

  def handle_call({:refuse, key, reason}, _from, s),
    do: {:reply, :ok, put_in(s.refusing[key], reason)}

  def handle_call({:until, at}, _from, s), do: {:reply, :ok, %{s | until: at}}

  def handle_call({:reserve, key}, _from, s),
    do: {:reply, :ok, %{s | reserved: MapSet.put(s.reserved, key)}}

  @impl true
  def handle_info({:atlas_bus, %Envelope{class: "read"} = e, content}, s) do
    s = %{s | reads: [e.kind | s.reads]}

    if silent?(s, e.kind, content) do
      if s.tell_unanswered, do: send(s.tell_unanswered, {:unanswered, e.id})
      {:noreply, s}
    else
      answer =
        case {e.kind, content} do
          # How far Facts is: its position alone, which every answer carries.
          {"_position", _} ->
            %{}

          {"_page", %{"reads" => reads}} ->
            %{
              "answers" =>
                for(
                  [kind, read] <- reads,
                  do: Map.put(timed(s, answer(s, kind, read)), "position", s.position)
                )
            }

          {kind, content} ->
            timed(s, answer(s, kind, content))
        end

      :ok = AtlasBus.send(Envelope.reply(e, "answer"), Map.put(answer, "position", s.position))
      {:noreply, s}
    end
  end

  def handle_info({:atlas_bus, %Envelope{class: "fact"}, _content}, %{silent: true} = s),
    do: {:noreply, s}

  def handle_info({:atlas_bus, %Envelope{class: "fact"} = e, %{"op" => op, "key" => key} = c}, s) do
    s = %{s | last: c}
    about = %{"op" => op, "key" => key}
    about = if is_binary(c["by"]), do: Map.put(about, "by", c["by"]), else: about
    s = %{s | sent: [c | s.sent]}
    id = {e.kind, key}

    cond do
      Map.has_key?(s.refusing, key) ->
        reasons = [s.refusing[key]]
        :ok = AtlasBus.send(Envelope.reply(e, "refused"), Map.put(about, "reasons", reasons))
        {:noreply, s}

      op == "create" and missing(s, e.kind, c["values"]) != [] ->
        reasons = for name <- missing(s, e.kind, c["values"]), do: "#{name} is required"
        :ok = AtlasBus.send(Envelope.reply(e, "refused"), Map.put(about, "reasons", reasons))

        {:noreply, s}

      op == "create" and (Map.has_key?(s.facts, id) or key in s.reserved) ->
        code = if key in s.reserved, do: "reserved", else: "exists"
        refusal = Map.merge(about, %{"reasons" => ["#{key} is taken"], "code" => code})
        :ok = AtlasBus.send(Envelope.reply(e, "refused"), refusal)
        {:noreply, s}

      true ->
        facts =
          case op do
            "delete" ->
              Map.delete(s.facts, id)

            "create" ->
              Map.put(s.facts, id, {c["values"], 0, c["links"] || %{}})

            "change" ->
              Map.update!(s.facts, id, fn {old, n, l} ->
                l =
                  Enum.reduce(c["links"] || %{}, l, fn
                    {relation, []}, acc -> Map.delete(acc, relation)
                    {relation, keys}, acc -> Map.put(acc, relation, keys)
                  end)

                {Map.merge(old, c["values"]), n + 1, l}
              end)
          end

        changes = changed(e.kind, key, s.facts[id], facts[id])
        s = %{s | facts: facts, position: s.position + 1}
        about = Map.put(about, "changes", changes)
        :ok = AtlasBus.send(Envelope.reply(e, "stored", position: s.position), about)
        {:noreply, s}
    end
  end

  defp timed(%{until: nil}, answer), do: answer
  defp timed(%{until: at}, answer), do: Map.put(answer, "until", at)

  defp silent?(%{silent_reads: :all}, _kind, _content), do: true

  defp silent?(s, "_page", %{"reads" => reads}),
    do: Enum.any?(reads, fn [kind, _] -> is_map_key(s.silent_reads, kind) end)

  defp silent?(s, kind, _content), do: is_map_key(s.silent_reads, kind)

  # What a write changed, as Facts says it in `changes`: what differs between before and
  # after (each `{values, version, links}` or nil).
  defp changed(_kind, _key, nil, nil), do: []

  defp changed(kind, key, before, later) do
    {old, _, old_links} = before || {%{}, 0, %{}}
    {new, _, new_links} = later || {%{}, 0, %{}}
    names = Enum.uniq(Map.keys(old) ++ Map.keys(new))
    relations = Enum.uniq(Map.keys(old_links) ++ Map.keys(new_links))

    {op, fields, relinked} =
      case {before, later} do
        {nil, _} ->
          {"create", Map.keys(new), Map.keys(new_links)}

        {_, nil} ->
          {"delete", Map.keys(old), Map.keys(old_links)}

        _ ->
          {"change", Enum.filter(names, &(old[&1] != new[&1])),
           Enum.filter(relations, &(old_links[&1] != new_links[&1]))}
      end

    links =
      for relation <- relations,
          keys = Enum.uniq(List.wrap(old_links[relation]) ++ List.wrap(new_links[relation])),
          keys != [],
          into: %{},
          do: {relation, Enum.sort(keys)}

    if op == "change" and fields == [] and relinked == [] do
      []
    else
      [
        %{
          "kind" => kind,
          "key" => key,
          "op" => op,
          "fields" => Enum.sort(fields),
          "relinked" => Enum.sort(relinked),
          "links" => links
        }
      ]
    end
  end

  # One read's answer, with what it depended on, as Facts says it. A fact's presentation
  # is the one the test stored with it (as Facts derives it from the runs), or none.
  defp answer(s, kind, %{"presentation" => true} = content) do
    present = fn fact ->
      case s.presentations[{kind, fact["key"]}] do
        nil -> fact
        presentation -> Map.put(fact, "presentation", presentation)
      end
    end

    case plain_answer(s, kind, content) do
      %{"fact" => %{} = fact} = answer -> %{answer | "fact" => present.(fact)}
      %{"facts" => facts} = answer -> %{answer | "facts" => Enum.map(facts, present)}
      answer -> answer
    end
  end

  defp answer(s, kind, content), do: plain_answer(s, kind, content)

  defp plain_answer(s, kind, content) do
    case {kind, content} do
      {kind, %{"key" => key}} ->
        case s.facts[{kind, key}] do
          nil ->
            %{"fact" => nil, "deps" => [["key", kind, key, "*"]]}

          {values, n, links} ->
            incoming =
              for {relation, %{to: to}} <- s.model.relations,
                  kind in to,
                  into: %{} do
                {relation, for({{_, k}, {_, _, l}} <- s.facts, key in (l[relation] || []), do: k)}
              end

            %{
              "fact" => %{
                "key" => key,
                "values" => values,
                "links" => links,
                "origins" => origins(s, kind, key),
                "version" => "v#{n}"
              },
              "incoming" => incoming,
              "deps" =>
                Enum.sort([
                  ["key", kind, key, "*"]
                  | for({relation, _} <- incoming, do: ["linked", relation, key, "*"])
                ])
            }
        end

      {kind, content} ->
        linked = content["linked"] || %{}

        facts =
          for {{^kind, k}, {v, _, l}} <- Enum.sort(s.facts),
              Enum.all?(linked, fn {rel, parent} -> parent in (l[rel] || []) end),
              do: %{"key" => k, "values" => v, "links" => l, "version" => nil}

        members =
          if linked == %{},
            do: [["kind", kind]],
            else: for({rel, parent} <- linked, do: ["linked", rel, parent, "*"])

        deps = Enum.sort(members ++ for(f <- facts, do: ["key", kind, f["key"], "*"]))
        %{"facts" => facts, "deps" => deps}
    end
  end

  defp origins(s, kind, key) do
    for {{^kind, ^key, relation}, origin} <- s.origins, into: %{}, do: {relation, origin}
  end

  defp missing(s, kind, values) do
    for %{name: name, required: true} <- s.model.kinds[kind].fields,
        values[name] in [nil, ""],
        do: name
  end
end

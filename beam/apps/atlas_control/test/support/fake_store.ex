defmodule AtlasControl.FakeStore do
  @moduledoc """
  A stand-in for Facts on the Bus, for Control's tests: answers reads, stores facts in
  memory, answers every fact with stored or refused. What it knows of kinds (which fields
  are required, which relations point at a kind) is the neutral model's
  (`AtlasControl.Shop`, or the `model:` it is started with).
  """
  use GenServer

  alias AtlasBus.Envelope

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts[:model] || AtlasControl.Shop, name: __MODULE__)

  def put(key, values, kind \\ "widget", links \\ %{}),
    do: GenServer.call(__MODULE__, {:put, kind, key, values, links})

  @doc "The fact that set a link, as Facts answers it in `origins`."
  def origin(kind, key, relation, origin),
    do: GenServer.call(__MODULE__, {:origin, kind, key, relation, origin})

  @doc "Every fact content Facts was sent, oldest first."
  def sent, do: GenServer.call(__MODULE__, :sent)

  def link(part, widget), do: put(part, %{"title" => part}, "part", %{"of_widget" => [widget]})
  def silent(on?), do: GenServer.call(__MODULE__, {:silent, on?})

  @doc "Leave reads unanswered: `true` for every kind, a list for those kinds, `false` for none."
  def silent_reads(kinds), do: GenServer.call(__MODULE__, {:silent_reads, kinds})

  @doc "Tell `pid` `{:unanswered, id}` of each read it leaves unanswered, as it leaves it."
  def tell_unanswered(pid), do: GenServer.call(__MODULE__, {:tell_unanswered, pid})

  @doc "The content of the last fact it was sent."
  def last_fact, do: GenServer.call(__MODULE__, :last_fact)

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
       sent: []
     }}
  end

  @impl true
  def handle_call({:put, kind, key, values, links}, _from, s),
    do: {:reply, :ok, put_in(s.facts[{kind, key}], {values, 0, links})}

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

  def handle_call({:refuse, key, reason}, _from, s),
    do: {:reply, :ok, put_in(s.refusing[key], reason)}

  def handle_call({:reserve, key}, _from, s),
    do: {:reply, :ok, %{s | reserved: MapSet.put(s.reserved, key)}}

  @impl true
  def handle_info({:atlas_bus, %Envelope{class: "read", kind: kind} = e, _content}, s)
      when s.silent_reads == :all or is_map_key(s.silent_reads, kind) do
    if s.tell_unanswered, do: send(s.tell_unanswered, {:unanswered, e.id})
    {:noreply, s}
  end

  def handle_info({:atlas_bus, %Envelope{class: "read"} = e, content}, s) do
    answer =
      case {e.kind, content} do
        {kind, %{"key" => key}} ->
          case s.facts[{kind, key}] do
            nil ->
              %{"fact" => nil}

            {values, n, links} ->
              incoming =
                for {relation, %{to: to}} <- s.model.relations,
                    kind in to,
                    into: %{} do
                  {relation,
                   for({{_, k}, {_, _, l}} <- s.facts, key in (l[relation] || []), do: k)}
                end

              %{
                "fact" => %{
                  "key" => key,
                  "values" => values,
                  "links" => links,
                  "origins" => origins(s, kind, key),
                  "version" => "v#{n}"
                },
                "incoming" => incoming
              }
          end

        {kind, content} ->
          linked = content["linked"] || %{}

          facts =
            for {{^kind, k}, {v, _, l}} <- Enum.sort(s.facts),
                Enum.all?(linked, fn {rel, parent} -> parent in (l[rel] || []) end),
                do: %{"key" => k, "values" => v, "links" => l, "version" => nil}

          %{"facts" => facts}
      end

    :ok = AtlasBus.send(Envelope.reply(e, "answer"), Map.put(answer, "position", s.position))
    {:noreply, s}
  end

  def handle_info({:atlas_bus, %Envelope{class: "fact"}, _content}, %{silent: true} = s),
    do: {:noreply, s}

  def handle_info({:atlas_bus, %Envelope{class: "fact"} = e, %{"op" => op, "key" => key} = c}, s) do
    s = %{s | last: c}
    about = %{"op" => op, "key" => key}
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

        s = %{s | facts: facts, position: s.position + 1}
        :ok = AtlasBus.send(Envelope.reply(e, "stored", position: s.position), about)
        {:noreply, s}
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

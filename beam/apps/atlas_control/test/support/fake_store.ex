defmodule AtlasControl.FakeStore do
  @moduledoc """
  A stand-in for Facts on the Bus, for Control's tests: answers reads, stores facts in
  memory, answers every fact with stored or refused. Its kinds are made up on purpose.
  """
  use GenServer

  alias AtlasBus.Envelope

  def description do
    %{
      # As `rela/atlas.json` adds it: values of this type are web addresses.
      "types" => %{"web_address" => %{"format" => "url"}},
      "entities" => %{
        "widget" => %{
          "label" => "Widget",
          "plural" => "widgets",
          "primary" => "title",
          "id_type" => "manual",
          "id_prefixes" => ["W-"],
          "properties" => %{
            "title" => %{"type" => "string", "required" => true},
            "shade" => %{
              "type" => "shade",
              "values" => ["light", "dark"],
              "labels" => %{"light" => "Light", "dark" => "Dark"}
            },
            "done" => %{"type" => "boolean", "default" => "false"},
            "notes" => %{"type" => "string", "description" => "Free text", "multiline" => true},
            # Only a connector fills it, as `rela/atlas.json` marks it.
            "ext_ref" => %{"type" => "string", "set_by" => "connector"}
          },
          # As `rela/atlas.json` adds it.
          "create" => %{
            "ask" => ["title", "notes"],
            "id" => %{"prefix" => "W-", "digits" => 2},
            "defaults" => %{"shade" => "light", "done" => false}
          }
        },
        "part" => %{
          "label" => "Part",
          "plural" => "parts",
          "id_prefixes" => ["P-"],
          "primary" => "title",
          "properties" => %{"title" => %{"type" => "string", "required" => true}}
        },
        # A kind whose id is made from a property, as `rela/atlas.json` adds it; no primary.
        "tag" => %{
          "label" => "Tag",
          "plural" => "tags",
          "id_prefixes" => ["T-"],
          "properties" => %{
            "name" => %{"type" => "string", "required" => true},
            "note" => %{"type" => "string", "set_by" => "connector"},
            # Of a type `rela/atlas.json` marks as web addresses.
            "site" => %{"type" => "web_address", "set_by" => "connector"}
          },
          "create" => %{
            "ask" => ["name"],
            "id" => %{
              "from" => "name",
              "pattern" => "^#([a-z.]+)/([0-9]+)$",
              "template" => "T-{1}-{2}",
              "replace" => %{"." => "_"},
              "error" => "name must look like #word/1"
            }
          }
        },
        # Reached only through the facts that point at it, as `rela/atlas.json` says.
        "member" => %{
          "label" => "Member",
          "plural" => "members",
          "top" => false,
          "properties" => %{"name" => %{"type" => "string", "required" => true}}
        }
      },
      "relations" => %{
        "of_widget" => %{
          "label" => "of widget",
          "from" => ["part"],
          "to" => ["widget"],
          "max_outgoing" => 1,
          "parent" => true,
          "inverse" => %{"id" => "parts", "label" => "parts"}
        },
        "on_part" => %{
          "label" => "on part",
          "from" => ["tag"],
          "to" => ["part"],
          "max_outgoing" => 1,
          "parent" => true,
          "inverse" => %{"id" => "tags", "label" => "tags"},
          # As `rela/atlas.json` adds it: one live tag per part; a dropped one does not count.
          "limit" => %{
            "max" => 1,
            "field" => "note",
            "values" => ["live", "kept"],
            "error" => "{parent} already has {child} ({value}); one tag per part"
          }
        },
        # Associations: at most one, but not a parent.
        "checked_by" => %{
          "label" => "checked by",
          "from" => ["widget", "part"],
          "to" => ["member"],
          "max_outgoing" => 1,
          "inverse" => %{"id" => "checked", "label" => "checked"}
        },
        # Only a member approves, and only as itself; as `rela/atlas.json` adds it.
        "approved_by" => %{
          "label" => "approved by",
          "from" => ["widget"],
          "to" => ["member"],
          "max_outgoing" => 1,
          "only_target" => %{"error" => "only a member approves", "also" => ["migration"]},
          "actions" => %{
            "set" => %{"label" => "Approve", "key" => "a"},
            "remove" => %{"label" => "Withdraw", "key" => "a"}
          },
          "requires_completed_children" => "{key} has {children} open",
          "closes_parent" =>
            "{parent} is approved; withdraw it first, or put this under another {kind}"
        },
        # History only: a migration sets it.
        "seen_in" => %{
          "label" => "also seen in",
          "from" => ["widget"],
          "to" => ["tag"],
          "set_by" => "migration",
          "inverse" => %{"id" => "also_seen", "label" => "also seen"}
        }
      }
    }
  end

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def put(key, values, kind \\ "widget", links \\ %{}),
    do: GenServer.call(__MODULE__, {:put, kind, key, values, links})

  @doc "The fact that set a link, as Facts answers it in `origins`."
  def origin(kind, key, relation, origin),
    do: GenServer.call(__MODULE__, {:origin, kind, key, relation, origin})

  @doc "Every fact content Facts was sent, oldest first."
  def describe(description), do: GenServer.call(__MODULE__, {:describe, description})

  def sent, do: GenServer.call(__MODULE__, :sent)

  def link(part, widget), do: put(part, %{"title" => part}, "part", %{"of_widget" => [widget]})
  def silent(on?), do: GenServer.call(__MODULE__, {:silent, on?})

  @doc "Leave reads unanswered: `true` for every kind, a list for those kinds, `false` for none."
  def silent_reads(kinds), do: GenServer.call(__MODULE__, {:silent_reads, kinds})

  @doc "The content of the last fact it was sent."
  def last_fact, do: GenServer.call(__MODULE__, :last_fact)

  @doc "Make a key taken without listing it, as rela does for a key deleted a moment ago."
  def reserve(key), do: GenServer.call(__MODULE__, {:reserve, key})

  @doc "Refuse every fact about `key` with `reason`, as a rule in rela would."
  def refuse(key, reason), do: GenServer.call(__MODULE__, {:refuse, key, reason})

  @impl true
  def init(:ok) do
    :ok = AtlasBus.attach(AtlasBus.store())

    {:ok,
     %{
       description: description(),
       facts: %{},
       position: 0,
       silent: false,
       silent_reads: %{},
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

  def handle_call(:last_fact, _from, s), do: {:reply, s.last, s}

  def handle_call({:origin, kind, key, relation, origin}, _from, s),
    do: {:reply, :ok, put_in(s.origins[{kind, key, relation}], origin)}

  def handle_call({:describe, description}, _from, s),
    do: {:reply, :ok, %{s | description: description}}

  def handle_call(:sent, _from, s), do: {:reply, Enum.reverse(s.sent), s}

  def handle_call({:refuse, key, reason}, _from, s),
    do: {:reply, :ok, put_in(s.refusing[key], reason)}

  def handle_call({:reserve, key}, _from, s),
    do: {:reply, :ok, %{s | reserved: MapSet.put(s.reserved, key)}}

  @impl true
  def handle_info({:atlas_bus, %Envelope{class: "read", kind: kind}, _content}, s)
      when s.silent_reads == :all or is_map_key(s.silent_reads, kind),
      do: {:noreply, s}

  def handle_info({:atlas_bus, %Envelope{class: "read"} = e, content}, s) do
    answer =
      case {e.kind, content} do
        {"_description", _} ->
          %{"description" => s.description}

        {kind, %{"key" => key}} ->
          case s.facts[{kind, key}] do
            nil ->
              %{"fact" => nil}

            {values, n, links} ->
              incoming =
                for {relation, %{"to" => to}} <- description()["relations"],
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

      op == "create" and missing(e.kind, c["values"]) != [] ->
        reasons = for name <- missing(e.kind, c["values"]), do: "#{name} is required"
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

  defp missing(kind, values) do
    for {name, %{"required" => true}} <- description()["entities"][kind]["properties"],
        values[name] in [nil, ""],
        do: name
  end
end

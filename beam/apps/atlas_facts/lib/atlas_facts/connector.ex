defmodule AtlasFacts.Connector do
  @moduledoc """
  A connector at Facts' edge: it copies an outside system's facts into Atlas, read-only
  (architecture, sections 11 and 13). Generic: which kinds and fields it fills is the
  model's (`AtlasFacts.Model.connector/1`), for each kind rela describes:

      %{"system" => "github", "address" => "url",
        "fields" => %{"title" => "title", "state" => "state", "draft" => "isDraft"},
        "until" => %{"state" => ["merged", "closed"]}}

  For every fact of such a kind, its `source` (the module that knows the outside system,
  see the callbacks) reads the thing at the fact's `address` and answers its fields. The
  connector stores only the differences, as one change with its cause ("GitHub
  connector, read at …"), so reading the same values again stores nothing.

  When: at once for a fact just made (its hint), and a round every `every` ms for every
  fact that is not `until` yet. A hint only makes it read sooner; the round reads the
  facts themselves. A failed read is logged and tried again next round; the stored
  values stay. When each fact was last read is kept in `AtlasFacts.Copies`.

  A rule may also say what a copied field names (`names`):

      "names" => %{"field" => "title", "relation" => "done_in", "when" => %{"state" => ["merged"]},
                    "kind" => "task", "prefix" => "TA-"}

  Every round, for each fact whose values match `when`, the keys in `field` that fit the
  id `prefix` of the relation's `from` kind (other than the facts it points at already) are
  facts it was also done for: each such fact that exists gets a link to it through
  `relation`, one change with its cause. Links that are there already stay; a link is
  never removed by this.

  It reaches Facts as any layer does: reads and facts over the Bus, as its own endpoint
  `connector/<system>`. Nothing is ever written to the outside system.
  """
  use GenServer

  require Logger

  alias AtlasBus.Envelope
  alias AtlasFacts.Copies

  @description "_description"
  @answer_timeout 5_000
  # Until the first round found rela, try again this soon.
  @retry 5_000

  @doc "A short name of the outside system, for causes and pages (\"GitHub\")."
  @callback label(config :: term()) :: String.t()

  @doc """
  Read the things at `addresses`; one answer per address: its fields, named as the
  outside system names them, or why it could not be read. Never writes anything.
  """
  @callback read(config :: term(), addresses :: [String.t()]) ::
              %{String.t() => {:ok, map()} | {:error, String.t()}}

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

  @doc "Read every fact that is not `until` yet, now (for tests)."
  def round(server), do: GenServer.call(server, :round, 60_000)

  @impl true
  def init(opts) do
    system = Keyword.fetch!(opts, :system)
    :ok = AtlasBus.attach("connector/#{system}")
    :ok = Copies.open(Keyword.fetch!(opts, :data_dir))
    send(self(), :round)

    {:ok,
     %{
       model: Keyword.get_lazy(opts, :model, &AtlasFacts.Model.configured!/0),
       system: system,
       source: Keyword.fetch!(opts, :source),
       every: Keyword.get(opts, :every, 300_000),
       kinds: %{},
       timer: nil
     }}
  end

  @impl true
  def terminate(_reason, _state), do: Copies.close()

  @impl true
  def handle_call(:round, _from, state) do
    state = do_round(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:round, state), do: {:noreply, do_round(state)}

  # A fact of a kind this connector fills was just made: read it at once.
  def handle_info(
        {:atlas_bus, %Envelope{class: "stored", kind: kind}, %{"op" => "create", "key" => key}},
        state
      )
      when is_map_key(state.kinds, kind) do
    case call("read", kind, %{"key" => key}) do
      {:ok, %{"fact" => fact}} when is_map(fact) -> refresh(state, kind, [fact])
      _ -> :ok
    end

    {:noreply, state}
  end

  # Other hints, and answers that came after their wait.
  def handle_info({:atlas_bus, _envelope, _content}, state), do: {:noreply, state}

  defp do_round(state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    {state, next} =
      case call("read", @description, %{}) do
        {:ok, %{"description" => description}} ->
          state = %{state | kinds: kinds(state.model, description, state.system)}

          for {kind, rule} <- state.kinds do
            :ok = AtlasBus.listen(kind)

            case call("read", kind, %{}) do
              {:ok, %{"facts" => facts}} ->
                refresh(state, kind, Enum.reject(facts, &done?(&1, rule)))
                link_named(state, kind, rule)

              other ->
                Logger.warning("#{name(state)} could not list #{kind}: #{inspect(other)}")
            end
          end

          {state, state.every}

        other ->
          Logger.warning("#{name(state)} has no description yet: #{inspect(other)}")
          {state, min(@retry, state.every)}
      end

    %{state | timer: Process.send_after(self(), :round, next)}
  end

  @doc """
  The kinds of rela's schema (`description`) that `model` copies from `system`:
  `%{kind => connector rule}`.
  """
  def kinds(model, description, system) do
    for kind <- Map.keys(description["entities"] || %{}),
        %{"system" => ^system} = rule <- [model.connector(kind)],
        into: %{},
        do: {kind, rule}
  end

  # The facts each fact names in a field, linked to it (`names` in the rule), when its
  # values match `when`. Read again, so what this round just copied counts.
  defp link_named(state, kind, %{"names" => %{} = names}) do
    relation = names["relation"]
    target = names["kind"]
    prefix = names["prefix"]

    with true <- is_binary(target) and is_binary(prefix) and prefix != "",
         {:ok, %{"facts" => facts}} <- call("read", kind, %{}) do
      {:ok, pattern} = Regex.compile(Regex.escape(prefix) <> "\\d+")

      for fact <- facts,
          matches?(fact, names["when"] || %{}),
          own = fact["links"] |> Map.values() |> List.flatten(),
          key <-
            pattern
            |> Regex.scan(to_string(fact["values"][names["field"]]))
            |> List.flatten()
            |> Enum.uniq(),
          key not in own,
          do: link(state, target, key, relation, fact["key"])
    end

    :ok
  end

  defp link_named(_state, _kind, _rule), do: :ok

  defp matches?(fact, conditions),
    do: Enum.all?(conditions, fn {name, values} -> fact["values"][name] in List.wrap(values) end)

  defp link(state, kind, key, relation, to) do
    case call("read", kind, %{"key" => key}) do
      {:ok, %{"fact" => %{} = fact}} ->
        keys = fact["links"][relation] || []

        if to not in keys do
          {mod, config} = state.source

          content = %{
            "op" => "change",
            "key" => key,
            "values" => %{},
            "links" => %{relation => keys ++ [to]},
            "version" => nil,
            "by" => "connector/#{state.system}",
            "cause" => "#{mod.label(config)} connector: #{to} names #{key}"
          }

          case call("fact", kind, content) do
            {:stored, _} ->
              Logger.info("#{name(state)}: #{key} #{relation} #{to}")

            other ->
              Logger.warning(
                "#{name(state)}: #{key} #{relation} #{to} not stored: #{inspect(other)}"
              )
          end
        end

      _ ->
        :ok
    end
  end

  defp done?(fact, rule) do
    Enum.any?(rule["until"] || %{}, fn {name, values} -> fact["values"][name] in values end)
  end

  defp refresh(_state, _kind, []), do: :ok

  defp refresh(state, kind, facts) do
    rule = state.kinds[kind]
    {mod, config} = state.source
    label = mod.label(config)

    addressed =
      for fact <- facts,
          address = fact["values"][rule["address"]],
          is_binary(address),
          do: {fact, address}

    answers = mod.read(config, Enum.map(addressed, &elem(&1, 1)) |> Enum.uniq())
    at = now()

    for {fact, address} <- addressed do
      case Map.get(answers, address, {:error, "not read"}) do
        # Recorded first, so the page the change's hint brings already says it was read.
        {:ok, outside} ->
          Copies.read(kind, fact["key"], label, at)

          store(
            state,
            kind,
            fact,
            changes(fact, rule, outside),
            "#{label} connector, read at #{at}"
          )

        {:error, reason} ->
          Logger.warning(
            "#{name(state)}: reading #{address} for #{fact["key"]} failed: #{reason}; " <>
              "the stored values stay, and the next round tries again"
          )

          Copies.failed(kind, fact["key"], label, at, reason)
      end
    end

    :ok
  end

  # The fields whose outside value differs from the stored one. A field the outside
  # system did not answer is left as it is.
  defp changes(fact, rule, outside) do
    for {name, field} <- rule["fields"] || %{},
        Map.has_key?(outside, field),
        loose(outside[field]) != loose(fact["values"][name]),
        into: %{},
        do: {name, outside[field]}
  end

  defp store(_state, _kind, _fact, changes, _cause) when changes == %{}, do: :ok

  defp store(state, kind, fact, changes, cause) do
    content = %{
      "op" => "change",
      "key" => fact["key"],
      "values" => changes,
      "version" => fact["version"],
      "cause" => cause
    }

    case call("fact", kind, content) do
      {:stored, _} ->
        Logger.info("#{name(state)}: #{fact["key"]} #{inspect(changes)} (#{cause})")

      # Changed meanwhile, refused or no answer: the next round reads it again.
      other ->
        Logger.warning("#{name(state)}: #{fact["key"]} not stored: #{inspect(other)}")
    end
  end

  defp call(class, kind, content) do
    envelope = Envelope.new(class, kind)
    id = envelope.id

    with :ok <- AtlasBus.send(envelope, content) do
      receive do
        {:atlas_bus, %Envelope{id: ^id, class: "answer"}, answer} -> {:ok, answer}
        {:atlas_bus, %Envelope{id: ^id, class: "stored"}, about} -> {:stored, about}
        {:atlas_bus, %Envelope{id: ^id, class: "refused"}, refusal} -> {:refused, refusal}
      after
        @answer_timeout -> {:error, :no_answer}
      end
    end
  end

  defp loose(value) when value in [nil, ""], do: nil
  defp loose(value), do: to_string(value)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp name(state), do: "connector/#{state.system}"
end

defmodule AtlasFlow.Runs.Projection do
  @moduledoc """
  The one writer of what a run presents (`AtlasFlow.Runs.Presentation`) on its subject,
  or on the fact its selection's `projection` is `on` (a component, such as an
  Assignment): what is expected of its owner, the state, the deadline it shows and the
  owner. The engine projects a subject after its runs were reconciled; nothing else
  writes there. It keeps nothing: projected again at any moment, it reads Facts again
  and writes only what differs, with its cause, by `flow` (whose hints Flow passes over).

  The owner rules:

    * a state change moves the owner to the state's owner (`owner` of the subflow, or of
      the state); so does the first look at a fact nobody owns by hand;
    * an owner a user or an agent set by hand stays while the state stays
      (`Presentation.manual?/2`), unless the state keeps an assignee of its kind
      (`preserve_kind`, `AtlasFlow.Ownership`);
    * while a turn of the current owner runs on the fact, a handover waits: the projection
      records it in the `handover_field` (`Presentation.handover/2`) and moves the owner
      once the turn ended (its end is a hint about the fact); a later manual assignment
      cancels it;
    * an owner that does not exist yet is not written: what is expected is, and the
      result names the owner it waits for, so its creation projects the fact again;
    * when Facts does not say whether the owner exists, nothing is written;
    * a state owned by the configured `decider` goes to the run's human supervisor inside
      a supervised span (`AtlasFlow.Model.owner/3`): its own subflow's span, or, for a run
      of a subflow a span names in its `with:`, the span of the nearest spanned run above
      its subject (`AtlasFlow.Supervision.of/3`). When Facts does not say who supervises
      such a run, nothing is written: it never falls back to the decider.
  """

  require Logger

  alias AtlasFlow.Talk
  alias AtlasFlow.Runs.{Presentation, Store}

  @doc """
  Project `{kind, key}` with `runner` (`AtlasFlow.Model.load/3`): `{:ok, :none}`
  when no selected subflow presents it (or it is gone), else `{:ok, %{waits: owner | nil}}`.
  A missing owner is a successful projection that waits for its creation. Unavailable
  reads, missing required targets and unsuccessful writes return `{:error, reason}`;
  callers must not settle the originating input until recovery succeeds.
  """
  def project(runner, kind, key) do
    case Talk.read(kind, %{"key" => key, "incoming" => false}) do
      %{"fact" => fact} when is_map(fact) ->
        case Store.selected(runner.config, kind, fact) do
          nil -> {:ok, :none}
          selected -> project(runner, kind, fact, selected)
        end

      %{"fact" => nil} ->
        {:ok, :none}

      other ->
        {:error, {:subject_unavailable, other}}
    end
  end

  defp project(runner, kind, fact, {name, selection} = selected) do
    case presented(runner, kind, fact, selected) do
      {:ok, nil} ->
        {:ok, :none}

      {:ok, current} ->
        with {:ok, waits} <- move(runner, kind, {name, selection["projection"]}, fact, current) do
          {:ok, %{waits: waits}}
        end

      {:error, _} = error ->
        error
    end
  end

  # What the latest generation presents. Preserve the absence of a presentation for
  # missing, refused or other-definition runs; an unavailable read is a failure.
  defp presented(runner, kind, fact, {name, _selection}) do
    %{config: config, flows: flows, refusal: refusal} = runner
    subflow = flows[name]

    with nil <- refusal,
         true <- subflow != nil,
         {:ok, %{} = run} <- Store.latest(config, name, kind, fact["key"]),
         true <- run["definition_sha256"] == subflow.digest(),
         {:ok, run} <- supervised(runner, subflow, run) do
      {:ok, Presentation.of_run(run, subflow, fact, &owner(runner, &1, run)) |> entered(run)}
    else
      # Facts did not say who supervises the run: write nothing, never the decider.
      {:error, :supervision_unavailable} = error -> error
      {:error, why} -> {:error, {:presentation_unavailable, why}}
      _ -> {:ok, nil}
    end
  end

  # When the run entered its state (F2-P): a manual owner set before that entry is one of
  # an earlier entry.
  defp entered(%{"done" => true} = current, _run), do: current
  defp entered(%{} = current, run), do: Map.put(current, "entered_at", run["entered_at"])
  defp entered(nil, _run), do: nil

  # Who the state names, with a configured actor (`config`) as the environment's settings
  # fill it, or the run's human supervisor in its stead inside a supervised span
  # (`AtlasFlow.Model.owner/3`).
  defp owner(_runner, nil, _run), do: nil
  defp owner(runner, owner, run), do: AtlasFlow.Model.owner(owner, runner.actors, run)

  # The run with what `AtlasFlow.Model.owner/3` takes of its supervision, only when its
  # state's owner may go to a supervisor and the run is active: `{:ok, run}`, or
  # `{:error, :supervision_unavailable}` when Facts did not say.
  #
  # - A run whose subflow declares a span carries those `spans` and its human supervisor
  #   (`supervised_by`, `%{"kind", "key"}` or nil). The run's writer keeps the supervisor as
  #   a link of the run's fact, and the run it read carries that link's key as
  #   `supervised_by` (`AtlasFlow.Runs.Store`); its kind is the supervision relation's one
  #   holder kind. It reads nothing more.
  # - A run of a subflow some span names in its `with:` (and with no span of its own)
  #   belongs to the nearest spanned run above its subject (`AtlasFlow.Supervision.of/3`).
  #   It carries that run's supervisor and its in-span answer (`in_span`), but only when
  #   the span that run's state lies in names the run's subflow in its `with:`. This reads
  #   the subject's parents and that run's record. A run of a subflow no span names reads
  #   nothing more.
  defp supervised(runner, subflow, run) do
    supervision = runner.config["supervision"] || %{}
    spans = get_in(supervision, ["spans", run["flow"]]) || []

    cond do
      run["status"] != "active" or
          not AtlasFlow.Model.supervisable?((subflow.owner(run["state"]) || %{})["default"]) ->
        {:ok, run}

      spans != [] ->
        supervisor = holder(supervision, run["supervised_by"])
        {:ok, Map.merge(run, %{"spans" => spans, "supervised_by" => supervisor})}

      with?(supervision, run["flow"]) ->
        belonging(runner, supervision, run)

      true ->
        {:ok, run}
    end
  end

  # Whether a span of any subflow names `flow` in its `with:`.
  defp with?(supervision, flow) do
    Enum.any?(supervision["spans"] || %{}, fn {_name, spans} ->
      Enum.any?(spans, &(flow in (&1["with"] || [])))
    end)
  end

  # The supervision of a `with:` run: its nearest spanned run's, when that run's span
  # names the run's subflow.
  defp belonging(runner, supervision, run) do
    case AtlasFlow.Supervision.of(runner, run["subject_kind"], run["subject_key"]) do
      {:supervised, holder, key} ->
        case with_span(runner.config, supervision, key, run["flow"]) do
          {:ok, true} ->
            supervisor = holder(supervision, holder)

            {:ok,
             Map.merge(run, %{"in_span" => supervisor != nil, "supervised_by" => supervisor})}

          {:ok, false} ->
            {:ok, run}

          :unavailable ->
            {:error, :supervision_unavailable}
        end

      :unsupervised ->
        {:ok, run}

      :unavailable ->
        {:error, :supervision_unavailable}
    end
  end

  # Whether the span the run `key`'s state lies in names `flow` in its `with:`.
  defp with_span(config, supervision, key, flow) do
    with %{"fact" => %{} = fact} <- Talk.read(config["kind"], %{"key" => key, "plain" => true}),
         {:ok, spanned} <- Store.decode(config, fact) do
      spans = get_in(supervision, ["spans", spanned["flow"]]) || []

      {:ok,
       Enum.any?(spans, fn span ->
         spanned["state"] in (span["states"] || []) and flow in (span["with"] || [])
       end)}
    else
      %{"fact" => nil} -> {:ok, false}
      _ -> :unavailable
    end
  end

  # A supervisor's key as an owner: of the supervision relation's one holder kind.
  defp holder(supervision, key) do
    case {supervision["holders"], key} do
      {[kind], key} when is_binary(key) and key != "" -> %{"kind" => kind, "key" => key}
      _ -> nil
    end
  end

  # Store what differs on the fact the projection writes on: its own, or the one its
  # `on` relation points at. The owner it waits for, or nil.
  defp move(runner, kind, {name, projection}, fact, current) do
    case written(runner.relations, projection, kind, fact) do
      {:ok, kind, target} ->
        write(runner, fact["key"], name, projection, kind, target, current)

      {:missing, relation} ->
        Logger.warning("flow #{name}: #{fact["key"]} has no #{relation} to write on; tried again")
        {:error, {:missing_target, relation}}

      :unavailable ->
        {:error, :target_unavailable}
    end
  end

  defp written(relations, %{"on" => relation}, _kind, fact) when is_binary(relation) do
    with [to] <- get_in(relations, [relation, "to"]),
         [key] <- get_in(fact, ["links", relation]) || [],
         %{"fact" => target} when is_map(target) <-
           Talk.read(to, %{"key" => key, "plain" => true}) do
      {:ok, to, target}
    else
      %{"fact" => nil} -> {:missing, relation}
      %{"error" => _} -> :unavailable
      other when is_map(other) -> {:missing, relation}
      _ -> :unavailable
    end
  end

  defp written(_relations, _projection, kind, fact), do: {:ok, kind, fact}

  defp write(runner, subject, name, projection, kind, fact, current) do
    expected = if current["done"] == true, do: nil, else: current["expected"] || ""
    field = projection["field"]

    values =
      if field && blank(fact["values"][field]) != blank(expected),
        do: %{field => expected || ""},
        else: %{}

    current = preserve_owner(current, fact, projection["owner_relation"])
    owner = owner(current)
    relation = projection["owner_relation"]
    # A move is a change of state: what is expected changes from one thing to another. The
    # first look at a fact (nothing expected yet) is none, so an owner handed over before
    # it stays.
    moved? = values != %{} and blank(fact["values"][field]) != nil

    # A new entry into the state the fact shows is a move too (F2-P, B-3): the run left it
    # and came back between two projections (e.g. held → fresh → held in one reconcile, an
    # answer the ladder did not take), so a manual owner linked before that entry is the
    # earlier entry's and does not stay.
    moved? = moved? or reentered?(projection["state_field"], fact, current, relation)

    held_field = projection["handover_field"]
    owners = get_in(fact, ["links", relation]) || []
    origin = get_in(fact, ["origins", relation, "position"])
    pending = Presentation.handover(fact, held_field)
    deferred? = Presentation.deferred?(pending, owners, origin)
    cancelled? = pending != %{} and not deferred?

    wanted? =
      relation != nil and owners != List.wrap(owner) and
        (current["preserve_kind"] != nil or moved? or deferred? or
           (not cancelled? and not Presentation.manual?(fact, relation)))

    owner? =
      cond do
        current["owner_unavailable"] -> :unknown
        wanted? -> owner_exists(current)
        true -> :not_wanted
      end

    running =
      wanted? and current["done"] != true and held_field != nil and
        running?(runner.turn, fact["key"], owners)

    hold? = running != false

    links = if owner? == :yes and not hold?, do: %{relation => List.wrap(owner)}, else: %{}

    held_value =
      if hold? or (wanted? and deferred? and owner? != :yes),
        do: JSON.encode!(%{"from" => owners, "position" => origin}),
        else: ""

    values =
      if held_field && to_string(fact["values"][held_field]) != held_value,
        do: Map.put(values, held_field, held_value),
        else: values

    # The state's name, so a page can show its owner what to do (`state_field`). Written
    # with the rest, and alone when only it differs; it never counts as a move by itself.
    values = Map.merge(values, state_value(projection["state_field"], fact, current))

    # The due time of the timer the state presents (`present.deadline`), when the
    # projection names a `deadline_field`; cleared in every other state.
    values =
      if field = projection["deadline_field"] do
        if same_time?(fact["values"][field], current["deadline"]),
          do: values,
          else: Map.put(values, field, current["deadline"] || "")
      else
        values
      end

    outcome =
      cond do
        # Facts did not say whether the owner exists: write nothing now, rather than what
        # is expected without its owner; the next round tries again.
        owner? == :unknown ->
          Logger.warning("flow #{name}: #{subject} not moved: Facts did not answer; tried again")
          {:error, :owner_unavailable}

        running == :unknown ->
          {:error, :turn_unavailable}

        values != %{} or links != %{} ->
          # By flow: Flow passes over the hints of its own writes, on whichever fact.
          content = %{
            "op" => "change",
            "key" => fact["key"],
            "values" => values,
            "version" => nil,
            "by" => "flow",
            "cause" => cause(runner.flows[name], current, owner),
            "was" =>
              Map.merge(
                Map.new(Map.keys(values), &{&1, fact["values"][&1]}),
                Map.new(Map.keys(links), &{&1, fact["links"][&1] || []})
              )
          }

          content = if links == %{}, do: content, else: Map.put(content, "links", links)

          case Talk.put(kind, content) do
            {:stored, _} ->
              Logger.info("flow #{name}: #{subject} #{current["name"]} (#{inspect(values)})")
              :ok

            other ->
              Logger.warning("flow #{name}: #{subject} not moved: #{inspect(other)}; tried again")
              {:error, {:write_failed, other}}
          end

        true ->
          :ok
      end

    with :ok <- outcome do
      {:ok,
       case owner? do
         {:no, waits} -> waits
         _ -> nil
       end}
    end
  end

  defp preserve_owner(current, fact, relation) do
    AtlasFlow.Ownership.resolve(current, get_in(fact, ["links", relation]) || [], fn kind, key ->
      Talk.read(kind, %{"key" => key, "plain" => true})
    end)
  end

  # A turn of one of `owners` runs on the fact the work is written on (a turn works on
  # that one: the subject, or its component). Unknown Facts availability leaves the
  # projection waiting for recovery, preserving the existing owner.
  defp running?(_turn, _key, []), do: false

  defp running?(%{"kind" => kind} = n, key, owners) do
    case Talk.read(kind, %{"linked" => %{n["on"] => key}, "plain" => true}) do
      %{"facts" => turns} ->
        Enum.any?(turns, fn turn ->
          turn["values"][n["state"]] == n["running"] and
            Enum.any?(get_in(turn, ["links", n["by"]]) || [], &(&1 in owners))
        end)

      _ ->
        :unknown
    end
  end

  defp running?(_turn, _key, _owners), do: false

  # The owner a state names must exist; until it does, only what is expected is written.
  # :yes, `{:no, owner}` (Facts says there is no such fact) or :unknown (no answer).
  defp owner_exists(current) do
    case {owner(current), current["owner"]["kind"]} do
      {key, kind} when is_binary(key) and is_binary(kind) ->
        case Talk.read(kind, %{"key" => key, "plain" => true}) do
          %{"fact" => %{}} ->
            :yes

          %{"fact" => nil} ->
            Logger.warning("flow: #{kind} #{key} does not exist; the owner waits for it")
            {:no, {kind, key}}

          _ ->
            :unknown
        end

      _ ->
        :yes
    end
  end

  # The owner of the current state, a fact's key (who is next in line), or nil when done.
  defp owner(%{"done" => true}), do: nil
  defp owner(%{"owner" => %{"key" => key}}), do: key
  defp owner(_current), do: nil

  # Why it moved, naming the flow by its label (such as "Design"), else its name.
  defp cause(flow, current, owner) do
    why = current["why"] || current["name"]
    to = if owner, do: " → #{owner}", else: ""
    "Flow #{flow.label() || flow.name()}: #{why}#{to}"
  end

  # The fact shows the run's state already, and its owner was set by hand before the run
  # entered that state: in an earlier entry of it. Facts stores a link's `since` to the
  # second, so the entry is compared to the second as well: a link set in the second the
  # run entered counts as set after it, and stays.
  defp reentered?(nil, _fact, _current, _relation), do: false

  defp reentered?(field, fact, current, relation) do
    current["done"] != true and blank(fact["values"][field]) != nil and
      fact["values"][field] == current["name"] and Presentation.manual?(fact, relation) and
      before?(get_in(fact, ["origins", relation, "since"]), current["entered_at"])
  end

  defp before?(since, entered) do
    with {:ok, since, _} <- DateTime.from_iso8601(to_string(since)),
         {:ok, entered, _} <- DateTime.from_iso8601(to_string(entered)) do
      DateTime.compare(since, DateTime.truncate(entered, :second)) == :lt
    else
      _ -> false
    end
  end

  defp state_value(nil, _fact, _current), do: %{}

  defp state_value(field, fact, current) do
    name = if current && !current["done"], do: current["name"], else: nil
    if blank(fact["values"][field]) == blank(name), do: %{}, else: %{field => name || ""}
  end

  defp blank(value) when value in [nil, ""], do: nil
  defp blank(value), do: value

  # The same instant however it is written (Facts may store it with other precision).
  defp same_time?(a, b) do
    case {blank(a), blank(b)} do
      {nil, nil} ->
        true

      {a, b} when is_binary(a) and is_binary(b) ->
        with {:ok, x, _} <- DateTime.from_iso8601(a),
             {:ok, y, _} <- DateTime.from_iso8601(b),
             do: DateTime.compare(x, y) == :eq,
             else: (_ -> a == b)

      _ ->
        false
    end
  end
end

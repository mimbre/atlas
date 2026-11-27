defmodule AtlasFlow.Model do
  @moduledoc """
  The model Flow runs: a module the domain compiles (its subflows, where runs are kept
  and how they are selected), wired by configuration at boot:

      config :atlas, model: SomeModel

  Flow reads it once when it starts; a missing module, or one without these callbacks,
  refuses the start. Flow names no model, no kind and no subflow.
  """

  defmodule MissingActor do
    @moduledoc "The environment's settings fill no actor for `role`: Flow does not start."
    defexception [:role, :message]
  end

  @doc "The compiled subflow of each subflow the model runs (`AtlasFlow.Subflow`), in `environment`."
  @callback subflows(environment :: atom) :: [module]

  @doc "Where runs are kept: `%{\"kind\", \"fields\", \"writer\", \"inputs\"}`, or nil."
  @callback runs() :: nil | map

  @doc """
  How the runs of `subflow` are selected: `subject`, `admission`, `imports`,
  `projection`, `verification` and `reopen`; nil when it is not selected.
  `reopen: "new_generation"` lets reopened
  work start a new generation of a completed run; without it only an explicit restart
  does (`AtlasFlow.Runs.Run.restart/4`).
  """
  @callback selection(subflow :: String.t()) :: nil | map

  @doc """
  How the results of its subflows reach one another, as versioned data:
  `%{"version" => 1, "links" => [...], "counts" => [...], "tallies" => [...]}`. A link
  writes a child run's outcome to a field of its parent (`AtlasFlow.Composition.Links`),
  a count the parent's number of children and of open ones
  (`AtlasFlow.Composition.Counts`), a tally the number of facts of any kind that relate
  to the parent (`AtlasFlow.Composition.Tallies`). Flow applies a link or count whose
  child subflow and a subflow on the parent are both selected, and a tally when a
  subflow on the parent is; it refuses a version it does not know.
  """
  @callback composition() :: map

  @doc """
  The configured actors the model needs: `[{role, kind}]`. An owner whose default is
  `%{"kind", "config" => role}` is the actor the environment configures for that role
  (`AtlasBus.Actors`).
  """
  @callback actors() :: [{atom, String.t()}]

  @doc """
  Every relation, by name, as rela describes it with the model's additions: `from`,
  `to`, `max_outgoing`, and `parent` (a fact belongs under the one it points at) and
  `component` (made and deleted with the fact it starts at), which Flow walks.
  """
  @callback relations() :: %{String.t() => map}

  # The callback of the component that runs turns Flow calls too: the turn (its kind, the
  # relation to what it works `on`, `by` whom, its `state` field and the `running` value),
  # so an owner is not handed over while a turn of theirs runs on a fact.
  @shared [turn: 0]

  @doc "The model Flow is wired to, checked: raises when it is missing or wrong."
  def configured!, do: check!(Application.fetch_env!(:atlas, :model))

  @doc "`model` when it implements this behaviour; raises otherwise."
  def check!(model) do
    unless is_atom(model) and Code.ensure_loaded?(model),
      do: raise(ArgumentError, "the model #{inspect(model)} is not a module Flow can load")

    missing =
      for {name, arity} <- __MODULE__.behaviour_info(:callbacks) ++ @shared,
          not function_exported?(model, name, arity),
          do: "#{name}/#{arity}"

    if missing != [],
      do: raise(ArgumentError, "the model #{inspect(model)} lacks #{Enum.join(missing, ", ")}")

    model
  end

  @doc "The environment whose compiled subflows run: Atlas's, not Mix's."
  def environment, do: if(AtlasBus.environment() == "test", do: :test, else: :prod)

  @doc """
  What Flow runs of `model` in `environment`: its compiled subflows by name, the run configuration (`AtlasFlow.Runs.Store.activate/2`) and why it refuses to
  run the selected ones, if it does, with the relations and the turn it walks, and the
  actors its owners name, as `actors` (`%{role => key}`, the environment's settings)
  fills them. Raises `AtlasFlow.Model.MissingActor` (its `role`) when it does not fill
  one: Flow does not start without it.
  """
  def load(model, environment, actors \\ AtlasBus.Actors.configured()) do
    model = check!(model)
    flows = Map.new(model.subflows(environment), &{&1.name(), &1})
    {config, refusal} = AtlasFlow.Runs.Store.activate(model, flows)

    actors =
      case AtlasBus.Actors.resolve(model.actors(), actors) do
        {:ok, actors} ->
          actors

        {:error, why} ->
          # The first role not filled, as `resolve/2` meets it.
          {role, _} =
            Enum.find(model.actors(), &match?({:error, _}, AtlasBus.Actors.resolve([&1], actors)))

          raise MissingActor, role: to_string(role), message: "Flow does not start: " <> why
      end

    %{
      flows: flows,
      config: config,
      refusal: refusal,
      relations: model.relations(),
      turn: model.turn(),
      actors: actors
    }
  end

  # The configured role a run's human supervisor stands in for, inside a supervised span
  # (decision 2026-11-17 §5.7: a gate's outcome goes to the supervisor; this role's actor
  # is the fallback).
  @supervised_role "decider"

  @doc """
  An owner as Flow writes it: `%{"kind", "key"}`. One that names a configured actor
  (`%{"kind", "config" => role}`) is that role's actor in `actors` (`load/3`).

  Except one: the `decider` role, on a `run` whose state lies in one of its subflow's
  supervised `spans` and that has a human supervisor (`supervised_by`, `%{"kind",
  "key"}`) of the owner's kind, is that supervisor, unless the owner says it is not
  (`"supervisor" => false`: a state that asks someone else, such as the subject's
  producer, while its run keeps its supervisor). With no supervisor, outside every
  span, or with no run, it is the configured actor.

  An owner that asks the subject's producer (`"producer" => relation`, SC-Atlas-09) is
  the one the subject links to through that relation, which the projection passes as the
  run's `producer` (`%{"kind", "key"}` or nil): the human supervisor of the run that made
  the subject. With none (an item made by hand, or before its producer was recorded), it
  is the configured actor, or the named one (`%{"kind", "key", "producer"}`). The
  producer is of the owner's kind, unless the owner names another (`"producer_kind"`: the
  producer of one kind, else the configured actor of another).
  Never the run's own supervisor. The projection passes the run with
  its subflow's `spans` and its supervisor as the run's fact links it, of the
  supervision relation's holder kind (`AtlasFlow.Runs.Projection`). A run of a subflow a
  span names in its `with:` lies in no span of its own: the projection passes it with
  the precomputed answer of its nearest spanned run (`in_span`, a boolean) and that
  run's supervisor instead.
  """
  def owner(owner, actors, run \\ nil)

  def owner(%{"producer" => _} = owner, actors, run) do
    case producer(owner, run) do
      %{} = producer -> producer
      nil -> owner(Map.drop(owner, ["producer", "producer_kind"]), actors, nil)
    end
  end

  def owner(%{"config" => role} = owner, actors, run) do
    case supervisor(owner, run) do
      %{} = supervisor ->
        supervisor

      nil ->
        case actors do
          %{^role => %{"key" => key}} -> %{"kind" => owner["kind"], "key" => key}
          _ -> raise ArgumentError, "no configured actor #{role}; Flow loads every one it names"
        end
    end
  end

  def owner(owner, _actors, _run), do: owner

  @doc "Whether `owner` (a state's default) may go to a run's human supervisor (`owner/3`)."
  def supervisable?(owner),
    do:
      match?(%{"config" => @supervised_role}, owner) and owner["supervisor"] != false and
        not Map.has_key?(owner, "producer")

  @doc "Whether `owner` (a state's default) asks the subject's producer: its relation, or nil."
  def producer(%{"producer" => relation}) when is_binary(relation), do: relation
  def producer(_owner), do: nil

  @doc "The kind of the producer `owner` (a state's default) asks: its own, unless it names one."
  def producer_kind(owner), do: owner["producer_kind"] || owner["kind"]

  # The subject's producer, as the projection passes it, when it is of the kind asked.
  defp producer(owner, %{"producer" => %{"kind" => kind, "key" => key}})
       when is_binary(key) and key != "" do
    if kind == producer_kind(owner), do: %{"kind" => kind, "key" => key}
  end

  defp producer(_owner, _run), do: nil

  defp supervisor(
         %{"kind" => kind} = owner,
         %{"supervised_by" => %{"kind" => kind, "key" => key}} = run
       )
       when is_binary(key) and key != "" do
    if supervisable?(owner) and in_span?(run), do: %{"kind" => kind, "key" => key}
  end

  defp supervisor(_owner, _run), do: nil

  # A run of a subflow a span names in its `with:` carries its span's answer itself.
  defp in_span?(%{"in_span" => in_span}) when is_boolean(in_span), do: in_span

  defp in_span?(%{"state" => state, "spans" => spans}) when is_list(spans),
    do: Enum.any?(spans, &(state in (&1["states"] || [])))

  defp in_span?(_run), do: false
end

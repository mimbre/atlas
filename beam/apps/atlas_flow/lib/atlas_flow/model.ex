defmodule AtlasFlow.Model do
  @moduledoc """
  The model Flow runs: a module the domain compiles (its subflows, legacy flows, where
  runs are kept and how they are selected), wired by configuration at boot:

      config :atlas, model: SomeModel

  Flow reads it once when it starts; a missing module, or one without these callbacks,
  refuses the start. Flow names no model, no kind and no subflow.
  """

  @type digest :: String.t()

  @doc "The compiled subflow of each subflow the model runs (`AtlasFlow.Subflow`), in `environment`."
  @callback subflows(environment :: atom) :: [module]

  @doc "The compiled legacy flows (`AtlasFlow.Legacy`): flows whose runs are not stored yet."
  @callback legacy() :: [module]

  @doc "Where runs are kept: `%{\"kind\", \"fields\", \"writer\", \"inputs\"}`, or nil."
  @callback runs() :: nil | map

  @doc """
  How the runs of `subflow` are selected: `subject`, `admission`, `imports`,
  `projection`, `follow_through`, `verification`, `legacy` and its approved `migrations`;
  nil when it is not selected.
  """
  @callback selection(subflow :: String.t()) :: nil | map

  @doc "Every approved run migration: `from`, `to`, `states`, `rekey`/`preserve_entry`, `subflow`."
  @callback migrations() :: [map]

  @doc """
  How the results of its subflows reach one another, as versioned data:
  `%{"version" => 1, "links" => [...], "counts" => [...]}`. A link writes a child run's
  outcome to a field of its parent (`AtlasFlow.Composition.Links`), a count the parent's
  number of children and of open ones (`AtlasFlow.Composition.Counts`). Flow applies
  those whose child subflow and a subflow on the parent are both selected; it refuses a
  version it does not know.
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
  What Flow runs of `model` in `environment`: its legacy flows, its compiled subflows by
  name, the run configuration (`AtlasFlow.Runs.Store.activate/2`) and why it refuses to
  run the selected ones, if it does, with the relations and the turn it walks, and the
  actors its owners name, as `actors` (`%{role => key}`, the environment's settings)
  fills them. Raises when it does not fill one: Flow does not start without it.
  """
  def load(model, environment, actors \\ AtlasBus.Actors.configured()) do
    model = check!(model)
    flows = Map.new(model.subflows(environment), &{&1.name(), &1})
    {config, refusal} = AtlasFlow.Runs.Store.activate(model, flows)

    actors =
      case AtlasBus.Actors.resolve(model.actors(), actors) do
        {:ok, actors} -> actors
        {:error, why} -> raise ArgumentError, "Flow does not start: " <> why
      end

    %{
      legacy: model.legacy(),
      flows: flows,
      config: config,
      refusal: refusal,
      relations: model.relations(),
      turn: model.turn(),
      actors: actors
    }
  end

  @doc """
  An owner as Flow writes it: `%{"kind", "key"}`. One that names a configured actor
  (`%{"kind", "config" => role}`) is that role's actor in `actors` (`load/3`).
  """
  def owner(%{"config" => role} = owner, actors) do
    case actors do
      %{^role => %{"key" => key}} -> %{"kind" => owner["kind"], "key" => key}
      _ -> raise ArgumentError, "no configured actor #{role}; Flow loads every one it names"
    end
  end

  def owner(owner, _actors), do: owner
end

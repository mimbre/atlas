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

  @doc "The configured actors the model needs."
  @callback actors() :: [atom]

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
  run the selected ones, if it does, with the relations and the turn it walks.
  """
  def load(model, environment) do
    model = check!(model)
    flows = Map.new(model.subflows(environment), &{&1.name(), &1})
    {config, refusal} = AtlasFlow.Runs.Store.activate(model, flows)

    %{
      legacy: model.legacy(),
      flows: flows,
      config: config,
      refusal: refusal,
      relations: model.relations(),
      turn: model.turn()
    }
  end
end

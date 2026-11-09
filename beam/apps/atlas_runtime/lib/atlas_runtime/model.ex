defmodule AtlasRuntime.Model do
  @moduledoc """
  The model Runtime runs turns for: a module the domain compiles, wired by configuration
  at boot:

      config :atlas, model: SomeModel

  Runtime reads it when it starts; a missing module, or one without these callbacks,
  refuses the start. Runtime names no model and no kind: the turn's kind and fields, the
  facts a turn works on, the agent's kind and the guidance records are all the model's.
  """

  @typedoc "Facts' answer to a read, as `AtlasRuntime.Talk.read/3` gives it."
  @type answer :: map

  @typedoc "A reader of facts: `lookup.(kind, query)`, answered as Facts answers a read."
  @type lookup :: (kind :: String.t(), query :: map -> answer)

  @doc """
  The turn, or nil when the model runs none: the names of its kind and fields, with
  string keys (`kind`, `key`, `on`, `by`, `state`, `running`, `ended`, `machine`, `lease`,
  `activity`, `why`, `ended_at`, `outcome`, `attempt`), and

    * `on_kinds`: the kinds a turn's `on` relation leads to;
    * `items`: the facts a turn can work on, in order, each `%{"kind", "owner_relation"}`:
      owned through `owner_relation`. Whether one is open, and whether a deferred
      handover bars a new turn on it, Facts says: its `"presentation"` (`actionable`,
      `handover`, `owner`), which a read asks for with `"presentation" => true`.
  """
  @callback turn() :: nil | map

  @doc """
  The agent a turn is by, or nil: `%{"kind", "cannot_run"}`, its kind (nil unless the
  turn's `by` leads to one) and the field that says it cannot run on a machine.
  """
  @callback agent() :: nil | map

  @doc """
  The durable guidance records, or nil when the model keeps none: for each of
  `execution`, `interaction` and `receipt`, `%{"kind", "fields"}`.
  """
  @callback guidance() :: nil | map

  @doc """
  What a worker reads before it acts on `fact` (the fact read as Facts answers it, with
  its links), as short plain text; nil when nothing applies. Related facts are read
  through `lookup`; a read that fails leaves its part out.
  """
  @callback read_first(fact :: map, lookup) :: nil | String.t()

  @doc "The model Runtime is wired to, checked: raises when it is missing or wrong."
  def configured!, do: check!(Application.fetch_env!(:atlas, :model))

  @doc "`model` when it implements this behaviour; raises otherwise."
  def check!(model) do
    unless is_atom(model) and Code.ensure_loaded?(model),
      do: raise(ArgumentError, "the model #{inspect(model)} is not a module Runtime can load")

    missing =
      for {name, arity} <- __MODULE__.behaviour_info(:callbacks),
          not function_exported?(model, name, arity),
          do: "#{name}/#{arity}"

    if missing != [],
      do: raise(ArgumentError, "the model #{inspect(model)} lacks #{Enum.join(missing, ", ")}")

    model
  end
end

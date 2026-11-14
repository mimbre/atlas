defmodule AtlasFlow.TestModel do
  @moduledoc """
  A model for one test: the depot's (`AtlasFlow.Depot`), with some of its parts given
  instead: `subflows:` (every environment), `runs:`, `selection:` (by
  subflow name; nil deselects it), `composition:` (the depot's has no links or counts),
  `relations:` (the depot's, with the model's
  additions), `turn:` (nil: the depot runs no turns) or `actors:` (the configured actors
  its owners name, `[{role, kind}]`; none by default).

      defmodule Plain do
        use AtlasFlow.TestModel, subflows: [AtlasFlow.Sorts.Plain]
      end
  """

  defmacro __using__(opts) do
    quote do
      @behaviour AtlasFlow.Model
      @parts Map.new(unquote(opts))

      @impl true
      def subflows(env),
        do: Map.get_lazy(@parts, :subflows, fn -> AtlasFlow.Depot.subflows(env) end)

      @impl true
      def runs, do: Map.get_lazy(@parts, :runs, &AtlasFlow.Depot.runs/0)

      @impl true
      def selection(name),
        do:
          Map.get_lazy(@parts[:selection] || %{}, name, fn -> AtlasFlow.Depot.selection(name) end)

      @impl true
      def migrations, do: []
      @impl true
      def composition, do: Map.get_lazy(@parts, :composition, &AtlasFlow.Depot.composition/0)
      @impl true
      def actors, do: Map.get(@parts, :actors, [])
      @impl true
      def relations, do: Map.get_lazy(@parts, :relations, &AtlasFlow.Depot.relations/0)

      def turn, do: Map.get_lazy(@parts, :turn, &AtlasFlow.Depot.turn/0)
    end
  end

  @doc "The run configuration of `model` (where runs are kept, how they are selected)."
  def config(model \\ AtlasFlow.Depot), do: AtlasFlow.Model.load(model, :prod).config

  @doc "The depot's sort, compiled for `environment`."
  def sort(environment \\ :prod), do: hd(AtlasFlow.Depot.subflows(environment))
end

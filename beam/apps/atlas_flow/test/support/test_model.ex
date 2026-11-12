defmodule AtlasFlow.TestModel do
  @moduledoc """
  A model for one test: the depot's (`AtlasFlow.Depot`), with some of its parts given
  instead: `legacy:`, `subflows:` (every environment), `runs:`, or `selection:` (by
  subflow name; nil deselects it).

      defmodule Later do
        use AtlasFlow.TestModel, legacy: [AtlasFlow.Packs.Later]
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
      def legacy, do: Map.get_lazy(@parts, :legacy, &AtlasFlow.Depot.legacy/0)
      @impl true
      def runs, do: Map.get_lazy(@parts, :runs, &AtlasFlow.Depot.runs/0)

      @impl true
      def selection(name),
        do:
          Map.get_lazy(@parts[:selection] || %{}, name, fn -> AtlasFlow.Depot.selection(name) end)

      @impl true
      def migrations, do: []
      @impl true
      def actors, do: []
    end
  end

  @doc "The run configuration of `model` (where runs are kept, how they are selected)."
  def config(model \\ AtlasFlow.Depot), do: AtlasFlow.Model.load(model, :prod).config

  @doc "The depot's sort, compiled for `environment`."
  def sort(environment \\ :prod), do: hd(AtlasFlow.Depot.subflows(environment))
end

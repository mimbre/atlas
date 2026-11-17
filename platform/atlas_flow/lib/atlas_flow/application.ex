defmodule AtlasFlow.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    with {:ok, work_source} <- work_source() do
      engine =
        if Application.get_env(:atlas_flow, :start, true) do
          every = Application.get_env(:atlas_flow, :tick_seconds, 60) * 1000

          # The model is wired by configuration (`config :atlas, model: …`); without one, or
          # with a module that is no model, Flow does not start.
          [
            {AtlasFlow.Engine,
             every: every, name: AtlasFlow.Engine, model: AtlasFlow.Model.configured!()}
          ]
        else
          []
        end

      children = [AtlasFlow.Activities.Effect.Inbox] ++ engine ++ work_source

      Supervisor.start_link(children, strategy: :one_for_one, name: AtlasFlow.Root)
    end
  end

  @doc """
  The work source's processes (plan m3 §3.1, A2): the result store, Bases, Dispatch and
  Delivery, only when `config :atlas_flow, :work_source` is set; none by default. With the
  work source set and no result store directory (`config :atlas_flow, :results, dir:`),
  Flow does not start: every result would be too large.

  They run under one supervisor, in that order, `rest_for_one`: the store rebuilds its pins
  from Facts before it serves a call, and Dispatch and Delivery start after it.
  """
  def work_source do
    case Application.get_env(:atlas_flow, :work_source) do
      nil ->
        {:ok, []}

      _set ->
        if Keyword.get(Application.get_env(:atlas_flow, :results, []), :dir) do
          children = [
            {AtlasFlow.Results, pins: &result_pins/0},
            AtlasFlow.Bases,
            AtlasFlow.Dispatch,
            AtlasFlow.Delivery
          ]

          {:ok,
           [
             %{
               id: AtlasFlow.WorkSource.Root,
               type: :supervisor,
               start:
                 {Supervisor, :start_link,
                  [children, [strategy: :rest_for_one, name: AtlasFlow.WorkSource.Root]]}
             }
           ]}
        else
          {:error, :work_source_without_results}
        end
    end
  end

  # The store reads its pins from Facts itself, before it serves anything (§3.4 "Index").
  @doc false
  def result_pins do
    case AtlasBus.attach("flow/results") do
      :ok -> AtlasFlow.WorkSource.Leases.pins()
      {:error, why} -> raise "the result store cannot read Facts: #{inspect(why)}"
    end
  end
end

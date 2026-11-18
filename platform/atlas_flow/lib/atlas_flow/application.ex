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

      # The work source first: the Engine's first round already finds Bases (M3 A4).
      children = [AtlasFlow.Activities.Effect.Inbox] ++ work_source ++ engine

      Supervisor.start_link(children, strategy: :one_for_one, name: AtlasFlow.Root)
    end
  end

  @doc """
  The work source's processes (plan m3 §3.1, A2): the result store, Bases, Dispatch,
  Delivery and Landing (F3-L: it publishes checked results to Code and marks drafts
  ready), only when `config :atlas_flow, :work_source` is set; none by default. With the
  work source set and no result store directory (`config :atlas_flow, :results, dir:`),
  Flow does not start: every result would be too large.

  They run under one supervisor, in that order, `rest_for_one`: the store rebuilds its pins
  from Facts before it serves a call, and Dispatch, Delivery and Landing start after it. That
  supervisor starts before the Engine, so the Engine's first round finds Bases' table.

  The HTTP listener (`AtlasFlow.Backend.Listener`, A3) comes last, and only when the work
  source has a `port`: without one there is no listener. It binds 127.0.0.1 only.
  """
  def work_source do
    case Application.get_env(:atlas_flow, :work_source) do
      nil ->
        {:ok, []}

      settings ->
        if Keyword.get(Application.get_env(:atlas_flow, :results, []), :dir) do
          children =
            [
              {AtlasFlow.Results, pins: &result_pins/0},
              AtlasFlow.Bases,
              AtlasFlow.Dispatch,
              AtlasFlow.Delivery,
              AtlasFlow.Landing
            ] ++ listener(settings)

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

  @doc """
  The listener child of the work source's `settings`: none without a `port`, else
  `AtlasFlow.Backend.Listener` on 127.0.0.1 and that port.
  """
  def listener(settings) do
    case Keyword.get(settings, :port) do
      nil -> []
      port -> [{AtlasFlow.Backend.Listener, port: port}]
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

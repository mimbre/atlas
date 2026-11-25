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
      # Health first: Dispatch and the Engine note in its table what Control's health page
      # reads (IS-Atlas-117).
      children = [AtlasFlow.Health, AtlasFlow.Activities.Effect.Inbox] ++ work_source ++ engine

      Supervisor.start_link(children, strategy: :one_for_one, name: AtlasFlow.Root)
    end
  end

  @doc """
  The work source's processes (plan m3 §3.1, A2): Bases, Dispatch and Delivery, only when
  `config :atlas_flow, :work_source` is set; none by default. A result travels over Git
  (`refs/atlas/results/<task>`), so Flow keeps no result store (IS-Atlas-100).

  They run under one supervisor, in that order, `rest_for_one`. That supervisor starts
  before the Engine, so the Engine's first round finds Bases' table.

  The HTTP listener (`AtlasFlow.Backend.Listener`, A3) comes last, and only when the work
  source has a `port`: without one there is no listener. It binds 127.0.0.1 only.
  """
  def work_source do
    case Application.get_env(:atlas_flow, :work_source) do
      nil ->
        {:ok, []}

      settings ->
        children = [AtlasFlow.Bases, AtlasFlow.Dispatch, AtlasFlow.Delivery] ++ listener(settings)

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
end

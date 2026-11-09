defmodule AtlasFlow.Legacy do
  @moduledoc """
  A legacy flow, compiled by the model: a flow whose runs are not stored yet. A fact is
  in the first of its states whose conditions hold; Flow writes its owner and what is
  expected on the fact (or on the fact its `on` relation points at). State names are
  text.
  """

  @type state :: String.t() | nil

  @callback name() :: String.t()
  @doc "The kinds it runs on."
  @callback kinds() :: [String.t()]
  @doc "Where it writes: `on`, `field`, `state_field`, `handover_field`, `owner_relation`, as given."
  @callback writes() :: map
  @doc "The relations its `empty` conditions name."
  @callback empties() :: [String.t()]
  @doc """
  The state `fact` is in, and the vars its texts are filled from. `children` are the facts
  that point at it through `parents` (parent relations) or `pointing` (associations that
  end at its kind and that it reads).
  """
  @callback state(
              fact :: map,
              children :: [map],
              parents :: [String.t()],
              pointing :: [String.t()]
            ) ::
              {state, map}
  @callback done?(state) :: boolean
  @doc "Who owns a fact in `state`: `%{\"kind\", \"key\"}`, or nil when done."
  @callback owner(state) :: nil | map
  @doc "What its owner is expected to do in `state`, filled from `vars`; nil when done."
  @callback expected(state, vars :: map) :: nil | String.t()
  @callback why(state) :: nil | String.t()
  @doc "How often a fact in `state` is looked at again, in ms; nil for Flow's default."
  @callback every(state) :: nil | pos_integer

  @doc "The flows that may run: those Facts found no problems in (`flow_problems`)."
  def runnable(flows, description) do
    problems = description["flow_problems"] || %{}
    Enum.filter(flows, &((problems[&1.name()] || []) == []))
  end

  @doc "The flow that runs on `kind`, or nil."
  def for_kind(flows, kind), do: Enum.find(flows, &(kind in &1.kinds()))

  @doc "Every kind a flow runs on."
  def kinds(flows), do: flows |> Enum.flat_map(& &1.kinds()) |> Enum.uniq()

  @doc "The kinds the flows assign to: what their owner relations point at."
  def owner_kinds(flows, description) do
    for flow <- flows,
        relation = flow.writes()["owner_relation"],
        is_binary(relation),
        kind <- get_in(description, ["relations", relation, "to"]) || [],
        uniq: true,
        do: kind
  end

  @doc """
  The associations (not parent relations) that the flow's `empty` conditions name and
  that end at `kind`: Flow reads what points at a fact through them.
  """
  def pointing(flow, description, kind) do
    for relation <- flow.empties(),
        spec = get_in(description, ["relations", relation]),
        is_map(spec) and spec["parent"] != true and kind in (spec["to"] || []),
        uniq: true,
        do: relation
  end
end

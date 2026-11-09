defmodule AtlasFlow.Subflow do
  @moduledoc """
  One subflow in one environment, compiled by the model. Flow's run machine
  (`AtlasFlow.Runs.Run`) asks it everything a run needs; state names are text, as runs
  store them. A state the subflow does not have does nothing (no mechanism, no timers,
  no outputs, `:stay`).
  """

  @type state :: String.t()
  @type values :: %{optional(String.t()) => term}

  @callback name() :: String.t()
  @doc "The kind of fact it runs on."
  @callback subject() :: String.t()
  @doc "Its identity: the digest of its canonical data; a run keeps the digest it started with."
  @callback digest() :: String.t()
  @callback initial() :: state
  @doc "Its states, sorted."
  @callback states() :: [state]
  @callback per_subject() :: String.t()
  @doc "Whether the trigger (`:create`, or `:predicate` on the subject's values) starts a run."
  @callback start?(trigger :: :create | :predicate, values) :: boolean
  @doc "What entering `state` writes, in order: `{:set, values}` and `{:create, %{\"type\", \"properties\", \"relate\"}}`."
  @callback enter(state, values) :: [{:set, map} | {:create, map}]
  @doc """
  Where `state` leads: on a change of the subject (`nil`: branches no role takes), on a
  mechanism's result (`:result`), or on a role's input (`%{roles:, changed:}`).
  """
  @callback next(state, values, nil | :result | %{roles: [String.t()], changed: map}) ::
              {:to, state} | :stay
  @doc "The state's timers: `%{\"name\", \"period\", \"to\", \"since\"}`."
  @callback timers(state) :: [map]
  @callback mechanism(state) :: nil | {:pass | :gate | :effect, map}
  @callback waiting_for(state) :: [String.t()]
  @doc "The subflow's owner: `%{\"via\", \"relation\", \"default\", \"preserve_kind\"}`."
  @callback owner() :: map
  @doc "The owner of `state`: its own, else the subflow's."
  @callback owner(state) :: map
  @doc "What the owner sees in `state`: `expected` (filled from `values`), `why`, `todo`, `deadline` (a timer's name)."
  @callback present(state, values) :: nil | map
  @callback final?(state) :: boolean
end

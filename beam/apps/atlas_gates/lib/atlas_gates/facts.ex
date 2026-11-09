defmodule AtlasGates.Facts do
  @moduledoc """
  How Gates reaches Facts to record a verdict: a module with these callbacks and its
  state, given as `{module, state}`. Facts is the one place verdicts are kept; Gates never
  writes rela itself.

    * `AtlasGates.Facts.Bus`: over the Bus, from the calling process, for a caller in a
      node with the core's Bus (Flow, State, Control, the integration proof);
    * `AtlasGates.Facts.Control`: through Control with the `atlas` client, for a caller on
      another machine (the coordinator's `mix atlas.gates.evaluate`): Control writes the
      fact over the Bus to Facts under the same rules.
  """

  @typedoc "Whatever the module needs: an endpoint, a client, an environment."
  @type state :: term()

  @doc """
  The key of a recorded verdict of `kind` that has every value in `identity` (strings),
  newest first; nil when there is none. An error when Facts could not be read.
  """
  @callback find(state, kind :: String.t(), identity :: [String.t()]) ::
              {:ok, String.t() | nil} | {:error, String.t()}

  @doc """
  Create one verdict of `kind` with `values` (property to value) and `links` (relation to
  key), sent as the request `request_id`, so a resend is stored once: `{:ok, key}` or
  `{:error, reason}` when Facts refused it or did not answer.
  """
  @callback create(
              state,
              kind :: String.t(),
              request_id :: String.t(),
              values :: map(),
              links :: map()
            ) :: {:ok, String.t()} | {:error, String.t()}
end

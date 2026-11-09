defmodule Model.Profiles.Foundation do
  @moduledoc """
  A private dependency proof, not an installed workflow (MIX_ENV=test only): foundation
  alone, without audit, software or the product plan. Each composition binds what a
  gate verdict is about, here only decisions. It runs no subflows, so no run is
  selected.

      MIX_ENV=test mix model.gen --contract Model.Profiles.Foundation --out DIR
  """
  use RelaDSL.Composition,
    name: "foundation",
    subflow_behaviour: AtlasFlow.Subflow,
    legacy_behaviour: AtlasFlow.Legacy

  # The model Facts, Flow, Gates, Runtime and Control are wired to (config :atlas, model: …).
  @behaviour AtlasFacts.Model
  @behaviour AtlasFlow.Model
  @behaviour AtlasGates.Model
  @behaviour AtlasRuntime.Model
  @behaviour AtlasControl.Model

  schema(
    version: "1.0",
    namespace: "https://example.invalid/fixture#",
    description: "Private dependency fixture"
  )

  # Compiled for both environments, so a private instance of either can run it.
  environments([:prod, :test])
  modules([Model.Foundation])

  relation(:about,
    label: "about",
    from: [:gate_verdict],
    to: [:decision],
    max_outgoing: 1,
    inverse: {:gate_verdicts, "gate verdicts"}
  )

  start_page(assigned: [empty: "Nothing is assigned to you."])

  defcomposition :foundation do
    subflows([])
  end
end

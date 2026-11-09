defmodule AtlasFlow.Yard do
  @moduledoc """
  The neutral model Flow's composition tests run, written in the Rela DSL as a model is:
  cups stand on a tray. A cup's subflow `pour` ends `full` or `spilt`; the composition
  links that outcome to its tray (`outcome`, from the current cup only: the one poured
  for the tray's `revision`), and counts the tray's cups (`cups`, `open_cups`). Two
  subflows run on one tray: `fill` awaits the outcome, `tally` waits until no cup is
  open, and starts only once the tray has cups. Every subflow is selected while its
  subject is in its `first` phase.
  """
  use RelaDSL.Composition,
    name: "yard",
    subflow_behaviour: AtlasFlow.Subflow

  @behaviour AtlasFlow.Model

  schema(version: "1.0", namespace: "https://example.invalid/yard#", description: "A yard.\n")
  modules([AtlasFlow.Yard.Stock])
  environments([:prod, :test])

  acl(comment: "The yard's roles.")
  role("yard", read: ["*"], create: [:cursor], update: [:tray, :cup, :cursor])
  role("hand", read: ["*"], update: [:tray, :cup])
  assign("system:yard", "yard")

  defcomposition :yard do
    subflows([AtlasFlow.Yard.Tray, AtlasFlow.Yard.Cup])

    link(:pour,
      to: {:tray, :on_tray},
      field: :outcome,
      states: [full: :full, spilt: :spilt],
      stale: :drop,
      current: {:revision, :revision}
    )

    count(:pour, to: {:tray, :on_tray}, all: :cups, open: :open_cups)
  end
end

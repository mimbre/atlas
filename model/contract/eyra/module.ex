defmodule Model.Eyra do
  @moduledoc """
  The product plan: scenes and their use cases, with their hierarchy and acceptance,
  and how far an item is.
  """
  use RelaDSL.Module,
    path: "modules/eyra/schema.yaml",
    concepts: [Model.Scene, Model.UseCase]

  progress_order(
    order: [:refine, :ready_to_pick_up, :specification, :design, :development, :to_test],
    done_label: "Done",
    to_test: [value: :to_test, label: "To test"]
  )
end

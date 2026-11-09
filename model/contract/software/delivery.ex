defmodule Model.Delivery do
  @moduledoc "Work of one issue that a pull request of another also did."
  use RelaDSL

  relation(:done_in,
    label: "also done in",
    description: "A merged pull request of another issue that also did this one.",
    from: [:issue],
    to: [:pull_request],
    inverse: {:also_done, "also done"},
    set_by: [:migration, :connector]
  )
end

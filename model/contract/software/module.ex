defmodule Model.Software do
  @moduledoc """
  Software: issues and their pull requests, the reviews and tests of those, and the
  pull requests of other issues that also did one. Its subflows build them.
  """
  use RelaDSL.Module,
    path: "modules/software/schema.yaml",
    concepts: [Model.Issue, Model.PullRequest, Model.PrReview, Model.PrTest, Model.Delivery]
end

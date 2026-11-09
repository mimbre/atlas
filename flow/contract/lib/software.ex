defmodule AtlasFlowContract.Software do
  @moduledoc """
  The composition of the software subflows: building a scene, its use cases, their
  issues, and the pull requests of those issues, with their reviews and tests.

  Each subflow runs on its own subject; what one reports to another is written here:

    * a pull request's review and test report their outcome to it (`review_outcome`,
      `test_outcome`); a result from a review or test that a newer one replaced is
      dropped;
    * a pull request reports to its issue (`pr_outcome`), which waits for it in
      `in_pr`;
    * a use case counts its issues, and a scene its use cases (`children`, and
      `open_children`: those whose subflow has not ended), to know when all are built.

  `mix atlas.flow.gen` generates the targets from this module.
  """
  use AtlasFlowGenerator.Schema.Composition

  alias AtlasFlowContract.{Decision, Issue, PrReview, PrTest, PullRequest, Scene, UseCase}

  defcomposition :software do
    subflows([Issue, PullRequest, PrReview, PrTest, UseCase, Scene, Decision])

    link(:pr_review,
      to: {:pull_request, :review_of},
      field: :review_outcome,
      states: [approved: :approved, changes_requested: :changes_requested],
      stale: :drop
    )

    link(:pr_test,
      to: {:pull_request, :test_of},
      field: :test_outcome,
      states: [passed: :passed, failed: :failed],
      stale: :drop
    )

    link(:pull_request,
      to: {:issue, :in_issue},
      field: :pr_outcome,
      states: [changes_requested: :changes_requested, integrated: :integrated, closed: :closed]
    )

    count(:issue, to: {:use_case, :in_use_case}, all: :children, open: :open_children)

    count(:test_and_accept_use_case,
      to: {:scene, :in_scene},
      all: :children,
      open: :open_children
    )
  end
end

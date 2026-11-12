defmodule Model.PrReview do
  @moduledoc """
  The review of a pull request: a subflow on the `pr_review` that the pull request
  subflow creates. A reviewer works through the exact revision with an agent on
  their own Runtime (a pass with the person, which writes no result) and sets the
  verdict themselves.

    * The verdict ends it as `approved` or `changes_requested`; the composition
      reports that to the pull request (`review_outcome`).
    * No verdict in three days escalates it to a maintainer, next to the reviewer.
    * A newer revision of the pull request supersedes it (`superseded`, set by
      Atlas when the pull request checks again).
  """
  use RelaDSL

  entity :pr_review,
    label: "PR review",
    plural: "pr_reviews",
    id_type: :short,
    id_prefix: "PRR-",
    description: """
    The review of one pull request by a person, created by the pull request's
    flow. Its outcome is reported back to the pull request.
    """ do
    field(:title, :string, required: true, description: "What is reviewed")
    field(:verdict, :string, description: "The reviewer's verdict: approved or changes_requested")

    field(:superseded, :boolean,
      default: false,
      description: "True when a newer revision of the pull request replaced this review"
    )
  end

  relation(:review_of,
    label: "review of",
    description: "A review belongs to one pull request; a pull request has its reviews.",
    from: [:pr_review],
    to: [:pull_request],
    max_outgoing: 1,
    inverse: {:reviews, "reviews"}
  )

  subflow :pr_review, label: "PR review", subject: :pr_review do
    owner relation: :assigned_to
    start :create
    initial :working

    state :working, label: "PR review in progress" do
      branch to: :superseded, by: :atlas, when: "entity.superseded == true"

      pass :developer,
        mode: :review,
        folder: {:materialize, :parent_revision},
        permissions: :materialized_folder,
        with_person: true,
        writes: :none

      wait_for [:reviewer],
        on: :verdict,
        reset: false,
        approved: :approved,
        changes_requested: :changes_requested

      timer :stalled, "3d", to: :escalated, label: "No outcome in three days"
    end

    state :escalated, label: "Escalated" do
      branch to: :superseded, by: :atlas, when: "entity.superseded == true"

      wait_for [:maintainer, :reviewer],
        on: :verdict,
        reset: false,
        approved: :approved,
        changes_requested: :changes_requested
    end

    final :approved
    final :changes_requested
    final :superseded, label: "Superseded by a newer PR revision", status: :cancelled
  end
end

defmodule Model.PrReview do
  @moduledoc """
  The review of a pull request: a subflow on the `pr_review` that the pull request
  subflow creates, for one exact revision of it (`revision`). A reviewer works
  through that revision and sets the verdict themselves, naming themselves in
  `verdict_by` in the same change: Facts takes it as their trusted choice.

    * The verdict ends it as `approved` or `changes_requested`; the composition
      reports that to the pull request (`review_outcome`), but only while the review
      is for the pull request's current revision (`current:`): a review of an older
      revision reports nothing, however late it ends.
    * No verdict in three days escalates it to a maintainer, next to the reviewer.
    * A newer revision of the pull request supersedes it (`superseded`).

  It runs on Flow's durable runs (`select`). Its owner is its reviewer (`review_by`),
  a person or an agent, who gives the verdict by hand. Flow sends no review pass to a
  Runtime any more (F0, the Flow Engine plan): review on machinery comes back as a Flow
  task. The packet fields (`packet_tree`, `packet_id`, `packet_fingerprint`) stay on the
  kind, unread by the subflow.

  `superseded` is taken as it is written (no role): nothing writes it as Atlas; a run
  cannot write a field on its child, so it is set by hand.
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
    icon(:magnifier)
    field(:title, :string, intent: :title, required: true, description: "What is reviewed")
    field(:verdict, :string, description: "The reviewer's verdict: approved or changes_requested")

    field(:superseded, :boolean,
      default: false,
      description: "True when a newer revision of the pull request replaced this review"
    )

    field(:revision, :string,
      description: "The exact revision of the pull request this review is for (its head commit)"
    )

    field(:packet_tree, :string,
      description:
        "The tree of the frozen review packet of the revision, on the reviewer's machine (an absolute path)"
    )

    field(:packet_id, :string, description: "The frozen review packet's id")
    field(:packet_fingerprint, :string, description: "The frozen review packet's fingerprint")
  end

  relation(:review_of,
    label: "review of",
    description: "A review belongs to one pull request; a pull request has its reviews.",
    from: [:pr_review],
    to: [:pull_request],
    max_outgoing: 1,
    inverse: {:reviews, "reviews"}
  )

  # Who reviews it, and so owns it while it runs. Anyone may hand a review to its
  # reviewer, as with assigned_to.
  relation(:review_by,
    label: "review by",
    description: "Who reviews it; one, a person or an agent.",
    from: [:pr_review],
    to: [:person, :agent],
    max_outgoing: 1,
    inverse: {:reviews_to_do, "reviews to do"}
  )

  # The review and the test of a pull request each take one verdict, from whoever names
  # themselves here as they give it: the one relation their roles are checked by.
  relation(:verdict_by,
    label: "verdict by",
    description: "Who gave the verdict of a review or test; one, a person or an agent.",
    from: [:pr_review, :pr_test],
    to: [:person, :agent],
    max_outgoing: 1,
    inverse: {:verdicts, "verdicts"},
    only_target: [
      error: "only the one who gives the verdict sets verdict_by, to themselves",
      also: [:migration, :flow]
    ]
  )

  subflow :pr_review, label: "PR review", subject: :pr_review do
    owner relation: :review_by
    start :create
    initial :working

    # It waits for the reviewer's answer, by hand.
    state :working, label: "PR review in progress" do
      branch to: :superseded, when: "entity.superseded == true"

      wait_for [:reviewer],
        on: :verdict,
        reset: false,
        approved: :approved,
        changes_requested: :changes_requested

      timer :stalled, "3d", to: :escalated, label: "No outcome in three days"
    end

    state :escalated, label: "Escalated" do
      branch to: :superseded, when: "entity.superseded == true"

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

  # How the runs of pr_review are selected, and imported from the review as it was before
  # the subflow ran: the first row that holds gives the entry. A final row is completed
  # history (no entry writes, nothing rerun); the last row takes every open review into
  # `working`, its wait, with its three days counted from the import (a review records no
  # time it opened). Superseded first, as the subflow's own branch comes first.
  select(:pr_review,
    choices: [:verdict],
    roles: [reviewer: :verdict_by, maintainer: :verdict_by],
    admission: [],
    imports: [
      [when: [superseded: [true]], state: :superseded],
      [when: [verdict: [:approved]], state: :approved],
      [when: [verdict: [:changes_requested]], state: :changes_requested],
      [when: [], state: :working]
    ]
  )
end

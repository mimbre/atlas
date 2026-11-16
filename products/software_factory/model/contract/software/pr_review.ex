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

  It runs on Flow's durable runs (`select`). Its owner is its reviewer (`review_by`).
  While it is `working`, a reviewer that is an agent with a Runtime (its `machine`)
  reviews through that Runtime, once:

    * the pass is a Claude turn on the frozen review packet that the review names
      (`packet_tree`, `packet_id`, `packet_fingerprint`), with `review-packet` permissions;
      the packet must have been frozen for `revision` (`atlas-runtime snapshot freeze
      --revision`, on the reviewer's machine), or Runtime refuses it; until the review
      names one, or for a reviewer with no machine (a person), there is no pass, and the
      reviewer answers by hand, as before;
    * its findings' verdict (`atlas-runtime snapshot findings`) is the reviewer's own
      answer: `pass` approves, `changes_required` requests changes; Flow writes the
      `verdict` and names the reviewer in `verdict_by`. An `uncertain` verdict, findings
      Runtime refuses, or a packet it refuses (another revision's, changed, or not a
      packet) answer nothing: the review waits for the reviewer by hand and escalates in
      three days, as before;
    * an offline Runtime leaves the pass waiting (the three days still count); a changed
      revision, packet or reviewer makes it another pass, also after a pass that answered
      nothing, and the first one's late result changes nothing; superseded, a late result
      changes nothing either.

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
    field(:title, :string, required: true, description: "What is reviewed")
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

  # Who reviews it, and so owns it while it runs: an agent reviews through its Runtime's
  # pass, a person by hand. Anyone may hand a review to its reviewer, as with assigned_to.
  relation(:review_by,
    label: "review by",
    description: "Who reviews it; one, a person or an agent.",
    from: [:pr_review],
    to: [:person, :agent],
    max_outgoing: 1,
    inverse: {:reviews_to_do, "reviews to do"}
  )

  # The review and the test of a pull request each take one verdict, from whoever names
  # themselves here as they give it: the one relation their roles are checked by. Flow
  # names the reviewer here for the verdict their own Runtime's review pass gave.
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

    # It waits for the reviewer's answer, by hand or through their pass (`input_required`
    # given, as a state with a mechanism is otherwise working).
    state :working, label: "PR review in progress", status: :input_required do
      branch to: :superseded, when: "entity.superseded == true"

      # An agent reviewer's Runtime reviews the frozen packet; its answer is the reviewer's.
      pass :reviewer,
        with_person: true,
        writes: :none,
        contract: 1,
        name: "review",
        routing: [machine_field: "machine"],
        fingerprint: [
          fields: ["revision", "packet_tree", "packet_id", "packet_fingerprint"],
          relations: []
        ],
        packet_from: [
          cwd: "packet_tree",
          packet_id: "packet_id",
          fingerprint: "packet_fingerprint",
          revision: "revision"
        ],
        request: [
          mode: "start",
          assignment: """
          Review the pull request revision frozen in this folder (a review packet: the
          tree, ../packet.json and ../diff.json). Write your findings to
          ../findings/findings.json as the review-packet findings contract says: version
          1, this packet's packet_id and fingerprint, your verdict (pass,
          changes_required or uncertain), a summary, the findings, and what you checked
          and did not check. Then end.
          """,
          permissions: "review-packet",
          packet_contract: 1,
          backend: "claude",
          vendors: ["claude"]
        ],
        answer: [
          field: "verdict",
          by: "verdict_by",
          role: "reviewer",
          outcomes: [pass: "approved", changes_required: "changes_requested"]
        ]

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

  # The approved migration of its runs, from the digest the base branch recorded
  # (RelaDSL.RunIdentity); the same in prod and test. No run had that digest: the
  # subflow was never selected before slice 7. A run that did would move along it as a
  # state migration (re-entering its state), never as a re-key, since the pass went; it
  # leads on to the next migration.
  migrate(:pr_review,
    from: "ee1314e80a41b4d4102923cc46d08126403ea5fc3c58bcf49d88617823acd86b",
    to: "7291ab5579991c4083ad2d1f18c211a7cc7c85ec27735c8d00d0d99e8752542e",
    states: :same,
    reason: "Slice 7: selected without its pass; superseded taken as written"
  )

  # The pass back in `working`, for a reviewer with a Runtime. Every run keeps its state,
  # entry, timers and anything frozen (`preserve_entry`): the three days of a waiting
  # review still count from where they did, and no state is entered again. A run waiting
  # in `working` then starts its pass, once its reviewer has a machine and the review
  # names its packet; any other run goes on as it did.
  migrate(:pr_review,
    from: "7291ab5579991c4083ad2d1f18c211a7cc7c85ec27735c8d00d0d99e8752542e",
    to: "05019b5d840dc936ea1f6f59f7be2849967f321a975b62bba01dacde16fa1682",
    states: :same,
    preserve_entry: true,
    reason: "The review pass for a reviewer with a Runtime; live entries and timers kept"
  )
end

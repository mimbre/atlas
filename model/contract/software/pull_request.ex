defmodule Model.PullRequest do
  @moduledoc """
  The pull request subflow. It starts when a pull request is recorded, and it ends when
  it is merged (`integrated`) or closed.

  How it reads:

    * `checking` waits for the review and the test of the pull request (`pr_review`,
      `pr_test`), each with a subflow of its own. Their outcomes come back as
      `review_outcome` and `test_outcome`, written by the composition's links, and only
      from the review and test of its current `revision`.
    * Approved and passed, together, lead to `integrating`: a rule Rela can express,
      so it is a branch and not a gate.
    * Changes requested or a failed test lead to `changes_requested`, until a new
      revision arrives (`update`) and the checks start again.
    * Merged or closed (GitHub's `state`, as its connector fills it) ends it from every
      state that is not final.

  Slice 8 runs it on Flow's durable runs (`select`), in place of the legacy flow
  `review_and_merge`. Three parity fixes keep it to what runs today, where a person or
  an agent merges a pull request by hand and Flow only presents it:

    * no integrate effect yet: Code has no receiver that passed the effect contract, and
      an effect Flow cannot run would refuse every selected subflow; `integrating` is
      the merge by hand, ended by the merge, so the `blocked` that only a refused or
      silent effect reached is gone (the `integrate` gate stays, for Code);
    * no creates yet: Flow cannot create a review or a test, whose kinds have short ids
      that Rela makes and Flow's create names one, nor fill their `revision`; whoever
      asks for a review or test creates it for the pull request's current `revision`,
      as today;
    * a new revision is reported by whoever pushes it (`update`, a plain branch): nothing
      in Atlas reports one yet, and a branch only Atlas takes would never be taken.
  """
  use RelaDSL

  type(:pull_request_state,
    values: [:open, :closed, :merged],
    labels: [open: "Open", closed: "Closed", merged: "Merged"]
  )

  type(:github_pull_url,
    description: "The web address of a GitHub pull request",
    validations: [
      [
        pattern: "^https://github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+$",
        error: "Must be a GitHub pull request URL, e.g. https://github.com/eyra/atlas/pull/12"
      ]
    ],
    format: :url
  )

  entity :pull_request,
    label: "Pull request",
    plural: "pull_requests",
    aliases: ["pr"],
    id_type: :manual,
    id_prefix: "PR-",
    description: """
    A GitHub pull request for an issue. Linked by URL; a GitHub connector
    fills title and state later. The id is derived from the URL,
    PR-<owner>-<repo>-<number>, so linking the same URL twice is one record.
    """ do
    field(:url, :github_pull_url, required: true, unique: true, description: "GitHub: url")
    field(:title, :string, description: "GitHub: title", set_by: :connector)
    field(:state, :pull_request_state, description: "GitHub: state", set_by: :connector)
    field(:draft, :boolean, default: false, description: "GitHub: isDraft", set_by: :connector)

    field(:review_outcome, :string,
      description: "Flow: how its review ended (none, approved, changes_requested)"
    )

    field(:test_outcome, :string, description: "Flow: how its test ended (none, passed, failed)")

    field(:revision, :string,
      description:
        "The revision its review and test are for (its head commit); one of another is not current"
    )

    field(:update, :string,
      description:
        "Flow: updated when a new revision arrives after changes were requested (none, updated)"
    )

    field(:integration, :string,
      description:
        "Flow: how integrating it ended, or a maintainer's retry (none, done, refused, retry)"
    )

    primary(:title)

    create(
      ask: [:url],
      id: [
        from: :url,
        pattern: "^https://github\\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([0-9]+)$",
        template: "PR-{1}-{2}-{3}",
        replace: [.: "_"],
        error: "url must be a GitHub pull request URL, e.g. https://github.com/eyra/atlas/pull/12"
      ]
    )

    connector(
      system: :github,
      address: :url,
      fields: [title: "title", state: :state, draft: "isDraft"],
      until: [state: [:merged, :closed]]
    )
  end

  relation(:in_issue,
    label: "in issue",
    description:
      "A pull request belongs to at most one issue; an issue has zero or more pull requests.",
    from: [:pull_request],
    to: [:issue],
    max_outgoing: 1,
    inverse: {:pull_requests, "pull requests"},
    parent: true
  )

  # Before Code integrates a pull request: CI is green on the exact head being
  # integrated, and the fingerprint approved at review is the one sent at integration.
  # Code applies it before it integrates (by hand until then); the pull request subflow
  # names it again once its integrate effect runs. A missing or null field is uncertain,
  # so it goes to a person.
  defgate :integrate,
    version: 1,
    flavor: :rule,
    purpose: :flow,
    evidence: [
      :ci_conclusion,
      :ci_head,
      :integration_head,
      :review_fingerprint,
      :integration_fingerprint
    ],
    rule: [
      all: [
        {:equals, :ci_conclusion, "success"},
        {:same, :ci_head, :integration_head},
        {:same, :review_fingerprint, :integration_fingerprint}
      ]
    ],
    verdicts: [:integrate, :refuse, :person],
    decide: [pass: :integrate, changes_required: :refuse, uncertain: :person, error: :person]

  subflow :pull_request, label: "Pull request", subject: :pull_request do
    run_as "system:sf-flow"
    owner default: {:agent, :coordinator}
    start :create
    initial :checking

    state :checking, label: "Review and test" do
      present(
        expected: "Review and merge it",
        why: "it is open",
        instructions: "Review the pull request; merge it, or close it."
      )

      set review_outcome: :none, test_outcome: :none, update: :none
      branch to: :closed, when: "entity.state == 'closed'"
      branch to: :integrated, when: "entity.state == 'merged'"
      await :review_outcome, changes_requested: :changes_requested
      await :test_outcome, failed: :changes_requested

      branch to: :integrating,
             by: :atlas,
             when: "entity.review_outcome == 'approved' and entity.test_outcome == 'passed'"
    end

    state :changes_requested, label: "Changes requested" do
      present(
        expected: "Make the changes asked for",
        why: "its review requested changes or its test failed",
        instructions:
          "Push a revision that makes them, set revision to its head commit and update to updated; its review and test start again."
      )

      branch to: :closed, when: "entity.state == 'closed'"
      branch to: :integrated, when: "entity.state == 'merged'"
      branch to: :checking, when: "entity.update == 'updated'"
    end

    state :integrating, label: "Integrate" do
      present(
        expected: "Merge it",
        why: "its review approved and its test passed",
        instructions: "Merge the reviewed and tested revision, or close it."
      )

      branch to: :integrated, when: "entity.state == 'merged'"
      branch to: :closed, when: "entity.state == 'closed'"
    end

    final :integrated, label: "Integrated"
    final :closed, label: "Closed", status: :cancelled
  end

  # How the runs of pull_request are selected, imported from the pull request as it was
  # before the subflow ran, and presented: on its Assignment, as the legacy flow
  # review_and_merge did, which no longer drives a pull request. The first row that holds
  # gives the entry. A final row is completed history (no entry writes, nothing rerun):
  # merged or closed, first, as the subflow's own branches come first. An open pull
  # request whose outcomes already say where it is joins that wait without anything
  # written. Any other open pull request (none of today's has an outcome: no flow wrote
  # one) matches no row and starts in `checking`, as a new one does: it enters its
  # checks, writing only their reset outcomes; nothing it had is rerun.
  select(:pull_request,
    legacy: :review_and_merge,
    choices: [],
    projection: [
      on: :assignment,
      state_field: :flow_state,
      handover_field: :handover,
      owner_relation: :assigned_to,
      field: :expected
    ],
    admission: [],
    imports: [
      [when: [state: [:merged]], state: :integrated],
      [when: [state: [:closed]], state: :closed],
      [when: [review_outcome: [:changes_requested]], state: :changes_requested],
      [when: [test_outcome: [:failed]], state: :changes_requested],
      [when: [review_outcome: [:approved], test_outcome: [:passed]], state: :integrating]
    ]
  )

  # The approved migration of its runs, from the digest the base branch recorded
  # (RelaDSL.RunIdentity); the same in prod and test. No run had that digest: the
  # subflow was never selected before slice 8. A run that did would move along it as a
  # state migration (re-entering its state), never as a re-key; one waiting in `blocked`,
  # which went with the effect, would wait for the merge by hand in `integrating`.
  migrate(:pull_request,
    from: "0d65d9a4aa1cdf916e022547e3f4a1974505cd94c349e9809f1a441f13cd8335",
    to: "e183d55ea7eb411d29dd812053dff89078b4ef131068a3223d40c22617bffbd0",
    states: [
      blocked: :integrating,
      changes_requested: :changes_requested,
      checking: :checking,
      closed: :closed,
      integrated: :integrated,
      integrating: :integrating
    ],
    reason: "Slice 8: selected without its integrate effect and creates; merged by hand"
  )
end

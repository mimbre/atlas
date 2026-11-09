defmodule Model.PullRequest do
  @moduledoc """
  The pull request subflow. It starts when State records the pull request that the
  Issue's publish effect created, and it ends when Code has integrated it or it is
  closed.

  How it reads:

    * `checking` creates a review and a test of the pull request (`pr_review`,
      `pr_test`), each with a subflow of its own. Their outcomes come back as
      `review_outcome` and `test_outcome`, written by the composition's links.
    * Approved and passed, together, lead to `integrating`: a rule Rela can express,
      so it is a branch and not a gate.
    * Changes requested or a failed test lead to `changes_requested`, until a new
      revision arrives (`update`) and the checks start again.
    * `integrating` asks Code to integrate the exact approved revision; Code applies
      the `integrate` rule gate first. A refusal or no answer goes to a maintainer.
    * Closing the pull request ends the subflow from any state that allows it.
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
  # The pull request subflow's integrate effect names it; Code applies it before it
  # integrates (by hand until then). A missing or null field is uncertain, so it goes
  # to a person.
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
      create :pr_review, properties: [title: "Review of {{subject.id}}"], relate: :review_of
      create :pr_test, properties: [title: "Test of {{subject.id}}"], relate: :test_of
      branch to: :closed, when: "entity.state == 'closed'"
      await :review_outcome, changes_requested: :changes_requested
      await :test_outcome, failed: :changes_requested

      branch to: :integrating,
             by: :atlas,
             when: "entity.review_outcome == 'approved' and entity.test_outcome == 'passed'"
    end

    state :changes_requested, label: "Changes requested" do
      branch to: :closed, when: "entity.state == 'closed'"
      branch to: :checking, by: :atlas, when: "entity.update == 'updated'"
    end

    state :integrating, label: "Integrate" do
      effect :integrate,
        service: :code,
        field: :integration,
        gate: :integrate,
        fingerprint: {:current_change, true},
        target: {:resolve, true},
        on: [done: :integrated, refused: :blocked]

      timer :no_effect, "1h", to: :blocked, label: "Code did not answer within an hour"
    end

    state :blocked, label: "Integration needs a person" do
      wait_for [:maintainer], on: :integration, reset: false, retry: :integrating
      branch to: :closed, roles: [:maintainer], when: "entity.state == 'closed'"
    end

    final :integrated, label: "Integrated"
    final :closed, label: "Closed", status: :cancelled
  end
end

defmodule AtlasFlowContract.PullRequest do
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
  use AtlasFlowGenerator.Schema, gates: AtlasFlowContract.Gates

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

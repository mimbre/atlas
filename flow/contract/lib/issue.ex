defmodule AtlasFlowContract.Issue do
  @moduledoc """
  The Issue subflow. An issue in development is built by several
  private passes and only then published as a pull request.

  How it reads:

    * `author` → `delivery_gate` → `review` → `review_gate` → `publish` → `in_pr`
      is the happy path. A gate that asks for changes sends the work to `rework`,
      which goes back through `delivery_gate`.
    * The work stays private until the review gate says `ready`; Code is involved
      only from `publish` on.
    * Anything that fails, times out or is uncertain lands in `needs_person`, where
      a maintainer chooses how to go on.
    * `in_pr` waits for the pull request subflow to report its outcome
      (`pr_outcome`, written by a composition link).

  Each `pass`, `gate` and `effect` becomes, in Rela, a reset of its result field and
  one branch per result; see `AtlasFlowGenerator.Schema`.
  """
  use AtlasFlowGenerator.Schema, gates: AtlasFlowContract.Gates

  subflow :issue, label: "Issue", subject: :issue do
    run_as "system:sf-flow"
    owner via: :assignment, relation: :assigned_to, default: {:agent, :coordinator}
    channel :work
    start :predicate, when: "entity.stage == 'development'"
    initial :author

    state :author, label: "Author pass" do
      present(
        expected: "Build it",
        why: "its pull request is not merged",
        instructions:
          "Build it in one pull request and get that merged; link the pull request to it."
      )

      pass :developer,
        mode: :author,
        folder: {:materialize, :target},
        permissions: :materialized_folder,
        freeze: :packet,
        on: [delivered: :delivery_gate, failed: :needs_person]

      timer :runtime_wait, "2d",
        to: :needs_person,
        label: "The owner's Runtime did not finish the pass"
    end

    state :delivery_gate, label: "Delivery-evidence gate" do
      gate :delivery_evidence, review: :review, rework: :rework, person: :needs_person
      timer :no_decision, "1h", to: :needs_person, label: "No gate decision within an hour"
    end

    state :review, label: "Review pass" do
      pass :developer,
        mode: :review,
        folder: {:packet, :last},
        permissions: :review_packet,
        diversity: :other_vendor,
        findings: :required,
        on: [delivered: :review_gate, failed: :needs_person]

      timer :runtime_wait, "2d",
        to: :needs_person,
        label: "The owner's Runtime did not finish the review"
    end

    state :review_gate, label: "Review gate" do
      gate :review, ready: :publish, rework: :rework, person: :needs_person
      timer :no_decision, "1h", to: :needs_person, label: "No gate decision within an hour"
    end

    state :rework, label: "Rework pass" do
      pass :developer,
        mode: :rework,
        folder: {:continue, :author},
        permissions: :materialized_folder,
        input: {:channel, :newest_since_last_pass},
        freeze: :packet,
        on: [delivered: :delivery_gate, failed: :needs_person]

      timer :runtime_wait, "2d",
        to: :needs_person,
        label: "The owner's Runtime did not finish the rework"
    end

    state :publish, label: "Create or update the PR" do
      effect :publish_review,
        service: :code,
        fingerprint: {:approved_by, :review_gate},
        submit: {:from, :packet},
        records: {:pull_request, :in_issue},
        also: [pr_outcome: :open],
        on: [done: :in_pr, refused: :needs_person]

      timer :no_effect, "1h", to: :needs_person, label: "Code did not answer within an hour"
    end

    state :in_pr, label: "In pull request" do
      await :pr_outcome, changes_requested: :rework, integrated: :done, closed: :closed
    end

    state :needs_person, label: "A person decides" do
      wait_for [:maintainer],
        on: :gate_result,
        review: :review,
        rework: :rework,
        ready: :publish,
        close: :closed
    end

    final :done, label: "Integrated"
    final :closed, label: "Closed", status: :cancelled
  end
end

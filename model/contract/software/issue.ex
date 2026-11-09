defmodule Model.Issue do
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
  one branch per result; see `RelaDSL.Schema`.
  """
  use RelaDSL

  type(:issue_stage,
    values: [:specification, :design, :development],
    labels: [specification: "Specification", design: "Design", development: "Development"]
  )

  entity :issue,
    label: "Issue",
    plural: "issues",
    aliases: ["is"],
    id_type: :manual,
    id_prefix: "IS-",
    description: """
    Small, independently testable work, normally one pull request (Flux's
    meaning). The id is its Atlas code, e.g. IS-Atlas-01.
    """ do
    field(:title, :string, required: true, description: "Without the code (Flux: name)")
    field(:description, :string, description: "The text (Flux: description)", multiline: true)

    field(:flux_id, :string,
      unique: true,
      description: "Flux (Basecamp) id, set by a later Flux sync",
      set_by: :connector
    )

    field(:stage, :issue_stage, description: "Flux: stage")

    field(:flux_ref, :string,
      unique: true,
      description: "Flux's own issue code (ref), e.g. NEXT-240, set by a later Flux sync",
      set_by: :connector
    )

    field(:pass_result, :string,
      description: "Flow: how the last pass ended (none, delivered, failed)"
    )

    field(:gate_result, :string,
      description:
        "Flow: the last gate verdict, or a maintainer's choice (none, review, rework, ready, person, close)"
    )

    field(:effect_result, :string,
      description: "Flow: how publishing the pull request ended (none, done, refused)"
    )

    field(:pr_outcome, :string,
      description:
        "Flow: where its pull request is (none, open, changes_requested, integrated, closed)"
    )

    create(ask: [:title, :description])
  end

  # After an author or rework pass: is the evidence good enough to review?
  defgate :delivery_evidence,
    version: 1,
    flavor: :smart,
    purpose: :flow,
    advice: :jev,
    evidence: [:assignment, :turn, :packet, :tests, :limits],
    verdicts: [:review, :rework, :person],
    decide: [pass: :review, changes_required: :rework, uncertain: :person, error: :person],
    policy: [max_rounds: 3, execution_failed: :person]

  # After the review pass: is the work ready to publish as a pull request?
  defgate :review,
    version: 1,
    flavor: :smart,
    purpose: :flow,
    advice: {:review_pass, :review},
    evidence: [:packet, :findings, :guidelines, :guardrails],
    verdicts: [:ready, :rework, :person],
    decide: [pass: :ready, changes_required: :rework, uncertain: :person, error: :person],
    policy: [max_rounds: 3, binds: :fingerprint]

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

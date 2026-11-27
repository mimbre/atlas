defmodule Model.Issue do
  @moduledoc """
  The issue kind, its gates and selection. Model.Delivery declares
  its `issue` subflow: an agent builds it on its supervisor's Runtime, a second agent
  reviews it, one fix follows changes required, Code opens its pull request (`pr_url`),
  its CI is waited for (`pr_checks` and `pr_checks_failure`, as rela's GitHub sync writes
  them for the head `pr_checks_head`, which must be the head Code pushed, `pr_head`; red is
  fixed at most twice, `ci_fixes`), a conflict with develop is updated once
  (`pr_mergeable`, as the sync writes it; `pr_updates`), and its supervisor merges it;
  merged (`pr_state`, as the GitHub connector copies it) is done. Closed in Atlas,
  rela's GitHub sync closes its open pull request (`pr_close_failure` when GitHub
  refused). A pull it leaves behind (its `pr_url` replaced by a Retry past publishing, or
  the issue removed in Atlas) is closed only as recorded: a pull request fact with a
  `close_reason` (IS-Atlas-130, IS-Atlas-133), never by its branch name.

  `pass_result`, `gate_result`, `effect_result` and `pr_outcome` stay on the kind with
  what earlier flows wrote; no flow writes them now. The gates stay defined, for when
  smart gates judge a review's findings.
  """
  use RelaDSL

  type(:issue_stage,
    values: [:specification, :design, :development],
    labels: [specification: "Specification", design: "Design", development: "Development"]
  )

  type(:pull_request_checks,
    values: [:pending, :success, :failure],
    labels: [pending: "Running", success: "Passed", failure: "Failed"]
  )

  type(:pull_request_mergeable,
    values: [:unknown, :clean, :behind, :conflicting],
    labels: [
      unknown: "Not known yet",
      clean: "Mergeable",
      behind: "Behind its base",
      conflicting: "Conflicts"
    ]
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
    icon(:ticket)
    field(:title, :string, required: true, description: "Without the code (Flux: name)")
    field(:description, :string, description: "The text (Flux: description)", multiline: true)

    field(:flux_id, :string,
      unique: true,
      description: "Flux (Basecamp) id, set by a later Flux sync",
      set_by: :connector
    )

    field(:stage, :issue_stage, description: "Flux: stage")

    field(:order, :integer,
      description:
        "Where it is built among the numbered issues of its use case, lowest first. Plan numbers the issues it proposes; change it to reorder. One without a number never waits and is never waited for",
      label: "Order"
    )

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
        "Flow: the last gate verdict, or a maintainer's choice (none, review, rework, ready, person, close, retry, publish, rebuild)"
    )

    field(:effect_result, :string,
      description: "Flow: how publishing the pull request ended (none, done, refused)"
    )

    field(:pr_outcome, :string,
      description:
        "Flow: where its pull request is (none, open, changes_requested, integrated, closed)"
    )

    # What its subflow's task branch reads: the run's own result, never written.
    field(:task_result, :string,
      description:
        "Flow: how its agent task ended (completed, check_failed, stuck, abandoned); the run's own, never written",
      set_by: [:flow],
      label: "Task result"
    )

    field(:publication, :string,
      description: "Flow: how opening its pull request ended (done, no_changes, refused)",
      set_by: [:flow],
      label: "Publication"
    )

    field(:pr_url, :github_pull_url,
      description:
        "Flow: the pull request Code opened from its result, which its supervisor merges",
      set_by: [:flow],
      label: "Pull request"
    )

    field(:pr_state, :pull_request_state,
      description: "GitHub: its pull request's state",
      set_by: :connector,
      label: "Pull request state"
    )

    field(:pr_checks, :pull_request_checks,
      description: "GitHub: the combined check status of its pull request's head",
      set_by: :connector,
      label: "CI"
    )

    # The CI gate's tie (IS-Atlas-120, IS-Atlas-122): the head its status was read for and
    # the head Code pushed; its branches act only when the two agree, so a status of an
    # earlier head is never taken for the current one.
    field(:pr_checks_head, :string,
      description:
        "GitHub: the head commit of its pull request that its CI (pr_checks) and mergeability (pr_mergeable) were read for",
      set_by: :connector,
      label: "CI head"
    )

    field(:pr_head, :string,
      description:
        "Flow: the head commit Code last pushed to its pull request (publish, CI fix, update), the one its CI gate waits for; rela's GitHub sync takes the pull's head when none is recorded or someone else pushed onto it",
      set_by: [:flow, :connector],
      label: "Head"
    )

    field(:pr_checks_failure, :string,
      description:
        "GitHub: its pull request's failing checks, with the failing lines of their logs",
      set_by: :connector,
      multiline: true,
      label: "CI failure"
    )

    # The CI gate's count: its run sets it entering each fix of its failing CI, so the
    # third red goes to its supervisor.
    field(:ci_fixes, :string,
      description:
        "Flow: how many fixes of its pull request's failing CI its run made (none, one, two)",
      set_by: [:flow],
      label: "CI fixes"
    )

    # Set reaching Merge it, so CI turning red after that is fixed saying so; publishing
    # (a new pull request) clears it.
    field(:ci_green, :string,
      description:
        "Flow: whether its pull request reached Merge it green and mergeable in this build (none, yes)",
      set_by: [:flow],
      label: "Was green"
    )

    field(:ci_push, :string,
      description:
        "Flow: how pushing a fix of its failing CI onto its pull request ended (done, no_changes, refused)",
      set_by: [:flow],
      label: "CI fix push"
    )

    field(:pr_mergeable, :pull_request_mergeable,
      description:
        "GitHub: whether its pull request merges into its base (mergeable, mergeable_state)",
      set_by: :connector,
      label: "Mergeable"
    )

    # The update's count: its run sets it entering the update of a conflict with develop,
    # so a conflict after it goes to its supervisor; reaching Merge it resets it.
    field(:pr_updates, :string,
      description:
        "Flow: how many updates with develop its run made since its pull request was last mergeable (none, one)",
      set_by: [:flow],
      label: "Updates"
    )

    field(:pr_update, :string,
      description:
        "Flow: how pushing its update with develop onto its pull request ended (done, no_changes, refused)",
      set_by: [:flow],
      label: "Update push"
    )

    # Its run, when an agent task ended without a result (IS-Atlas-60): the step Retry
    # goes back to, which each task state sets as it is entered, and what Flow wrote of
    # how that task ended.
    field(:retry_step, :string,
      description:
        "Flow: the step its run's last agent task ran as, which Retry goes back to (author, review, fix, ci_fix, ci_fix_again)",
      set_by: [:flow],
      label: "Retry step"
    )

    field(:task_failure, :string,
      description:
        "Flow: which of its agent tasks ended without a result (stuck or abandoned), in which state, and why; none while its last task ran",
      set_by: [:flow],
      multiline: true,
      label: "Task failure"
    )

    field(:pr_close_failure, :string,
      description:
        "GitHub: why closing its open pull request failed after it was closed in Atlas",
      set_by: :connector,
      label: "Pull request close failure"
    )

    connector(
      system: :github,
      address: :pr_url,
      fields: [pr_state: :state],
      until: [pr_state: [:merged, :closed]]
    )

    create(ask: [:title, :description])

    # Where its supervisor decides, as panels (Model.Delivery's states): Merge it, with
    # what Atlas records of its pull request and its latest review; and work that ended
    # without a result, with what went wrong and what can be done.
    panel(
      merging: [
        heading: "TO MERGE",
        title: "\#{pr_url|number} {title}",
        detail_groups: [
          [title: "Issue", fields: [:description, :stage, :order, :flux_ref, :flux_id]],
          [
            title: "Pull request",
            fields: [
              :pr_url,
              :pr_state,
              :pr_outcome,
              :pr_mergeable,
              :pr_head,
              :pr_checks,
              :pr_checks_head,
              :pr_checks_failure
            ]
          ],
          [
            title: "Build and checks",
            fields: [
              :pass_result,
              :gate_result,
              :effect_result,
              :task_result,
              :publication,
              :ci_fixes,
              :ci_green,
              :ci_push,
              :pr_updates,
              :pr_update,
              :retry_step,
              :task_failure,
              :pr_close_failure
            ]
          ]
        ],
        records: [
          review: [relation: :task_of, where: [kind: :review]],
          author: [relation: :task_of, where: [kind: :author]]
        ],
        byline: ["{key}", "{in_use_case}", "by {author}", [age: "waiting"]],
        checks: [
          [
            label: "CI",
            text: "{pr_checks}",
            state: [
              field: :pr_checks,
              success: [:success],
              error: [:failure],
              pending: [:pending]
            ]
          ],
          [
            label: "Review",
            text: "{review.verdict} · {review.answer|line}",
            state: [
              field: "review.verdict",
              success: [:approved],
              error: [:changes_required]
            ]
          ],
          [
            label: "GitHub",
            text: "{pr_state} · {pr_mergeable}",
            state: [
              field: :pr_mergeable,
              success: [:clean],
              error: [:conflicting],
              pending: [:behind, :unknown]
            ]
          ]
        ],
        links: [[key: "o", label: "Open on GitHub", field: :pr_url]],
        actions: [
          [
            key: "r",
            label: "Full review",
            help: "Open the review of its pull request",
            record: :review
          ]
        ]
      ],
      stuck: [
        heading: "YOUR DECISION",
        title: "{key} is stuck: what now?",
        records: [last: [relation: :task_of]],
        byline: ["{last.kind}", "attempt {last.attempt} failed", [age: "stuck"]],
        box: [title: "What went wrong", field: :task_failure, tone: :error, empty: ["none"]],
        choose: true,
        details: [
          r: "Runs that step again with a fresh task.",
          c: "Ends it; nothing more is built for it."
        ],
        actions: [
          [
            key: "l",
            label: "Agent's log",
            help: "Open the task whose attempt failed",
            record: :last
          ]
        ]
      ],
      review_stuck: [
        heading: "YOUR DECISION",
        title: "{key} is stuck: what now?",
        records: [last: [relation: :task_of]],
        byline: ["{last.kind}", "attempt {last.attempt} failed", [age: "stuck"]],
        box: [title: "What went wrong", field: :task_failure, tone: :error, empty: ["none"]],
        choose: true,
        details: [
          r: "Runs a fresh review of its author's result.",
          p: "Code opens its pull request without a review; its body says so.",
          c: "Ends it; nothing more is built for it."
        ],
        actions: [
          [
            key: "l",
            label: "Agent's log",
            help: "Open the task whose attempt failed",
            record: :last
          ]
        ]
      ]
    )
  end

  # After an author or rework pass: is the evidence good enough to review? Named by no
  # state while the passes wait (slice 9); Gates has no evaluator for a smart gate yet.
  defgate(:delivery_evidence,
    version: 1,
    flavor: :smart,
    purpose: :flow,
    advice: :jev,
    evidence: [:assignment, :turn, :packet, :tests, :limits],
    verdicts: [:review, :rework, :person],
    decide: [pass: :review, changes_required: :rework, uncertain: :person, error: :person],
    policy: [max_rounds: 3, execution_failed: :person]
  )

  # After the review pass: is the work ready to publish as a pull request? Named by no
  # state while the review pass waits (slice 9).
  defgate(:review,
    version: 1,
    flavor: :smart,
    purpose: :flow,
    advice: {:review_pass, :review},
    evidence: [:packet, :findings, :guidelines, :guardrails],
    verdicts: [:ready, :rework, :person],
    decide: [pass: :ready, changes_required: :rework, uncertain: :person, error: :person],
    policy: [max_rounds: 3, binds: :fingerprint]
  )

  # How the runs of issue are selected, imported from the issue as it was before the
  # subflow ran, and presented: on its Assignment. The first row that holds gives the
  # entry. An issue whose pull request already reported its merge is completed history
  # (no entry writes, nothing rerun). Any other issue matches no row and starts in
  # `working`, as a new one does, writing only its retry step and that no task failed:
  # what it showed and its owner stay.
  # The numbered issues of one use case are built in order (`order`, IS-Atlas-114): only
  # the first not finished (completed, or its run ended `done`) can be picked up; the other
  # numbered ones wait for it. An issue without a number never waits.
  # An issue completed meanwhile (`completed`, IS-Atlas-34): its change merged elsewhere,
  # a merged pull request linked to it by hand (`in_issue`) or that also did it
  # (`done_in`), as its composition's completion says; its run goes to `done` from any open
  # state, the task it held cancelled. A push Code was asked for is answered first.
  select(:issue,
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
      [when: [pr_outcome: [:integrated]], state: :done]
    ],
    order: [within: :in_use_case, by: :order, done: [:done]],
    completed: :done
  )
end

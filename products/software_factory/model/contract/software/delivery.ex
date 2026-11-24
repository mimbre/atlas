defmodule Model.Delivery do
  @moduledoc """
  Building an issue: its subflow `issue`, **Build** (Issue → Pull request), on the kind
  Model.Issue holds with its gates, selection and migration policy.

  A person picks an issue up in the Console and becomes its human supervisor; handed to
  a machinery, it runs one agent task on that supervisor's Runtime (`working`). When the
  task ends, a second agent reviews its result there (`reviewing`): a Git checkout of it,
  judged against the issue, ending with a verdict, its blocking findings and its
  follow-ups. Follow-ups are what it finds outside the issue's scope (a nice-to-have,
  hardening, an edge case, a neighbouring improvement): Flow makes each a new issue under
  the issue's use case for its supervisor (`follow_ups:`), whatever the verdict, and they
  are not fixed now. When the review asks for
  changes, one fix task works on that result with its findings (`fixing`); its result,
  on the author's, is what Code publishes. Then Code opens a pull request from the
  latest result, the review and the fix in its body (the effect `publish`,
  `AtlasCode.Effects`), and the issue waits for its CI (`checking`): rela's GitHub sync
  writes the pull's check status (`pr_checks`) and what failed (`pr_checks_failure`).
  Passed, it waits for its supervisor to merge it on GitHub (`merging`): the GitHub
  connector copies the pull's state, and merged is done. Failed, a fix task works on the
  latest result with what failed (`ci_fixing`, its `findings:` that field), and Code
  pushes its result onto the same pull request (`ci_pushing`, `onto: :pr_url`), whose CI
  is waited for again; at most two such fixes (`ci_fixes`), then its supervisor decides
  (`ci_failing`). A result without changes against develop opens no pull request: Code
  refuses it (`no_changes`) and the issue goes to its supervisor (`unchanged`). No second
  review; its supervisor decides. No package.

  Every task reads the issue's title and description, and those of its use case and its
  scene (`parents:`): why it is to be done.

  The span `build` holds until the pull request is merged; the runs of its packages
  (`package`, under it through `package_of`) and of pull requests linked to it
  (`pull_request`, through `in_issue`) belong to it: a person item of theirs goes to its
  supervisor (rule S3).
  """
  use RelaDSL

  relation(:done_in,
    label: "also done in",
    description: "A merged pull request of another issue that also did this one.",
    from: [:issue],
    to: [:pull_request],
    inverse: {:also_done, "also done"},
    set_by: [:migration, :connector]
  )

  # Build: Issue → Pull request.
  subflow :issue, label: "Build", subject: :issue do
    run_as "system:sf-flow"

    owner via: :assignment,
          relation: :assigned_to,
          default: {:agent, :coordinator},
          preserve_kind: [:agent, :person, :machinery]

    channel :work
    start :create
    initial :working
    # Its pull request is its supervisor's to merge: the span holds until it is merged.
    supervise :build,
      label: "Build",
      states: [
        :working,
        :reviewing,
        :fixing,
        :publishing,
        :checking,
        :ci_fixing,
        :ci_fixing_again,
        :ci_pushing,
        :ci_failing,
        :merging,
        :unchanged
      ],
      with: [:package, :pull_request]

    state :working, label: "Working" do
      present(
        expected: "Build it",
        why: "it is not built",
        instructions:
          "Its machinery runs one agent on it, on a fresh base of develop. Nothing is done while it is not assigned to a machinery."
      )

      task(:author,
        role: :developer,
        profile: :deep_coding,
        cost_class: :standard,
        input: [repository: "github.com/mimbre/atlas", base: "develop"],
        instructions:
          "Build the issue below in the repository you are given, a Git checkout of its base. Its use case and scene, after it, say why it is to be done. End your answer with what you did and what is left open.",
        fields: [:title, :description],
        parents: [:title, :description],
        records: [kind: "task", relation: "task_of"],
        machinery: "machinery",
        on: [
          completed: :reviewing,
          check_failed: :reviewing,
          stuck: :stuck,
          abandoned: :stuck
        ]
      )
    end

    # A second agent judges the author's result: a Git checkout of it (the result commit on
    # its base, and on top the base's dependencies), which Code serves like a branch. What it
    # changes is never read. Its verdict and findings go with the result to its pull request;
    # a verdict of changes required ends it `changes_required`, which leads to one fix.
    state :reviewing, label: "Reviewing" do
      present(
        expected: "Review it on the machinery",
        why: "its agent's work is done",
        instructions:
          "Its machinery runs a second agent on its result, which judges whether it does what the issue asks. Nothing is done while it is not assigned to a machinery."
      )

      task(:review,
        role: :developer,
        profile: :independent_review,
        cost_class: :standard,
        input: [repository: "github.com/mimbre/atlas", result: :latest],
        instructions:
          "Review the result of the issue below in the repository you are given: a Git checkout of it. Its last commit only adds the base's dependencies; the change to review is the commit under it (git show HEAD~1). Judge whether it does what the issue asks, and nothing else; its use case and scene, after it, say why. You may run bin/check. Change nothing: what you change is thrown away.",
        fields: [:title, :description],
        parents: [:title, :description],
        follow_ups: :issue,
        records: [kind: "task", relation: "task_of"],
        machinery: "machinery",
        on: [
          completed: :publishing,
          check_failed: :publishing,
          changes_required: :fixing,
          stuck: :stuck,
          abandoned: :stuck
        ]
      )
    end

    # One fix of the review's findings, on the author's result as its base (as the review
    # gets it): its result commit sits on the author's, so the pull request has both. No
    # second review follows.
    state :fixing, label: "Fixing" do
      present(
        expected: "Fix it on the machinery",
        why: "its review asks for changes",
        instructions:
          "Its machinery runs an agent on its result with the review's findings; its fix is what Code then opens a pull request from. Nothing is done while it is not assigned to a machinery."
      )

      task(:fix,
        role: :developer,
        profile: :deep_coding,
        cost_class: :standard,
        input: [repository: "github.com/mimbre/atlas", result: :latest],
        instructions:
          "Fix the result of the issue below in the repository you are given: a Git checkout of it. Its last commit only adds the base's dependencies; the issue's change so far is the commit under it (git show HEAD~1). Do what the review's findings below ask, within the issue, and run bin/check. End your answer with what you fixed and what is left open.",
        fields: [:title, :description],
        parents: [:title, :description],
        records: [kind: "task", relation: "task_of"],
        machinery: "machinery",
        on: [
          completed: :publishing,
          check_failed: :publishing,
          stuck: :stuck,
          abandoned: :stuck
        ]
      )
    end

    # Code pushes the task's result to a branch and opens a pull request from it onto the
    # base; Flow names the result by its ref only. Its CI is waited for (`checking`) before
    # anyone is asked to merge it.
    state :publishing, label: "Opening its pull request" do
      set ci_fixes: :none

      present(
        expected: "Let Code open its pull request",
        why: "its agent's work is done",
        instructions:
          "Code pushes its result to a branch on GitHub and opens a pull request from it onto develop; nothing is asked of anyone meanwhile."
      )

      effect(:publish,
        contract: 1,
        name: "publish",
        service: "code",
        operation: "publish",
        field: :publication,
        fingerprint: [fields: ["title"], relations: []],
        payload: ["title", "description"],
        input: [repository: "github.com/mimbre/atlas", base: "develop"],
        outputs: [url: "pr_url"],
        on: [done: :checking, no_changes: :unchanged, refused: :stuck]
      )
    end

    # The CI gate: rela's GitHub sync writes its pull request's check status (`pr_checks`)
    # and, when it failed, what failed (`pr_checks_failure`). Entering it sets the status
    # running, so a status of the head before the last push is never taken for this one.
    # Red leads to a fix of what failed, pushed onto the same pull request, at most twice
    # (`ci_fixes`); still red, its supervisor decides. Merged meanwhile is done.
    state :checking, label: "Waiting for CI" do
      set pr_checks: :pending

      present(
        expected: "Wait for its CI",
        why: "its pull request is open",
        instructions:
          "GitHub runs the checks of its pull request; nothing is asked of anyone meanwhile. Passed, its supervisor merges it; failed, an agent fixes what failed on its machinery, at most twice."
      )

      branch to: :done, when: "entity.pr_state == 'merged'"
      branch to: :merging, when: "entity.pr_checks == 'success'"

      branch to: :ci_failing,
             when: "entity.pr_checks == 'failure' and entity.ci_fixes == 'two'"

      branch to: :ci_fixing_again,
             when: "entity.pr_checks == 'failure' and entity.ci_fixes == 'one'"

      branch to: :ci_fixing, when: "entity.pr_checks == 'failure'"
    end

    # A fix of its failing CI, on its latest result (as the review's fix): what failed, the
    # failing checks with the failing lines of their logs, is what it fixes.
    state :ci_fixing, label: "Fixing its CI" do
      set ci_fixes: :one

      present(
        expected: "Fix its CI on the machinery",
        why: "the CI of its pull request failed",
        instructions:
          "Its machinery runs an agent on its result with what failed in its CI; Code then pushes its fix onto its pull request. Nothing is done while it is not assigned to a machinery."
      )

      task(:fix,
        role: :developer,
        profile: :deep_coding,
        cost_class: :standard,
        input: [repository: "github.com/mimbre/atlas", result: :latest],
        findings: :pr_checks_failure,
        instructions:
          "Fix the failing CI of the result of the issue below in the repository you are given: a Git checkout of it. Its last commit only adds the base's dependencies; the issue's change so far is the commit under it (git show HEAD~1). What failed, below, names the failing checks with the failing lines of their logs. Make them pass, within the issue, and run bin/check. End your answer with what you fixed and what is left open.",
        fields: [:title, :description],
        parents: [:title, :description],
        records: [kind: "task", relation: "task_of"],
        machinery: "machinery",
        on: [
          completed: :ci_pushing,
          check_failed: :ci_pushing,
          stuck: :stuck,
          abandoned: :stuck
        ]
      )
    end

    # The second and last fix of its failing CI.
    state :ci_fixing_again, label: "Fixing its CI again" do
      set ci_fixes: :two

      present(
        expected: "Fix its CI on the machinery",
        why: "the CI of its pull request failed after its fix",
        instructions:
          "Its machinery runs an agent on its result with what failed in its CI, the last time; Code then pushes its fix onto its pull request. Nothing is done while it is not assigned to a machinery."
      )

      task(:fix,
        role: :developer,
        profile: :deep_coding,
        cost_class: :standard,
        input: [repository: "github.com/mimbre/atlas", result: :latest],
        findings: :pr_checks_failure,
        instructions:
          "Fix the failing CI of the result of the issue below in the repository you are given: a Git checkout of it. Its last commit only adds the base's dependencies; the issue's change so far is the commit under it (git show HEAD~1). What failed, below, names the failing checks with the failing lines of their logs. Make them pass, within the issue, and run bin/check. End your answer with what you fixed and what is left open.",
        fields: [:title, :description],
        parents: [:title, :description],
        records: [kind: "task", relation: "task_of"],
        machinery: "machinery",
        on: [
          completed: :ci_pushing,
          check_failed: :ci_pushing,
          stuck: :stuck,
          abandoned: :stuck
        ]
      )
    end

    # Code pushes the CI fix's result, on top of the published one, to the branch of its
    # pull request (`onto: :pr_url`): the same pull request, whose CI is waited for again.
    state :ci_pushing, label: "Pushing its CI fix" do
      present(
        expected: "Let Code push its CI fix",
        why: "its CI fix is done",
        instructions:
          "Code pushes the fix onto the branch of its pull request on GitHub; nothing is asked of anyone meanwhile."
      )

      effect(:push,
        contract: 1,
        name: "push",
        service: "code",
        operation: "publish",
        field: :ci_push,
        fingerprint: [fields: ["title"], relations: []],
        payload: ["title", "description"],
        input: [repository: "github.com/mimbre/atlas", base: "develop", onto: :pr_url],
        on: [done: :checking, no_changes: :ci_failing, refused: :stuck]
      )
    end

    # Its CI still fails after two fixes: its supervisor decides, with what failed in front
    # of them. They fix it by hand (passed is merging) or close it; merged is done.
    state :ci_failing, label: "CI still fails" do
      owner via: :assignment, relation: :assigned_to, default: {:person, config: :decider}
      set gate_result: :none

      present(
        expected: "Decide what to do with it",
        why: "the CI of its pull request still fails after two fixes",
        instructions:
          "Its agents could not make its CI pass. Fix its pull request by hand (once its CI passes it is yours to merge), or close it.",
        section: [field: :pr_checks_failure, label: "What fails"],
        answers: [[key: "c", label: "Close it", change: %{values: %{gate_result: :close}}]]
      )

      branch to: :done, when: "entity.gate_result == 'close'"
      branch to: :done, when: "entity.pr_state == 'merged'"
      branch to: :merging, when: "entity.pr_checks == 'success'"
    end

    state :merging, label: "Merge it" do
      owner via: :assignment, relation: :assigned_to, default: {:person, config: :decider}

      present(
        expected: "Review and merge its pull request",
        why: "its agent's work is done",
        instructions:
          "Its CI passed. Open its pull request, read its review's verdict and findings and its fix's answer in its body, and merge it on GitHub; the issue is done once GitHub says it is merged."
      )

      branch to: :done, when: "entity.pr_state == 'merged'"
    end

    # Its agent changed nothing (author's and fix's result alike): Code opened no pull
    # request, and its supervisor is told. They close it (a maintainer's choice,
    # `gate_result: close`) when nothing was to change.
    state :unchanged, label: "Nothing to merge" do
      owner via: :assignment, relation: :assigned_to, default: {:person, config: :decider}
      set gate_result: :none

      present(
        expected: "Decide what to do with it",
        why: "its agent changed nothing",
        instructions:
          "Its result has no changes against develop, so Code opened no pull request. Close it when nothing was to change.",
        answers: [[key: "c", label: "Close it", change: %{values: %{gate_result: :close}}]]
      )

      branch to: :done, when: "entity.gate_result == 'close'"
    end

    final :done, label: "Done"
    final :stuck, label: "Stuck"
  end

  # "Issue → Pull request": its label is its signature; nothing else changed.
  migrate(:issue,
    from: "21b257b9472016e18cd842eada87213987ad5d4ac564b63b0761efdf79213a20",
    to: "7442292b63a8bdf89d67dc5863804cff9cc62985d3fa2c005d8bb510e7642182",
    states: :same,
    reason: "Issue → Pull request: its label is its signature"
  )

  # Build: its label was its signature, Issue → Pull request; nothing else changed.
  migrate(:issue,
    from: "7442292b63a8bdf89d67dc5863804cff9cc62985d3fa2c005d8bb510e7642182",
    to: "1670f0b0f0cb57280933c8ec0f768d622bee040c924caa56c75ac30df5da908f",
    states: :same,
    reason: "Build: renamed from Issue → Pull request"
  )

  # The CI gate (IS-Atlas-115): its pull request's CI is waited for before its supervisor
  # is asked to merge it, and red leads to at most two fixes pushed onto it. States are
  # added, none renamed or removed, so a live run keeps its state, entry, task and timers;
  # one in `merging` already is asked to merge without a CI gate.
  migrate(:issue,
    from: "1670f0b0f0cb57280933c8ec0f768d622bee040c924caa56c75ac30df5da908f",
    to: "d27ffdee4e94542a80dfb17e8b45d64a2e139f4265baa46c849b8e3c727bb7a3",
    preserve_entry: true,
    states: [
      done: :done,
      fixing: :fixing,
      merging: :merging,
      publishing: :publishing,
      reviewing: :reviewing,
      stuck: :stuck,
      unchanged: :unchanged,
      working: :working
    ],
    reason: "The CI gate: CI is waited for before the merge, and red is fixed at most twice"
  )
end

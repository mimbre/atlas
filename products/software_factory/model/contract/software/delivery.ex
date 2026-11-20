defmodule Model.Delivery do
  @moduledoc """
  Building an issue: its subflow `issue`, on the kind Model.Issue holds with its gates,
  selection and migration policy.

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
  `AtlasCode.Effects`), and the issue waits for its supervisor to merge it on GitHub:
  the GitHub connector copies the pull's state, and merged is done. A result without
  changes against develop opens no pull request: Code refuses it (`no_changes`) and the
  issue goes to its supervisor (`unchanged`). No second review and no second fix; its
  supervisor decides. No package or check.

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

  subflow :issue, label: "Issue", subject: :issue do
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
      states: [:working, :reviewing, :fixing, :publishing, :merging, :unchanged],
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
    # base; Flow names the result by its ref only. It presents what happens meanwhile, so
    # the step to `merging` is a move (`AtlasFlow.Runs.Projection`): its owner, the
    # supervisor, takes the issue from the machinery someone handed it to.
    state :publishing, label: "Opening its pull request" do
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
        on: [done: :merging, no_changes: :unchanged, refused: :stuck]
      )
    end

    state :merging, label: "Merge it" do
      owner via: :assignment, relation: :assigned_to, default: {:person, config: :decider}

      present(
        expected: "Review and merge its pull request",
        why: "its agent's work is done",
        instructions:
          "Open its pull request, read its review's verdict and findings and its fix's answer in its body, and merge it on GitHub; the issue is done once GitHub says it is merged."
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
end

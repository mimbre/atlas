defmodule Model.Delivery do
  @moduledoc """
  Building an issue: its subflow `issue`, **Build** (Issue → Pull request), on the kind
  Model.Issue holds with its gates and selection.

  A person picks an issue up in the Console and becomes its human supervisor; that pickup
  alone starts its work: one agent task on that supervisor's Runtime (`working`). When the
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
  writes the pull's check status (`pr_checks`), what failed (`pr_checks_failure`) and
  whether it merges into develop (`pr_mergeable`). Passed and mergeable, it waits for its
  supervisor to merge it on GitHub (`merging`): the GitHub connector copies the pull's
  state, and merged is done. Its supervisor gets it only while it is mergeable and green:
  conflicting or not green meanwhile takes it back to `checking`. Failed, a fix task
  works on the latest result with what failed (`ci_fixing`, its `findings:` that field),
  and Code pushes its result onto the same pull request (`ci_pushing`, `onto: :pr_url`),
  whose CI is waited for again; at most two such fixes (`ci_fixes`), then its supervisor
  decides (`ci_failing`). Conflicting with develop, an update task resolves develop merged
  into its pull request (`updating`, its base `update: :pr_url`) and Code pushes it onto
  the same pull request (`update_pushing`); one update per conflict (`pr_updates`), then
  its supervisor decides (`update_failing`). A result without changes against develop
  opens no pull request: Code refuses it (`no_changes`) and the issue goes to its
  supervisor (`unchanged`), who closes it or builds it again (a fresh author on a fresh
  base of develop). A result Code cannot tell has changes is refused too, and goes to its
  supervisor with Retry (`stuck`); never an empty pull request. No second review; its
  supervisor decides. No package.

  No item gets stuck (IS-Atlas-60, IS-Atlas-18): an agent task that ends without a result
  (`stuck` or `abandoned`), or Code refusing its pull request, keeps the issue in its span
  with its supervisor (`stuck`), with why: Flow writes which task ended how, and its
  reason (`task_failure`, the task's `failure:`). Each task state records its step as it is
  entered (`retry_step`, as the package subflow's held state reads it), so Retry goes back
  to that state for a fresh task: the author on a fresh base of develop, any other on the
  latest result that has one. A review that ends so leaves its author's result complete in
  Code (`review_stuck`): its supervisor may also publish it without a review, its pull
  request's body saying no review was made. Either may be closed (`done`).

  A silent turn is ended (UC-Atlas-03): in every task state, a task whose lease runs out
  unrenewed (its agent, or its Runtime, went silent), or that crashes with no answer and
  no result, is an empty turn. The first starts the same task once more on its own, on a
  fresh attempt, with nobody asked; the second in a row ends it `abandoned`, which goes
  to that state's supervisor state with why ("its agent went silent twice") and Retry.
  Flow keeps that count in the run, by the package ladder's rule (`AtlasFlow.Ladder`).
  Work interrupted by an update, a Runtime stop or crash, or a restart of its machine is
  no empty turn: it runs again by itself from the step it was in, as often as it happens.

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
        :updating,
        :update_pushing,
        :update_failing,
        :merging,
        :unchanged,
        :stuck,
        :review_stuck
      ],
      with: [:package, :pull_request]

    state :working, label: "Working" do
      set retry_step: :author, task_failure: :none

      present(
        expected: "Build it",
        why: "it is not built",
        instructions:
          "Its supervisor's Runtime runs one agent on it, on a fresh base of develop. Its supervisor's pickup starts the work: nothing is done until then."
      )

      task(:author,
        role: :developer,
        profile: :deep_coding,
        cost_class: :standard,
        input: [repository: "github.com/mimbre/atlas", base: "develop"],
        instructions:
          "Build the issue below in the repository you are given, a Git checkout of its base. Its use case and scene, after it, say why it is to be done. Before you build anything that stores, syncs, schedules or queries data, ask rela what it offers and use that (D-0100): Atlas builds nothing beside rela, and what rela lacks is a request to the rela project, not a workaround in Atlas. Ask the pinned rela itself (docs/guides/rela.md): rela --help, rela <command> --help, or its MCP server, rela mcp. End your answer with what you did and what is left open.",
        fields: [:title, :description],
        parents: [:title, :description],
        failure: :task_failure,
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
      set retry_step: :review, task_failure: :none

      present(
        expected: "Review it on the machinery",
        why: "its agent's work is done",
        instructions:
          "Its supervisor's Runtime runs a second agent on its result, which judges whether it does what the issue asks. Its supervisor's pickup starts the work: nothing is done until then."
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
        failure: :task_failure,
        records: [kind: "task", relation: "task_of"],
        machinery: "machinery",
        on: [
          completed: :publishing,
          check_failed: :publishing,
          changes_required: :fixing,
          stuck: :review_stuck,
          abandoned: :review_stuck
        ]
      )
    end

    # One fix of the review's findings, on the author's result as its base (as the review
    # gets it): its result commit sits on the author's, so the pull request has both. No
    # second review follows.
    state :fixing, label: "Fixing" do
      set retry_step: :fix, task_failure: :none

      present(
        expected: "Fix it on the machinery",
        why: "its review asks for changes",
        instructions:
          "Its supervisor's Runtime runs an agent on its result with the review's findings; its fix is what Code then opens a pull request from. Its supervisor's pickup starts the work: nothing is done until then."
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
        failure: :task_failure,
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

    # The CI gate: rela's GitHub sync writes its pull request's check status (`pr_checks`),
    # what failed (`pr_checks_failure`) and whether it merges into develop
    # (`pr_mergeable`). Entering it sets both unknown, so a status of the head before the
    # last push is never taken for this one. Conflicting leads to an update with develop,
    # once (`pr_updates`); red to a fix of what failed, pushed onto the same pull request,
    # at most twice (`ci_fixes`); still conflicting or red, its supervisor decides. Its
    # supervisor is asked to merge it only when it is green and mergeable. Merged meanwhile
    # is done.
    state :checking, label: "Waiting for CI" do
      set pr_checks: :pending, pr_mergeable: :unknown

      present(
        expected: "Wait for its CI",
        why: "its pull request is open",
        instructions:
          "GitHub runs the checks of its pull request; nothing is asked of anyone meanwhile. Passed and mergeable, its supervisor merges it; conflicting with develop, an agent updates it; failed, an agent fixes what failed on its machinery, at most twice."
      )

      branch to: :done, when: "entity.pr_state == 'merged'"

      branch to: :update_failing,
             when:
               "(entity.pr_mergeable == 'conflicting' or entity.pr_mergeable == 'behind') and entity.pr_updates == 'one'"

      branch to: :updating,
             when: "entity.pr_mergeable == 'conflicting' or entity.pr_mergeable == 'behind'"

      branch to: :merging,
             when: "entity.pr_checks == 'success' and entity.pr_mergeable == 'clean'"

      branch to: :ci_failing,
             when: "entity.pr_checks == 'failure' and entity.ci_fixes == 'two'"

      branch to: :ci_fixing_again,
             when: "entity.pr_checks == 'failure' and entity.ci_fixes == 'one'"

      branch to: :ci_fixing, when: "entity.pr_checks == 'failure'"
    end

    # Its pull request conflicts with develop: an agent resolves develop merged into it
    # (Code's merge of develop into the pull request's head, with the conflicts marked),
    # keeping its intent, and Code pushes the result onto the same pull request
    # (`update_pushing`), whose CI is waited for again. One update per conflict.
    state :updating, label: "Updating it with develop" do
      set pr_updates: :one

      present(
        expected: "Update it with develop on the machinery",
        why: "its pull request conflicts with develop",
        instructions:
          "Its machinery runs an agent on develop merged into its pull request, which resolves the conflicts; Code then pushes the update onto its pull request. Nothing is done while it is not assigned to a machinery."
      )

      task(:fix,
        role: :developer,
        profile: :deep_coding,
        cost_class: :standard,
        input: [repository: "github.com/mimbre/atlas", base: "develop", update: :pr_url],
        instructions:
          "Update the pull request of the issue below with develop, in the repository you are given: a Git checkout of develop merged into its pull request. Its last commit only adds the base's dependencies; under it (HEAD~1) is the merge: its first parent is the pull request's head, its second develop, and its message lists the files that conflict, which hold Git's conflict markers. Resolve every conflict keeping the pull request's intent and develop's changes alike; leave no conflict marker. Run bin/check. End your answer with what you resolved and what is left open.",
        fields: [:title, :description],
        parents: [:title, :description],
        records: [kind: "task", relation: "task_of"],
        machinery: "machinery",
        on: [
          completed: :update_pushing,
          check_failed: :update_pushing,
          stuck: :update_failing,
          abandoned: :update_failing
        ]
      )
    end

    # Code pushes the update, on top of the pull request's head, to its branch
    # (`onto: :pr_url`): the same pull request, whose CI is waited for again.
    state :update_pushing, label: "Pushing its update" do
      present(
        expected: "Let Code push its update",
        why: "its update with develop is done",
        instructions:
          "Code pushes the update onto the branch of its pull request on GitHub; nothing is asked of anyone meanwhile."
      )

      effect(:push,
        contract: 1,
        name: "update",
        service: "code",
        operation: "publish",
        field: :pr_update,
        fingerprint: [fields: ["title"], relations: []],
        payload: ["title", "description"],
        input: [repository: "github.com/mimbre/atlas", base: "develop", onto: :pr_url],
        on: [done: :checking, no_changes: :update_failing, refused: :update_failing]
      )
    end

    # Its pull request still conflicts with develop after its update, or the update could
    # not be made or pushed: its supervisor decides. They update it by hand (green and
    # mergeable is theirs to merge) or close it; merged is done.
    state :update_failing, label: "Conflicts with develop" do
      owner via: :assignment, relation: :assigned_to, default: {:person, config: :decider}
      set gate_result: :none

      present(
        expected: "Decide what to do with it",
        why: "its pull request conflicts with develop, and its agent's update did not resolve it",
        instructions:
          "Its agent could not update its pull request with develop: the update ended without a result, Code could not push it (its branch moved meanwhile), or it still conflicts. Update it by hand (once it is green and mergeable it is yours to merge), or close it.",
        answers: [[key: "c", label: "Close it", change: %{values: %{gate_result: :close}}]]
      )

      branch to: :done, when: "entity.gate_result == 'close'"
      branch to: :done, when: "entity.pr_state == 'merged'"
      branch to: :checking, when: "entity.pr_mergeable == 'clean'"
    end

    # A fix of its failing CI, on its latest result (as the review's fix): what failed, the
    # failing checks with the failing lines of their logs, is what it fixes.
    state :ci_fixing, label: "Fixing its CI" do
      set ci_fixes: :one, retry_step: :ci_fix, task_failure: :none

      present(
        expected: "Fix its CI on the machinery",
        why: "the CI of its pull request failed",
        instructions:
          "Its supervisor's Runtime runs an agent on its result with what failed in its CI; Code then pushes its fix onto its pull request. Its supervisor's pickup starts the work: nothing is done until then."
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
        failure: :task_failure,
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
      set ci_fixes: :two, retry_step: :ci_fix_again, task_failure: :none

      present(
        expected: "Fix its CI on the machinery",
        why: "the CI of its pull request failed after its fix",
        instructions:
          "Its supervisor's Runtime runs an agent on its result with what failed in its CI, the last time; Code then pushes its fix onto its pull request. Its supervisor's pickup starts the work: nothing is done until then."
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
        failure: :task_failure,
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

      branch to: :merging,
             when: "entity.pr_checks == 'success' and entity.pr_mergeable == 'clean'"
    end

    # Its supervisor is asked to merge it only while it is green and mergeable: conflicting
    # or not green meanwhile (develop moved, a push, a rerun), it goes back to the CI gate,
    # which updates or fixes it. Reaching it ends a round: a later conflict or red gets
    # its update and fixes again.
    state :merging, label: "Merge it" do
      owner via: :assignment, relation: :assigned_to, default: {:person, config: :decider}
      set pr_updates: :none, ci_fixes: :none

      present(
        expected: "Review and merge its pull request",
        why: "its agent's work is done",
        instructions:
          "Its CI passed and it merges into develop. Open its pull request, read its review's verdict and findings and its fix's answer in its body, and merge it on GitHub; the issue is done once GitHub says it is merged."
      )

      branch to: :done, when: "entity.pr_state == 'merged'"

      branch to: :checking,
             when: "entity.pr_mergeable == 'conflicting' or entity.pr_mergeable == 'behind'"

      branch to: :checking,
             when: "entity.pr_checks == 'failure' or entity.pr_checks == 'pending'"
    end

    # Its agent changed nothing (author's and fix's result alike): Code opened no pull
    # request, and its supervisor is told (IS-Atlas-63). They close it (a maintainer's
    # choice, `gate_result: close`) when nothing was to change, or build it again: back to
    # Working, for a fresh author on a fresh base of develop (`gate_result: rebuild`).
    state :unchanged, label: "Nothing to merge" do
      owner via: :assignment, relation: :assigned_to, default: {:person, config: :decider}
      set gate_result: :none

      present(
        expected: "Decide what to do with it",
        why: "its agent changed nothing",
        instructions:
          "Its result has no changes against develop, so Code opened no pull request. Build it again for a fresh author on a fresh base of develop (when its agent failed to change what it should), or close it when nothing was to change.",
        answers: [
          [key: "b", label: "Build it again", change: %{values: %{gate_result: :rebuild}}],
          [key: "c", label: "Close it", change: %{values: %{gate_result: :close}}]
        ]
      )

      branch to: :done, when: "entity.gate_result == 'close'"
      branch to: :working, when: "entity.gate_result == 'rebuild'"
    end

    # An agent task ended without a result (stuck or abandoned), or Code refused its pull
    # request or a push onto it: its supervisor is told why, and decides. Retry goes back
    # to the state of the step its last task ran as (`retry_step`), for a fresh task: the
    # author on a fresh base of develop, any other on the latest result that has one. A run
    # whose step is not known (stuck before this state was open) is built again. Merged
    # meanwhile is done.
    state :stuck, label: "Stuck" do
      owner via: :assignment, relation: :assigned_to, default: {:person, config: :decider}
      set gate_result: :none

      present(
        expected: "Decide what to do with it",
        why: "its agent's work ended without a result",
        instructions:
          "An agent task of its build ended without a result, or Code refused to open or push its pull request (its publication says why; then what failed is none). What failed names the task, how it ended and why. Retry runs that step again with a fresh task: its author on a fresh base of develop, any other on its latest result. Or close it.",
        section: [field: :task_failure, label: "What failed"],
        answers: [
          [key: "r", label: "Retry", change: %{values: %{gate_result: :retry}}],
          [key: "c", label: "Close it", change: %{values: %{gate_result: :close}}]
        ]
      )

      branch to: :done, when: "entity.gate_result == 'close'"
      branch to: :done, when: "entity.pr_state == 'merged'"

      branch to: :reviewing,
             when: "entity.gate_result == 'retry' and entity.retry_step == 'review'"

      branch to: :fixing, when: "entity.gate_result == 'retry' and entity.retry_step == 'fix'"

      branch to: :ci_fixing,
             when: "entity.gate_result == 'retry' and entity.retry_step == 'ci_fix'"

      branch to: :ci_fixing_again,
             when: "entity.gate_result == 'retry' and entity.retry_step == 'ci_fix_again'"

      # The author's step, or none known (an absent field matches no condition, so this
      # one names none): built again. Last, so every step above is taken first.
      branch to: :working, when: "entity.gate_result == 'retry'"
    end

    # Its review ended without a result: its author's result, which the review ran on, is
    # complete in Code (a review follows only an author that ended with one). Its
    # supervisor retries the review, publishes the result without one (Code's pull request
    # says no review was made), or closes it.
    state :review_stuck, label: "Its review failed" do
      owner via: :assignment, relation: :assigned_to, default: {:person, config: :decider}
      set gate_result: :none

      present(
        expected: "Decide what to do with it",
        why: "its review ended without a result",
        instructions:
          "The agent reviewing its author's result ended without a verdict; what failed says how and why. Its author's result is complete in Code. Retry runs a fresh review of it; Publish without review has Code open its pull request from it, its body saying no review was made; or close it.",
        section: [field: :task_failure, label: "What failed"],
        answers: [
          [key: "r", label: "Retry", change: %{values: %{gate_result: :retry}}],
          [
            key: "p",
            label: "Publish without review",
            change: %{values: %{gate_result: :publish}}
          ],
          [key: "c", label: "Close it", change: %{values: %{gate_result: :close}}]
        ]
      )

      branch to: :done, when: "entity.gate_result == 'close'"
      branch to: :reviewing, when: "entity.gate_result == 'retry'"
      branch to: :publishing, when: "entity.gate_result == 'publish'"
    end

    final :done, label: "Done"
  end
end

defmodule Model.PrTest do
  @moduledoc """
  The test of a pull request: a subflow on the `pr_test` that the pull request
  subflow creates, for one exact revision of it (`revision`). A tester tests that
  revision and sets the verdict themselves, naming themselves in `verdict_by`
  (`Model.PrReview`) in the same change: Facts takes it as their trusted choice.

    * The verdict ends it as `passed` or `failed`; the composition reports that to
      the pull request (`test_outcome`), but only while the test is for the pull
      request's current revision (`current:`): a test of an older revision reports
      nothing, however late it ends.
    * No verdict in three days escalates it to a maintainer, next to the tester.
    * A newer revision of the pull request supersedes it (`superseded`).

  Slice 7 runs it on Flow's durable runs (`select`), with the parity fixes of
  `Model.PrReview`: no pass yet, and `superseded` taken as it is written.
  """
  use RelaDSL

  entity :pr_test,
    label: "PR test",
    plural: "pr_tests",
    id_type: :short,
    id_prefix: "PRT-",
    description: """
    The test of one pull request by a person, created by the pull request's
    flow. Its outcome is reported back to the pull request.
    """ do
    field(:title, :string, required: true, description: "What is tested")
    field(:verdict, :string, description: "The tester's verdict: passed or failed")

    field(:superseded, :boolean,
      default: false,
      description: "True when a newer revision of the pull request replaced this test"
    )

    field(:revision, :string,
      description: "The exact revision of the pull request this test is for (its head commit)"
    )
  end

  relation(:test_of,
    label: "test of",
    description: "A test belongs to one pull request; a pull request has its tests.",
    from: [:pr_test],
    to: [:pull_request],
    max_outgoing: 1,
    inverse: {:tests, "tests"}
  )

  subflow :pr_test, label: "PR test", subject: :pr_test do
    owner relation: :assigned_to
    start :create
    initial :working

    state :working, label: "PR test in progress" do
      branch to: :superseded, when: "entity.superseded == true"

      wait_for [:tester],
        on: :verdict,
        reset: false,
        passed: :passed,
        failed: :failed

      timer :stalled, "3d", to: :escalated, label: "No outcome in three days"
    end

    state :escalated, label: "Escalated" do
      branch to: :superseded, when: "entity.superseded == true"

      wait_for [:maintainer, :tester],
        on: :verdict,
        reset: false,
        passed: :passed,
        failed: :failed
    end

    final :passed
    final :failed
    final :superseded, label: "Superseded by a newer PR revision", status: :cancelled
  end

  # How the runs of pr_test are selected and imported, as for pr_review: superseded, the
  # two verdicts as completed history, and every open test into `working`.
  select(:pr_test,
    choices: [:verdict],
    roles: [tester: :verdict_by, maintainer: :verdict_by],
    admission: [],
    imports: [
      [when: [superseded: [true]], state: :superseded],
      [when: [verdict: [:passed]], state: :passed],
      [when: [verdict: [:failed]], state: :failed],
      [when: [], state: :working]
    ]
  )

  # The approved migration of its runs, from the digest the base branch recorded
  # (RelaDSL.RunIdentity); the same in prod and test. No run had that digest: the
  # subflow was never selected before slice 7. A run that did would move along it as a
  # state migration (re-entering its state), never as a re-key, since the pass went.
  migrate(:pr_test,
    from: "43fcbbf9a95d4e5bbac5c72d2dc878c28e56b48f7dd865e43d57cdb5e6bd5644",
    to: "909f7ac67ca0c71b562b6828d4e92cb38b057cfdb7d2afb7b4f95c7edd1a2237",
    states: :same,
    reason: "Slice 7: selected without its pass; superseded taken as written"
  )
end

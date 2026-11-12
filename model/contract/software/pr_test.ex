defmodule Model.PrTest do
  @moduledoc """
  The test of a pull request: a subflow on the `pr_test` that the pull request
  subflow creates. A tester tests the exact revision with an agent on
  their own Runtime (a pass with the person, which writes no result) and sets the
  verdict themselves.

    * The verdict ends it as `passed` or `failed`; the composition
      reports that to the pull request (`test_outcome`).
    * No verdict in three days escalates it to a maintainer, next to the tester.
    * A newer revision of the pull request supersedes it (`superseded`, set by
      Atlas when the pull request checks again).
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
      branch to: :superseded, by: :atlas, when: "entity.superseded == true"

      pass :tester,
        mode: :author,
        folder: {:materialize, :parent_revision},
        permissions: :materialized_folder,
        with_person: true,
        writes: :none

      wait_for [:tester],
        on: :verdict,
        reset: false,
        passed: :passed,
        failed: :failed

      timer :stalled, "3d", to: :escalated, label: "No outcome in three days"
    end

    state :escalated, label: "Escalated" do
      branch to: :superseded, by: :atlas, when: "entity.superseded == true"

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
end

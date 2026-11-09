defmodule AtlasFlowContract.PrTest do
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
  use AtlasFlowGenerator.Schema

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

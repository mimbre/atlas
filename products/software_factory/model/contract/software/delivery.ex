defmodule Model.Delivery do
  @moduledoc """
  Delivery of an issue through its pull request, and work a pull request of another
  issue also did. The subflow keeps its durable name `issue`; Model.Issue holds its
  kind, gates, selection and migration policy, with the slice 9 parity rationale.

  Building an issue is a supervised flow (decision 2026-11-17 §5.6): its span `build`
  is the state `author`, and the runs of its packages (`package`, under it through
  `package_of`) and of its pull requests (`pull_request`, through `in_issue`) belong to
  it: a person item of theirs goes to its supervisor (rule S3). Picking it up makes a
  person its human supervisor until the run leaves `author`; the span sits beside the
  subflow, so it changes no digest.
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
    owner via: :assignment, relation: :assigned_to, default: {:agent, :coordinator}
    channel :work
    start :create
    initial :author
    supervise :build, label: "Build", states: [:author], with: [:package, :pull_request]

    state :author, label: "Building" do
      present(
        expected: "Build it",
        why: "its pull request is not merged",
        instructions:
          "Build it in one pull request and get that merged; link the pull request to it."
      )

      # Changes requested on its pull request, or a closed one: it is built again, as
      # today (a new entry of the same state, nothing written); merged: done.
      await :pr_outcome, changes_requested: :author, integrated: :done, closed: :author
    end

    final :done, label: "Integrated"
  end
end

defmodule Model.FollowThrough do
  @moduledoc """
  The follow-through of an accepted decision: it stays owned until work carries it out
  (a scene, use case or issue is based on it) or its `no_work` says none is needed.

  `decide` ends when a decision is accepted; this subflow takes the decision from there
  (`select`: it admits only accepted decisions, `decide` the others). `work` is the
  composition's tally of the facts based on it (`based_on`, of every kind that has the
  relation), which Flow keeps on the decision: frozen as an accepted decision is, it
  still takes its tally (`frozen ... tallied: [:work]`).

    * `waiting` presents "Carry it out" to the coordinator, as the old flow `decide`'s
      `waiting` did, under the same state name, so what Flow wrote stays;
    * `no_work` ends it when a person sets `no_work` (frozen lets them);
    * `carried_out` ends it once something is based on it: removing that work later does
      not reopen it (the default, `reopen` explicit);
    * `superseded` ends it when a newer decision supersedes it before work did.
  """
  use RelaDSL

  subflow :follow_through, label: "Follow through", subject: :decision do
    owner via: :assignment, relation: :assigned_to, default: {:agent, :coordinator}
    start :predicate, when: "entity.status == 'accepted'"
    initial :waiting

    state :waiting, label: "Carry it out" do
      present(
        expected: "Carry it out: {consequences}",
        why: "it is accepted and no work is based on it yet",
        instructions:
          "Its consequences say what must change. Base the work that carries it out on it (a scene or use case with based_on it), or set no_work=true when none is needed; Flow then closes it."
      )

      branch to: :no_work, when: "entity.no_work == true"
      branch to: :superseded, when: "entity.status == 'superseded'"
      branch to: :carried_out, when: "entity.work > 0"
    end

    final :carried_out, label: "Carried out"
    final :no_work, label: "No work needed"
    final :superseded, label: "Superseded", status: :cancelled
  end

  # How the runs of follow_through are selected, imported from the decision as it was
  # before the subflow ran, and presented: on its Assignment, where the old flow decide
  # presented an accepted decision. The projection is decide's, so the two present one
  # decision through one presenter, each in its own statuses.
  #
  # The first row that holds gives the entry, writing nothing and rerunning nothing:
  #
  #   * an accepted decision whose `no_work` is set is completed history, `no_work`;
  #   * any other accepted decision joins `waiting`. On its first entry the tally of the
  #     work based on it is offered to the run: one with work moves to `carried_out` in
  #     that same reaction, one without stays owned, as the old flow presented them.
  #
  # A decision accepted later matches a row too, and takes the same way.
  select(:follow_through,
    choices: [],
    projection: [
      on: :assignment,
      state_field: :flow_state,
      deadline_field: :deadline,
      handover_field: :handover,
      owner_relation: :assigned_to,
      field: :expected
    ],
    admission: [status: [:accepted]],
    imports: [
      [when: [no_work: [true]], state: :no_work],
      [when: [status: [:accepted]], state: :waiting]
    ]
  )
end

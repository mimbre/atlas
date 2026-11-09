defmodule Model.Profiles.Incident.Service do
  @moduledoc "The incident of the incident profile: restoring a service, resolved by a person."
  use RelaDSL

  entity :incident, label: "Incident", plural: "incidents", id_type: :manual, id_prefix: "INC-" do
    field(:title, :string, required: true)
    field(:description, :string)
    start key: "i", label: "Incidents"
    create(ask: [:title, :description], id: [prefix: "INC-", digits: 2])
    completion(by: :resolved_by)
  end

  relation(:in_incident,
    label: "in incident",
    from: [:issue],
    to: [:incident],
    max_outgoing: 1,
    inverse: {:issues, "issues"},
    parent: true
  )

  relation(:resolved_by,
    label: "resolved by",
    from: [:incident],
    to: [:person],
    max_outgoing: 1,
    inverse: {:resolved_incidents, "resolved incidents"},
    only_target: [error: "only a person records service restoration"],
    actions: [set: [key: "a", label: "Resolve"], remove: [key: "a", label: "Reopen"]]
  )
end

defmodule Model.Profiles.Incident.Work do
  @moduledoc """
  How the incident profile builds its issues: the runner builds an issue until one of
  its pull requests is merged, and the coordinator reviews and merges the pull request.
  The pull request's run reports its merge to the issue (`pr_outcome`, the
  composition's link). An incident itself is resolved by a person (`resolved_by`), which
  no subflow presents.
  """
  use RelaDSL

  subflow :incident_issue, label: "Build it", subject: :issue do
    run_as "system:atlas-flow"
    owner via: :assignment, relation: :assigned_to, default: {:agent, :runner}
    start :create
    initial :building

    state :building, label: "Build it" do
      present(
        expected: "Build it",
        why: "its pull request is not merged",
        instructions:
          "Build it in one pull request and get that merged; link the pull request to it."
      )

      await :pr_outcome, integrated: :done
    end

    final :done, label: "Merged"
  end

  subflow :incident_pull_request, label: "Review and merge", subject: :pull_request do
    run_as "system:atlas-flow"
    owner via: :assignment, relation: :assigned_to, default: {:agent, :coordinator}
    start :create
    initial :open

    state :open, label: "Review and merge it" do
      present(
        expected: "Review and merge it",
        why: "it is open",
        instructions: "Review the pull request; merge it, or close it."
      )

      branch to: :merged, when: "entity.state == 'merged'"
      branch to: :closed, when: "entity.state == 'closed'"
    end

    final :merged, label: "Merged"
    final :closed, label: "Closed", status: :cancelled
  end

  @projection [
    on: :assignment,
    state_field: :flow_state,
    handover_field: :handover,
    owner_relation: :assigned_to,
    field: :expected
  ]

  select(:incident_issue,
    choices: [],
    projection: @projection,
    admission: [],
    imports: [[completed: true, state: :done]]
  )

  select(:incident_pull_request,
    choices: [],
    projection: @projection,
    admission: [],
    imports: [
      [when: [state: [:merged]], state: :merged],
      [when: [state: [:closed]], state: :closed]
    ]
  )
end

defmodule Model.Profiles.Incident.Module do
  @moduledoc "The incident profile's own module."
  use RelaDSL.Module,
    path: "modules/incident/schema.yaml",
    concepts: [Model.Profiles.Incident.Service, Model.Profiles.Incident.Work]
end

defmodule Model.Profiles.Incident do
  @moduledoc """
  A private dependency proof, not an installed workflow (MIX_ENV=test only): foundation,
  its audit and software reused for incidents, with independent person resolution and
  no scene, use case or acceptance. Issues are built and their pull requests merged by
  its own subflows (`Model.Profiles.Incident.Work`): an issue's keys are its own, it is
  owned by the runner agent while it is built, and an incident is resolved by a person
  while its software follow-up is open.

      MIX_ENV=test mix model.gen --contract Model.Profiles.Incident --out DIR
  """
  use RelaDSL.Composition,
    name: "incident",
    subflow_behaviour: AtlasFlow.Subflow

  # The model Facts, Flow, Gates, Runtime and Control are wired to (config :atlas, model: …).
  @behaviour AtlasFacts.Model
  @behaviour AtlasFlow.Model
  @behaviour AtlasGates.Model
  @behaviour AtlasRuntime.Model
  @behaviour AtlasControl.Model

  schema(
    version: "1.0",
    namespace: "https://example.invalid/fixture#",
    description: "Private dependency fixture"
  )

  # Compiled for both environments, so a private instance of either can run it.
  environments([:prod, :test])

  modules([
    Model.Foundation,
    Model.Foundation.Audit,
    Model.Software,
    Model.Profiles.Incident.Module
  ])

  relation(:assignment,
    label: "assignment",
    from: [:incident, :issue, :pull_request],
    to: [:assignment],
    max_outgoing: 1,
    inverse: {:assignment_of, "assignment of"},
    component: [key: "AS-{key}", values: [of: "{key}"]],
    set_by: [:migration]
  )

  relation(:about,
    label: "about",
    from: [:gate_verdict],
    to: [:decision, :incident, :issue, :pull_request],
    max_outgoing: 1,
    inverse: {:gate_verdicts, "gate verdicts"}
  )

  start_page(assigned: [empty: "Nothing is assigned to you."])

  extend_entity(:issue,
    create: [id: [prefix: "IS-Maint-", digits: 2], defaults: [stage: :specification]],
    completion: [
      [over: :in_issue, field: :state, value: :merged],
      [through: :done_in, field: :state, value: :merged]
    ],
    progress: [
      own: :stage,
      while: [[over: :in_issue, field: :state, value: :open, shows: :development]]
    ]
  )

  acl(comment: "The roles the incident profile's subflows name.")

  role("atlas-flow",
    read: ["*"],
    create: [:flow_run, :flow_input],
    update: [:flow_input, :flow_run, :issue, :pull_request]
  )

  assign("system:atlas-flow", "atlas-flow")

  defcomposition :incident do
    subflows([Model.Profiles.Incident.Work])

    link(:incident_pull_request,
      to: {:issue, :in_issue},
      field: :pr_outcome,
      states: [merged: :integrated]
    )
  end
end

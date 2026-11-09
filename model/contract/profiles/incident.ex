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

defmodule Model.Profiles.Incident.Module do
  @moduledoc "The incident profile's own module."
  use RelaDSL.Module,
    path: "modules/incident/schema.yaml",
    concepts: [Model.Profiles.Incident.Service]
end

defmodule Model.Profiles.Incident do
  @moduledoc """
  A private dependency proof, not an installed workflow (MIX_ENV=test only): foundation,
  its audit and software reused for incidents, with independent person resolution and
  no scene, use case or acceptance. Issues are built and their pull requests merged as
  in the main composition, but an issue's keys are its own, its last state is owned by
  the runner agent, and an incident is resolved while its software follow-up is open.

      MIX_ENV=test mix model.gen --contract Model.Profiles.Incident --out DIR
  """
  use RelaDSL.Composition,
    name: "incident",
    subflow_behaviour: AtlasFlow.Subflow,
    legacy_behaviour: AtlasFlow.Legacy

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

  @run [
    on: :assignment,
    state_field: :flow_state,
    handover_field: :handover,
    owner_relation: :assigned_to,
    field: :expected
  ]

  legacy_flow(
    :build_and_merge,
    @run ++
      [
        kinds: [:issue],
        states: [
          [name: :done, when: [completed: true], done: true],
          [
            name: :building,
            owner: [kind: :agent, key: "runner"],
            expected: "Build it",
            why: "its pull request is not merged",
            next: [:done],
            todo: [
              instructions:
                "Build it in one pull request and get that merged; link the pull request to it."
            ]
          ]
        ]
      ]
  )

  legacy_flow(
    :review_and_merge,
    @run ++
      [
        kinds: [:pull_request],
        states: [
          [name: :done, when: [values: [state: [:merged, :closed]]], done: true],
          [
            name: :open,
            owner: [kind: :agent, key: "coordinator"],
            expected: "Review and merge it",
            why: "it is open",
            next: [:done],
            todo: [instructions: "Review the pull request; merge it, or close it."]
          ]
        ]
      ]
  )

  legacy_flow(
    :restore_service,
    @run ++
      [
        kinds: [:incident],
        states: [
          [name: :done, when: [completed: true], done: true],
          [
            name: :restore,
            owner: [kind: :agent, key: "coordinator"],
            expected: "Restore service and record resolution",
            next: [:done]
          ]
        ]
      ]
  )

  defcomposition :incident do
    subflows([])
  end
end

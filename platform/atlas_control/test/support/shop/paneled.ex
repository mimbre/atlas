defmodule AtlasControl.Shop.PaneledWidget do
  @moduledoc """
  A widget its holder decides on in panels (`panel`): its parts to accept (check), the
  widget to ship (ship: checks and a link, no answers) and, when its inspection failed,
  what now (stuck: a choice, with what went wrong). Its inspections are records Flow keeps.
  """
  use RelaDSL

  type(:shade, values: [:light, :dark], labels: [light: "Light", dark: "Dark"])
  type(:widget_state, values: [:open, :final, :dropped, :shipped, :failed])
  type(:verdict, values: [:fine, :faulty], labels: [fine: "Fine", faulty: "Faulty"])

  entity :widget, label: "Widget", plural: "widgets", id_type: :manual, id_prefix: "W-" do
    field(:title, :string, required: true)
    field(:shade, :shade)
    field(:site, :string)
    field(:failure, :string, multiline: true)
    field(:state, :widget_state)
    primary(:title)
    create(ask: [:title], id: [prefix: "W-", digits: 2])

    panel(
      check: [
        heading: "TO ACCEPT",
        title: "Parts of {key} · {title}",
        records: [proposal: [relation: :inspection_of, where: [kind: :plan]]],
        byline: ["Proposed by {proposal}", [age: ""], "built in this order"],
        items: [
          relation: :of_widget,
          order: :rank,
          count: ["part", "parts"],
          details: [
            [label: "What", field: :notes, before: "Done when:"],
            [label: "Done", field: :notes, after: "Done when:"],
            [label: "Needs", earlier: true]
          ]
        ],
        actions: [[key: "i", label: "Full proposal", record: :proposal]]
      ],
      ship: [
        heading: "TO SHIP",
        title: "\#{site|number} {title}",
        records: [inspection: [relation: :inspection_of, where: [kind: :inspect]]],
        byline: ["{key}", "by {inspection}", [age: "waiting"]],
        checks: [
          [
            label: "Shade",
            text: "{shade}",
            state: [field: :shade, success: [:light], error: [:dark]]
          ],
          [
            label: "Inspection",
            text: "{inspection.verdict} · {inspection.answer|line}",
            state: [field: "inspection.verdict", success: [:fine], error: [:faulty]]
          ]
        ],
        links: [[key: "o", label: "Open its site", field: :site]],
        actions: [[key: "r", label: "Full inspection", record: :inspection]]
      ],
      stuck: [
        heading: "YOUR DECISION",
        title: "{key} is stuck: what now?",
        records: [last: [relation: :inspection_of]],
        byline: ["{last.kind}", "attempt {last.attempt} failed", [age: "stuck"]],
        box: [title: "What went wrong", field: :failure, tone: :error, empty: ["none"]],
        choose: true,
        details: [r: "Inspects it again.", c: "Ends it."],
        actions: [[key: "l", label: "Inspector's log", record: :last]]
      ]
    )
  end

  entity :inspection,
    label: "Inspection",
    plural: "inspections",
    id_type: :manual,
    id_prefix: "I-" do
    field(:title, :string, required: true)
    field(:kind, :string)
    field(:attempt, :string)
    field(:verdict, :verdict)
    field(:answer, :string, multiline: true)
    primary(:title)
    by_hand(false)
  end

  relation(:inspection_of,
    label: "inspection of",
    from: [:inspection],
    to: [:widget],
    max_outgoing: 1,
    inverse: {:inspections, "inspections"},
    set_by: [:flow]
  )

  subflow :review, label: "Review", subject: :widget do
    run_as("system:shop")
    owner(via: :card, relation: :held_by, default: {:member, :ada})
    start(:create)
    initial(:check)

    state :check, label: "Check" do
      present(
        expected: "Accept its parts",
        answers: [
          [key: "a", label: "Accept", change: %{values: %{state: :final}}],
          [key: "n", label: "Not accepted", note: true, change: %{values: %{state: :dropped}}]
        ]
      )

      branch(to: :ship, when: "entity.state == 'final'")
      branch(to: :stuck, when: "entity.state == 'failed'")
    end

    state :ship, label: "Ship it" do
      present(expected: "Ship it", instructions: "Ship it from its site.")
      branch(to: :shipped, when: "entity.state == 'shipped'")
    end

    state :stuck, label: "Stuck" do
      present(
        expected: "Decide what to do with it",
        answers: [
          [key: "r", label: "Retry", change: %{values: %{state: :open}}],
          [key: "c", label: "Close it", change: %{values: %{state: :dropped}}]
        ]
      )

      branch(to: :check, when: "entity.state == 'open'")
      branch(to: :shipped, when: "entity.state == 'dropped'")
    end

    final(:shipped, label: "Shipped")
  end

  select(:review,
    choices: [],
    projection: [on: :card, state_field: :step, owner_relation: :held_by, field: :todo],
    admission: [state: [:open, :final, :dropped, :shipped, :failed]],
    imports: []
  )
end

defmodule AtlasControl.Shop.RankedPart do
  @moduledoc "A part of a widget, ranked: built in that order; numbered P-."
  use RelaDSL

  entity :part, label: "Part", plural: "parts", id_type: :manual, id_prefix: "P-" do
    field(:title, :string, required: true)
    field(:notes, :string, description: "Free text", multiline: true)
    field(:rank, :integer)
    primary(:title)
  end

  relation(:of_widget,
    label: "of widget",
    from: [:part],
    to: [:widget],
    max_outgoing: 1,
    parent: true,
    inverse: {:parts, "parts"}
  )
end

alias AtlasControl.Shop

defmodule Shop.Paneled do
  @moduledoc "A widget its holder decides on in panels (`AtlasControl.Shop.PaneledWidget`)."
  use Shop.Composition,
    name: "shop-paneled",
    concepts: [
      Shop.PaneledWidget,
      Shop.RankedPart,
      Shop.Tag,
      Shop.Member,
      Shop.Links,
      Shop.Card,
      Shop.Runs
    ],
    subflows: [AtlasControl.Shop.PaneledWidget]

  todo_words(title: "Your move", why: "Because", instructions: "How", answers: "Keys")
  shell(title: "Private Console", tabs: [[id: "widgets", label: "Widgets", to: "/k/widget"]])

  acl(comment: "The shop's flow.")
  role("shop-flow", read: ["*"], update: [:widget, :run])
  assign("system:shop", "shop-flow")
end

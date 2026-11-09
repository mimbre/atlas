# The neutral model Control's tests serve pages for: a workshop of widgets, their parts,
# the tags on parts and the members who check and approve them. Its kinds are made up on
# purpose. Each concept is one kind (or a few), as a model writes them in the Rela DSL;
# the compositions (`AtlasControl.Shop`) select them, and vary them for one test or a few.

defmodule AtlasControl.Shop.Widget do
  @moduledoc "A widget: titled, shaded, with notes; numbered W-."
  use RelaDSL

  type(:shade, values: [:light, :dark], labels: [light: "Light", dark: "Dark"])

  entity :widget, label: "Widget", plural: "widgets", id_type: :manual, id_prefix: "W-" do
    field(:title, :string, required: true)
    field(:shade, :shade)
    field(:done, :boolean, default: false)
    field(:notes, :string, description: "Free text", multiline: true)
    # Only a connector fills it.
    field(:ext_ref, :string, set_by: [:connector])
    primary(:title)

    create(
      ask: [:title, :notes],
      id: [prefix: "W-", digits: 2],
      defaults: [shade: :light, done: false]
    )
  end
end

defmodule AtlasControl.Shop.DecidedWidget do
  @moduledoc "A widget with a state a member decides, and a subflow that reviews it."
  use RelaDSL

  type(:shade, values: [:light, :dark], labels: [light: "Light", dark: "Dark"])
  type(:widget_state, values: [:open, :final, :dropped])

  entity :widget, label: "Widget", plural: "widgets", id_type: :manual, id_prefix: "W-" do
    field(:title, :string, required: true)
    field(:shade, :shade)
    field(:done, :boolean, default: false)
    field(:notes, :string, description: "Free text", multiline: true)
    field(:ext_ref, :string, set_by: [:connector])
    field(:state, :widget_state)
    primary(:title)

    create(
      ask: [:title, :notes],
      id: [prefix: "W-", digits: 2],
      defaults: [shade: :light, done: false]
    )

    authority(
      when: [state: [:final]],
      by: :checked_by,
      kind: :member,
      writes: [state: [:final]],
      error: "a member decides",
      writer_error: "only the one checked_by names decides"
    )
  end

  subflow :review, label: "Review", subject: :widget do
    run_as("system:shop")
    owner(via: :card, relation: :held_by, default: {:member, :ada})
    start(:create)
    initial(:check)

    state :check, label: "Check" do
      wait_for([:checker], on: :state, reset: false, final: :final, dropped: :machine)

      present(
        expected: "Check it",
        answers: [
          [key: "a", label: "Accept", change: %{self: :checked_by, values: %{state: :final}}],
          [
            key: "f",
            label: "Reject",
            note: true,
            change: %{self: :checked_by, values: %{state: :dropped}}
          ]
        ]
      )
    end

    state :machine, label: "Machine" do
      wait_for([:checker], on: :state, reset: false, final: :final)
      present(expected: "Work")
    end

    final(:final, label: "Final")
  end

  select(:review,
    choices: [:state],
    roles: [checker: :checked_by],
    projection: [on: :card, state_field: :step, owner_relation: :held_by, field: :todo],
    admission: [state: [:open, :final, :dropped]],
    imports: [[when: [state: [:final]], state: :final]]
  )
end

defmodule AtlasControl.Shop.Part do
  @moduledoc "A part of a widget; numbered P-."
  use RelaDSL

  entity :part, label: "Part", plural: "parts", id_type: :manual, id_prefix: "P-" do
    field(:title, :string, required: true)
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

defmodule AtlasControl.Shop.Spare do
  @moduledoc "A spare of a widget; numbered S-."
  use RelaDSL

  entity :spare, label: "Spare", plural: "spares", id_type: :manual, id_prefix: "S-" do
    field(:title, :string, required: true)
    primary(:title)
  end

  relation(:spare_of,
    label: "spare of",
    from: [:spare],
    to: [:widget],
    max_outgoing: 1,
    parent: true,
    inverse: {:spares, "spares"}
  )
end

defmodule AtlasControl.Shop.FittedPart do
  @moduledoc "A part a connector fills: how it fits, and whether it is a spare."
  use RelaDSL

  type(:fit, values: [:loose, :tight], labels: [loose: "Loose", tight: "Tight"])

  entity :part, label: "Part", plural: "parts", id_type: :manual, id_prefix: "P-" do
    field(:title, :string, required: true)
    field(:fit, :fit, set_by: [:connector])
    field(:spare, :boolean, default: false, set_by: [:connector])
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

defmodule AtlasControl.Shop.Tag do
  @moduledoc "A tag on a part, its id made from its name; one live tag per part."
  use RelaDSL

  # Values of this type are web addresses.
  type(:web_address, description: "A web address", format: :url)

  entity :tag, label: "Tag", plural: "tags", id_type: :manual, id_prefix: "T-" do
    field(:name, :string, required: true)
    field(:note, :string, set_by: [:connector])
    field(:site, :web_address, set_by: [:connector])

    create(
      ask: [:name],
      id: [
        from: :name,
        pattern: "^#([a-z.]+)/([0-9]+)$",
        template: "T-{1}-{2}",
        replace: %{"." => "_"},
        error: "name must look like #word/1"
      ]
    )
  end

  relation(:on_part,
    label: "on part",
    from: [:tag],
    to: [:part],
    max_outgoing: 1,
    parent: true,
    inverse: {:tags, "tags"},
    # One live tag per part; a dropped one does not count.
    limit: [
      max: 1,
      field: :note,
      values: [:live, :kept],
      error: "{parent} already has {child} ({value}); one tag per part"
    ]
  )
end

defmodule AtlasControl.Shop.LabelledTag do
  @moduledoc "A tag whose note is one of a few labelled values."
  use RelaDSL

  type(:web_address, description: "A web address", format: :url)

  type(:tag_note,
    values: [:live, :kept, :dropped],
    labels: [live: "Live", kept: "Kept", dropped: "Dropped"]
  )

  entity :tag, label: "Tag", plural: "tags", id_type: :manual, id_prefix: "T-" do
    field(:name, :string, required: true)
    field(:note, :tag_note, set_by: [:connector])
    field(:site, :web_address, set_by: [:connector])

    create(
      ask: [:name],
      id: [from: :name, pattern: "^#([a-z.]+)/([0-9]+)$", template: "T-{1}-{2}"]
    )
  end

  relation(:on_part,
    label: "on part",
    from: [:tag],
    to: [:part],
    max_outgoing: 1,
    parent: true,
    inverse: {:tags, "tags"},
    limit: [
      max: 1,
      field: :note,
      values: [:live, :kept],
      error: "{parent} already has {child} ({value}); one tag per part"
    ]
  )
end

defmodule AtlasControl.Shop.LooseTag do
  @moduledoc "A tag that may sit on several parts: it belongs under none."
  use RelaDSL

  type(:web_address, description: "A web address", format: :url)

  entity :tag, label: "Tag", plural: "tags", id_type: :manual, id_prefix: "T-" do
    field(:name, :string, required: true)
    field(:note, :string, set_by: [:connector])
    field(:site, :web_address, set_by: [:connector])

    create(
      ask: [:name],
      id: [from: :name, pattern: "^#([a-z.]+)/([0-9]+)$", template: "T-{1}-{2}"]
    )
  end

  relation(:on_part,
    label: "on part",
    from: [:tag],
    to: [:part],
    max_outgoing: 2,
    inverse: {:tags, "tags"}
  )
end

defmodule AtlasControl.Shop.Member do
  @moduledoc "Who checks and approves: a member, its id its name; reached only through what points at it."
  use RelaDSL

  entity :member, label: "Member", plural: "members", id_type: :manual do
    field(:name, :string, required: true)
    top(false)
  end
end

defmodule AtlasControl.Shop.TopMember do
  @moduledoc "A member on the start page."
  use RelaDSL

  entity :member, label: "Member", plural: "members", id_type: :manual do
    field(:name, :string, required: true)
  end
end

defmodule AtlasControl.Shop.Links do
  @moduledoc "The associations: who checked or approved a fact, and where it was seen."
  use RelaDSL

  # At most one, but not a parent.
  relation(:checked_by,
    label: "checked by",
    from: [:widget, :part],
    to: [:member],
    max_outgoing: 1,
    inverse: {:checked, "checked"}
  )

  # Only a member approves, and only as itself.
  relation(:approved_by,
    label: "approved by",
    from: [:widget],
    to: [:member],
    max_outgoing: 1,
    inverse: {:approved, "approved"},
    only_target: [error: "only a member approves", also: [:migration]],
    actions: [set: [label: "Approve", key: "a"], remove: [label: "Withdraw", key: "a"]],
    requires_completed_children: "{key} has {children} open",
    closes_parent: "{parent} is approved; withdraw it first, or put this under another {kind}"
  )

  # History only: a migration sets it.
  relation(:seen_in,
    label: "also seen in",
    from: [:widget],
    to: [:tag],
    set_by: [:migration],
    inverse: {:also_seen, "also seen"}
  )
end

defmodule AtlasControl.Shop.Log do
  @moduledoc """
  A record a client writes (as an agent keeps its requests): kept off the start page,
  newest first, made by no key; its entries name the fact they changed.
  """
  use RelaDSL

  entity :log, label: "Log", plural: "logs", id_type: :manual, id_prefix: "L-" do
    field(:title, :string, required: true)
    field(:redoes, :string, cause: "Redone by")
    primary(:title)
    top(false)
    start(key: "w", label: "What happened")
    order(:newest)
    by_hand(false)
    agent("request")
    create(id: [prefix: "L-", digits: 4, first: 24])
  end

  entity :entry, label: "Entry", plural: "entries", id_type: :manual, id_prefix: "E-" do
    field(:title, :string, required: true)
    field(:about, :string, cause: "What happened here")
    field(:state, :string)
    primary(:title)
    by_hand(false)
    action(key: "x", label: "Undo", to: "agent:undo", when: [state: ["done"]])
  end

  relation(:in_log,
    label: "in log",
    from: [:entry],
    to: [:log],
    max_outgoing: 1,
    parent: true,
    add: false,
    inverse: {:entries, "entries"}
  )
end

defmodule AtlasControl.Shop.Helper do
  @moduledoc "Helpers, one key away from the start page; each row counts what it helps."
  use RelaDSL

  entity :helper, label: "Helper", plural: "helpers", id_type: :manual do
    field(:name, :string, required: true)
    primary(:name)
    top(false)
    start(key: "g", label: "Helpers")
    counts(relation: :helped_by, text: "{count} helped")
  end

  relation(:helped_by,
    label: "helped by",
    from: [:widget, :log],
    to: [:helper],
    max_outgoing: 1,
    inverse: {:helps, "helps"}
  )
end

defmodule AtlasControl.Shop.Task do
  @moduledoc """
  Tasks are made and deleted with something else, changed by hand only; each has an
  optional time it is due, and is late (Facts says) once that has passed.
  """
  use RelaDSL

  entity :task, label: "Task", plural: "tasks", id_type: :manual, id_prefix: "K-" do
    field(:title, :string, required: true)
    field(:todo, :string, set_by: [:flow])
    field(:due, :datetime)
    primary(:title)
    top(false)
    by_hand("update")
    late(after: :due, while: :todo, label: "overdue")
  end
end

defmodule AtlasControl.Shop.Card do
  @moduledoc "A widget's card, made and deleted with it (a made-up component), and who holds it."
  use RelaDSL

  entity :card, label: "Card", plural: "cards", id_type: :manual do
    field(:of, :string, required: true)
    field(:todo, :string, set_by: [:flow])
    field(:step, :string)
    field(:due, :datetime)
    primary(:of)
    top(false)
  end

  relation(:card,
    label: "card",
    from: [:widget],
    to: [:card],
    max_outgoing: 1,
    set_by: [:migration],
    component: [key: "C-{key}", values: [of: "{key}"]]
  )

  relation(:held_by, label: "held by", from: [:card], to: [:member], max_outgoing: 1)
end

defmodule AtlasControl.Shop.Runs do
  @moduledoc "Where the shop's subflow keeps its runs and their inputs."
  use RelaDSL

  entity :run, label: "Run", plural: "runs", id_type: :manual do
    field(:flow, :string)
    field(:state, :string)
    top(false)
    by_hand(false)
  end

  entity :input, label: "Input", plural: "inputs", id_type: :manual do
    field(:run, :string)
    field(:actor, :string)
    top(false)
    by_hand(false)
  end

  flow_runtime(runs: :run, writer: [sender: :flow, by: :flow], inputs: :input)
end

defmodule AtlasControl.Shop.Keeper do
  @moduledoc "A keeper: who keeps widgets and parts."
  use RelaDSL

  entity :keeper, label: "Keeper", plural: "keepers", id_type: :manual do
    field(:title, :string)
    primary(:title)
  end
end

defmodule AtlasControl.Shop.SteppedWidget do
  @moduledoc "A widget whose dark shade a member decides, and which is kept: never deleted."
  use RelaDSL

  type(:shade, values: [:light, :dark], labels: [light: "Light", dark: "Dark"])

  entity :widget, label: "Widget", plural: "widgets", id_type: :manual, id_prefix: "W-" do
    field(:title, :string, required: true)
    field(:shade, :shade)
    field(:done, :boolean, default: false)
    field(:notes, :string, description: "Free text", multiline: true)
    primary(:title)

    create(
      ask: [:title, :notes],
      id: [prefix: "W-", digits: 2],
      defaults: [shade: :light, done: false]
    )

    delete_error("Widgets are kept; record another.")

    authority(
      when: [shade: [:dark]],
      by: :checked_by,
      kind: :member,
      writes: [shade: [:dark]],
      error: "a member decides",
      writer_error: "only the one checked_by names decides"
    )
  end
end

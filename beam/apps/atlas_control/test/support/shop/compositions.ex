defmodule AtlasControl.Shop.Composition do
  @moduledoc false
  # A composition of the shop for Control's tests: `use AtlasControl.Shop.Composition,
  # name: "…", concepts: [...]` selects the concepts as one module, wired as a model
  # Control serves pages for.
  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)
    module = Module.concat(__CALLER__.module, Concepts)
    composition = name |> String.replace("-", "_") |> String.to_atom()
    subflows = Keyword.get(opts, :subflows, [])

    quote do
      defmodule unquote(module) do
        @moduledoc false
        use RelaDSL.Module,
          path: unquote("modules/#{name}/schema.yaml"),
          concepts: unquote(Keyword.fetch!(opts, :concepts))
      end

      use RelaDSL.Composition, unquote(Keyword.drop(opts, [:concepts, :subflows]))
      @behaviour AtlasControl.Model

      schema(version: "1.0", namespace: "https://example.invalid/shop#", comment: "The shop.")
      modules([unquote(module)])

      defcomposition unquote(composition) do
        subflows(unquote(subflows))
      end
    end
  end
end

defmodule AtlasControl.Shop.Base do
  @moduledoc false
  @doc "The concepts of the plain shop."
  def concepts,
    do: [
      AtlasControl.Shop.Widget,
      AtlasControl.Shop.Part,
      AtlasControl.Shop.Tag,
      AtlasControl.Shop.Member,
      AtlasControl.Shop.Links
    ]
end

defmodule AtlasControl.Shop do
  @moduledoc """
  The neutral model of Control's tests: widgets, their parts, the tags on parts, and the
  members who check and approve them (`AtlasControl.Shop.*` concepts). Each nested module
  is the same shop with one thing more or different, for the tests of that thing.
  """
  use AtlasControl.Shop.Composition, name: "shop", concepts: AtlasControl.Shop.Base.concepts()
end

alias AtlasControl.Shop

defmodule Shop.Fitted do
  @moduledoc "Parts a connector fills: how each fits, and whether it is a spare."
  use Shop.Composition,
    name: "shop-fitted",
    concepts: [Shop.Widget, Shop.FittedPart, Shop.Tag, Shop.Member, Shop.Links]
end

defmodule Shop.Two do
  @moduledoc "Spares belong under widgets too: a widget's page lists its parts and its spares."
  use Shop.Composition, name: "shop-two", concepts: Shop.Base.concepts() ++ [Shop.Spare]
end

defmodule Shop.Labelled do
  @moduledoc "A tag's note is one of a few labelled values."
  use Shop.Composition,
    name: "shop-labelled",
    concepts: [Shop.Widget, Shop.Part, Shop.LabelledTag, Shop.Member, Shop.Links]
end

defmodule Shop.Loose do
  @moduledoc "A tag sits on parts without belonging under one."
  use Shop.Composition,
    name: "shop-loose",
    concepts: [Shop.Widget, Shop.Part, Shop.LooseTag, Shop.Member, Shop.Links]
end

defmodule Shop.Rolled do
  @moduledoc "Widgets roll up their parts, parts their tags; a widget's shade is its Look."
  use Shop.Composition, name: "shop-rolled", concepts: Shop.Base.concepts()

  extend_entity(:widget,
    progress: [over: :of_widget, own: :shade],
    properties: [shade: [label: "Look"]]
  )

  extend_entity(:part, progress: [over: :on_part])
end

defmodule Shop.Completing do
  @moduledoc "A widget is done once checked; a part once a tag on it is #ok/1."
  use Shop.Composition, name: "shop-completing", concepts: Shop.Base.concepts()

  progress_order(done_label: "Done")

  extend_entity(:widget,
    progress: [over: :of_widget, own: :shade],
    properties: [shade: [label: "Look"]],
    completion: [by: :checked_by]
  )

  extend_entity(:part,
    progress: [over: :on_part],
    completion: [[over: :on_part, field: :name, value: "#ok/1"]]
  )
end

defmodule Shop.While do
  @moduledoc "As Completing; a widget shows how far its parts are while one is under it."
  use Shop.Composition, name: "shop-while", concepts: Shop.Base.concepts()

  progress_order(done_label: "Done")

  extend_entity(:widget,
    progress: [over: :of_widget, own: :shade, while: [[over: :of_widget]]],
    completion: [by: :checked_by]
  )
end

defmodule Shop.Approving do
  @moduledoc "A widget is done once approved."
  use Shop.Composition, name: "shop-approving", concepts: Shop.Base.concepts()

  progress_order(done_label: "Done")

  extend_entity(:widget,
    progress: [over: :of_widget, own: :shade],
    completion: [by: :approved_by]
  )

  extend_entity(:part, progress: [over: :on_part])
end

defmodule Shop.Named do
  @moduledoc "A tag is named by its note, which a connector fills."
  use Shop.Composition, name: "shop-named", concepts: Shop.Base.concepts()
  extend_entity(:tag, primary: :note)
end

defmodule Shop.ByLayer do
  @moduledoc "Members are made by no key: only a layer writes them."
  use Shop.Composition, name: "shop-by-layer", concepts: Shop.Base.concepts()
  extend_entity(:member, by_hand: false)
end

defmodule Shop.Shown do
  @moduledoc "Members are on the start page."
  use Shop.Composition,
    name: "shop-shown",
    concepts: [Shop.Widget, Shop.Part, Shop.Tag, Shop.TopMember, Shop.Links]
end

defmodule Shop.Logged do
  @moduledoc "With logs and their entries."
  use Shop.Composition, name: "shop-logged", concepts: Shop.Base.concepts() ++ [Shop.Log]
end

defmodule Shop.Counted do
  @moduledoc "With logs, and helpers whose rows count what they help."
  use Shop.Composition,
    name: "shop-counted",
    concepts: Shop.Base.concepts() ++ [Shop.Log, Shop.Helper]
end

defmodule Shop.Due do
  @moduledoc "With tasks, changed by hand only and due by a time."
  use Shop.Composition, name: "shop-due", concepts: Shop.Base.concepts() ++ [Shop.Task]
end

defmodule Shop.Handed do
  @moduledoc "Who checked a widget is handed on, with its title, in one change."
  use Shop.Composition, name: "shop-handed", concepts: Shop.Base.concepts()

  extend_relation(:checked_by,
    actions: [
      change: [label: "Hand to…", key: "h", with: [:title], cause: "handed to {to} by {by}"]
    ]
  )
end

defmodule Shop.Carded do
  @moduledoc "A widget has a card, made and deleted with it, held by a member."
  use Shop.Composition, name: "shop-carded", concepts: Shop.Base.concepts() ++ [Shop.Card]
end

defmodule Shop.Held do
  @moduledoc "Widgets and parts are held by a tag or a keeper."
  use Shop.Composition, name: "shop-held", concepts: Shop.Base.concepts() ++ [Shop.Keeper]

  relation(:held_by,
    label: "held by",
    from: [:widget, :part],
    to: [:tag, :keeper],
    max_outgoing: 1,
    inverse: {:holdings, "holdings"}
  )
end

defmodule Shop.Assigning do
  @moduledoc "A start page of what is kept by the client: a keeper opens on what it keeps."
  use Shop.Composition,
    name: "shop-assigning",
    concepts: Shop.Base.concepts() ++ [Shop.Keeper, Shop.Runs, Shop.Flows.Kept],
    subflows: [Shop.Flows.Kept]

  relation(:kept_by, label: "kept by", from: [:widget, :part], to: [:keeper], max_outgoing: 1)
  extend_entity(:keeper, top: false)
  extend_entity(:widget, start: [key: "s", label: "Widgets"])

  start_page(
    assigned: [
      relation: :kept_by,
      title: "Kept by you",
      count: "{count} kept by you",
      empty: "Nothing is kept by you."
    ]
  )
end

defmodule Shop.AssigningOpen do
  @moduledoc "As Assigning, with open work: the same list for everyone."
  use Shop.Composition,
    name: "shop-assigning-open",
    concepts: Shop.Base.concepts() ++ [Shop.Keeper, Shop.Runs, Shop.Flows.Kept],
    subflows: [Shop.Flows.Kept]

  relation(:kept_by, label: "kept by", from: [:widget, :part], to: [:keeper], max_outgoing: 1)
  extend_entity(:keeper, top: false)
  extend_entity(:widget, start: [key: "s", label: "Widgets"])

  start_page(
    assigned: [
      relation: :kept_by,
      title: "Kept by you",
      count: "{count} kept by you",
      empty: "Nothing is kept by you."
    ],
    open: [title: "Open work", empty: "Nothing is open."]
  )
end

defmodule Shop.CardedStart do
  @moduledoc "What is held is a card: the start page shows the widget it belongs to."
  use Shop.Composition,
    name: "shop-carded-start",
    concepts: Shop.Base.concepts() ++ [Shop.Card, Shop.Runs, Shop.Flows.Painted],
    subflows: [Shop.Flows.Painted]

  start_page(assigned: [relation: :held_by, title: "Held by you", count: "{count} held"])
end

defmodule Shop.Open do
  @moduledoc "Open work: the list of the cards is what is held, for everyone; a card is due."
  use Shop.Composition,
    name: "shop-open",
    concepts: Shop.Base.concepts() ++ [Shop.Card, Shop.Runs, Shop.Flows.Painted],
    subflows: [Shop.Flows.Painted]

  extend_entity(:card, late: [after: :due, while: :todo])

  start_page(
    assigned: [relation: :held_by, title: "Held by you", count: "{count} held"],
    open: [title: "All held", empty: "Nothing is held."]
  )
end

defmodule Shop.Todo do
  @moduledoc "What to do: a subflow on widgets, on their card; its state is the card's step."
  use Shop.Composition,
    name: "shop-todo",
    concepts: Shop.Base.concepts() ++ [Shop.Card, Shop.Runs, Shop.Flows.Checked],
    subflows: [Shop.Flows.Checked]

  todo_words(title: "Your move", why: "Because", instructions: "How", answers: "Keys")
end

defmodule Shop.Delegated do
  @moduledoc "What to do, for whoever the environment configures as the approver (`config`)."
  use Shop.Composition,
    name: "shop-delegated",
    concepts: Shop.Base.concepts() ++ [Shop.Card, Shop.Runs, Shop.Flows.Delegated],
    subflows: [Shop.Flows.Delegated]
end

defmodule Shop.Answering do
  @moduledoc "The owner's answers: approve sets checked_by; send back removes it."
  use Shop.Composition,
    name: "shop-answering",
    concepts: Shop.Base.concepts() ++ [Shop.Card, Shop.Runs, Shop.Flows.Answered],
    subflows: [Shop.Flows.Answered]

  todo_words(title: "Your move", why: "Because", instructions: "How", answers: "Keys")
  extend_relation(:checked_by, actions: [set: [label: "Check", key: "v"]])
end

defmodule Shop.Reviewed do
  @moduledoc """
  A subflow reviews each widget: in its check state the card's holder accepts or rejects
  (with a note); a change that sets a deciding state names its writer as the one who
  decides.
  """
  use Shop.Composition,
    name: "shop-reviewed",
    concepts: [
      Shop.DecidedWidget,
      Shop.Part,
      Shop.Tag,
      Shop.Member,
      Shop.Links,
      Shop.Card,
      Shop.Runs
    ],
    subflows: [AtlasControl.Shop.DecidedWidget]

  todo_words(title: "Your move", why: "Because", instructions: "How", answers: "Keys")
  extend_relation(:checked_by, actions: [set: [label: "Check", key: "v"]])

  acl(comment: "The shop's flow.")
  role("shop-flow", read: ["*"], update: [:widget, :run])
  role("checker", read: ["*"], update: [:widget])
  assign("system:shop", "shop-flow")
end

defmodule Shop.CheckedOpen do
  @moduledoc "What is checked by the client is its start page; open work is that for everyone."
  use Shop.Composition, name: "shop-checked-open", concepts: Shop.Base.concepts()

  start_page(
    assigned: [relation: :checked_by, title: "Assigned"],
    open: [title: "Open work", empty: "Nothing open"]
  )
end

defmodule Shop.Kept do
  @moduledoc "A dark shade is decided by who checked the widget; a widget is never deleted."
  use Shop.Composition,
    name: "shop-kept",
    concepts: [Shop.SteppedWidget, Shop.Part, Shop.Tag, Shop.Member, Shop.Links]
end

defmodule Shop.Console do
  @moduledoc "The shop's native shell: widgets, then parts."
  use Shop.Composition, name: "shop-console", concepts: Shop.Base.concepts()

  shell(
    title: "Private Console",
    tabs: [
      [id: "widgets", label: "Widgets", to: "/k/widget"],
      [id: "parts", label: "Parts", to: "/k/part"]
    ]
  )
end

defmodule Shop.Shelled do
  @moduledoc "The shop's native shell: parts, then widgets."
  use Shop.Composition, name: "shop-shelled", concepts: Shop.Base.concepts()

  shell(
    title: "Private Console",
    tabs: [
      [id: "parts", label: "Parts", to: "/k/part"],
      [id: "widgets", label: "Widgets", to: "/k/widget"]
    ]
  )
end

defmodule Shop.ShelledParts do
  @moduledoc "A shell with the parts' tab alone."
  use Shop.Composition, name: "shop-shelled-parts", concepts: Shop.Base.concepts()
  shell(title: "Private Console", tabs: [[id: "parts", label: "Parts", to: "/k/part"]])
end

defmodule Shop.ShelledAssigned do
  @moduledoc "A shell whose first tab is what is checked by the client."
  use Shop.Composition, name: "shop-shelled-assigned", concepts: Shop.Base.concepts()

  start_page(assigned: [relation: :checked_by])

  shell(
    title: "Private Console",
    tabs: [
      [id: "assigned", label: "Assigned", to: "/", assigned: true],
      [id: "parts", label: "Parts", to: "/k/part"],
      [id: "widgets", label: "Widgets", to: "/k/widget"]
    ]
  )
end

defmodule Shop.ShelledCards do
  @moduledoc "The shelled shop with cards."
  use Shop.Composition, name: "shop-shelled-cards", concepts: Shop.Base.concepts() ++ [Shop.Card]

  shell(
    title: "Private Console",
    tabs: [
      [id: "parts", label: "Parts", to: "/k/part"],
      [id: "widgets", label: "Widgets", to: "/k/widget"]
    ]
  )
end

defmodule Shop.ShelledKeepers do
  @moduledoc "The shelled shop with keepers: two kinds whose ids have no prefix."
  use Shop.Composition,
    name: "shop-shelled-keepers",
    concepts: Shop.Base.concepts() ++ [Shop.Keeper]

  shell(
    title: "Private Console",
    tabs: [
      [id: "parts", label: "Parts", to: "/k/part"],
      [id: "widgets", label: "Widgets", to: "/k/widget"]
    ]
  )
end

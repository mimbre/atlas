defmodule AtlasFlow.Packs do
  @moduledoc """
  Other versions of the depot's legacy flow `pack`, each compiled by itself
  (`RelaDSL.Flow.Legacy`), for the tests of what Flow does with a legacy flow.
  """

  @doc "The depot's `pack`, with `more` options (where it writes)."
  def pack(more \\ []) do
    [
      kinds: [:box],
      field: :todo,
      owner_relation: :owned_by,
      states: [
        [name: :done, when: [completed: true], done: true],
        [
          name: :again,
          when: [reopened: :signed_by],
          owner: [kind: :clerk, key: "bob"],
          expected: "Again: {note}",
          why: "taken back",
          next: [:packing, :done]
        ],
        [
          name: :check,
          when: [progress: :check],
          owner: [kind: :clerk, key: "ada"],
          expected: "Check it",
          why: "all in it is packed",
          next: [:done]
        ],
        [
          name: :packing,
          owner: [kind: :clerk, key: "bob"],
          expected: "Pack it",
          why: "not all in it is packed",
          next: [:check]
        ]
      ]
    ] ++ more
  end
end

defmodule AtlasFlow.Packs.Checked do
  @moduledoc "Checked by the actor the environment configures as its checker (`config`)."
  use RelaDSL.Flow.Legacy,
    name: :pack,
    behaviour: AtlasFlow.Legacy,
    flow:
      Keyword.update!(AtlasFlow.Packs.pack(), :states, fn states ->
        for state <- states,
            do:
              if(state[:name] == :check,
                do: Keyword.put(state, :owner, kind: :clerk, config: :checker),
                else: state
              )
      end)
end

defmodule AtlasFlow.Packs.Later do
  @moduledoc "Defers a handover while the owner's turn runs (`handover_field`)."
  use RelaDSL.Flow.Legacy,
    name: :pack,
    behaviour: AtlasFlow.Legacy,
    flow: AtlasFlow.Packs.pack(handover_field: :later)
end

defmodule AtlasFlow.Packs.Carded do
  @moduledoc "Writes on the box's card, the fact its `on` relation points at."
  use RelaDSL.Flow.Legacy,
    name: :pack,
    behaviour: AtlasFlow.Legacy,
    flow: AtlasFlow.Packs.pack(on: :card)
end

defmodule AtlasFlow.Packs.Stepped do
  @moduledoc "Writes the state's name too (`state_field`)."
  use RelaDSL.Flow.Legacy,
    name: :pack,
    behaviour: AtlasFlow.Legacy,
    flow: AtlasFlow.Packs.pack(state_field: :step)
end

defmodule AtlasFlow.Packs.Labelled do
  @moduledoc "A sealed box waits until a tag labels it (an association that ends at it)."
  use RelaDSL.Flow.Legacy,
    name: :pack,
    behaviour: AtlasFlow.Legacy,
    flow: [
      kinds: [:box],
      field: :todo,
      owner_relation: :owned_by,
      states: [
        [
          name: :wait,
          when: [values: [sealed: [true]], empty: "labels"],
          owner: [kind: :clerk, key: "ada"],
          expected: "Label it: {notes}",
          why: "nothing labels it yet",
          next: [:done]
        ],
        [name: :done, when: [values: [sealed: [true]]], done: true],
        [
          name: :packing,
          owner: [kind: :clerk, key: "bob"],
          expected: "Pack it",
          next: [:wait]
        ]
      ]
    ]
end

defmodule AtlasFlow.Packs.Split do
  @moduledoc "Split while nothing is in the box."
  use RelaDSL.Flow.Legacy,
    name: :pack,
    behaviour: AtlasFlow.Legacy,
    flow: [kinds: [:box], states: [[name: :split, when: [empty: "in_box"]], [name: :packing]]]
end

defmodule AtlasFlow.Packs.Filled do
  @moduledoc "Filled with crates first, then packed, by the same clerk."
  use RelaDSL.Flow.Legacy,
    name: :pack,
    behaviour: AtlasFlow.Legacy,
    flow: [
      kinds: [:box],
      states: [
        [
          name: :fill,
          when: [empty: "in_box"],
          owner: [kind: :clerk, key: "ada"],
          expected: "Fill it with crates"
        ],
        [name: :packing, owner: [kind: :clerk, key: "ada"], expected: "Pack it"]
      ]
    ]
end

defmodule AtlasFlow.Packs.Noted do
  @moduledoc "What is expected names the box's own field and a note."
  use RelaDSL.Flow.Legacy,
    name: :pack,
    behaviour: AtlasFlow.Legacy,
    flow: [kinds: [:box], states: [[name: :label, expected: "Label it: {notes} ({note})"]]]
end

defmodule AtlasFlow.Packs.Reopened do
  @moduledoc "As `Noted`, in a state a removed signature reopens: its cause is the note."
  use RelaDSL.Flow.Legacy,
    name: :pack,
    behaviour: AtlasFlow.Legacy,
    flow: [
      kinds: [:box],
      states: [
        [name: :label, when: [reopened: :signed_by], expected: "Label it: {notes} ({note})"]
      ]
    ]
end

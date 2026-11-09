defmodule AtlasControl.Shop.Flow do
  @moduledoc false
  # A concept of the shop with one selected subflow `f` on widgets: it waits in its one
  # state (`state:`), owned as `owner:` says and presenting `present:`, until the widget
  # is done, and is presented as `projection:` says. Its runs are kept as the shop keeps
  # them (`AtlasControl.Shop.Runs`, which a composition selects with it).
  defmacro __using__(opts) do
    state = Keyword.fetch!(opts, :state)

    quote do
      use RelaDSL

      subflow :f, label: "F", subject: :widget do
        owner(unquote(Keyword.fetch!(opts, :owner)))
        start(:create)
        initial(unquote(state))

        state unquote(state), label: unquote(to_string(state)) do
          present(unquote(Keyword.fetch!(opts, :present)))
          branch(to: :done, when: "entity.done == true")
        end

        final(:done, label: "Done")
      end

      select(:f,
        choices: [],
        projection: unquote(Keyword.fetch!(opts, :projection)),
        admission: [],
        imports: []
      )
    end
  end
end

defmodule AtlasControl.Shop.Flows.Kept do
  @moduledoc "Widgets are kept by a keeper."
  use AtlasControl.Shop.Flow,
    owner: [default: {:keeper, :desk}],
    state: :open,
    present: [expected: "Keep it"],
    projection: [field: :shade]
end

defmodule AtlasControl.Shop.Flows.Painted do
  @moduledoc "Ada paints each widget; the work is written on its card."
  use AtlasControl.Shop.Flow,
    owner: [via: :card, relation: :held_by, default: {:member, :ada}],
    state: :open,
    present: [expected: "Paint it"],
    projection: [on: :card, field: :todo]
end

defmodule AtlasControl.Shop.Flows.Checked do
  @moduledoc "Ada checks each painted widget, with what to do; its state is the card's step."
  use AtlasControl.Shop.Flow,
    owner: [via: :card, relation: :held_by, default: {:member, :ada}],
    state: :check,
    present: [
      expected: "Check it",
      why: "it is painted",
      instructions: "Look it over.",
      section: [field: :notes, heading: "Check"],
      answers: [[key: "a", label: "Approve", set: :checked_by]]
    ],
    projection: [on: :card, field: :todo, state_field: :step, owner_relation: :held_by]
end

defmodule AtlasControl.Shop.Flows.Delegated do
  @moduledoc "Whoever the environment configures as the approver checks each widget."
  use AtlasControl.Shop.Flow,
    owner: [via: :card, relation: :held_by, default: {:member, config: :approver}],
    state: :check,
    present: [expected: "Check it", why: "it is painted"],
    projection: [on: :card, field: :todo, state_field: :step, owner_relation: :held_by]
end

defmodule AtlasControl.Shop.Flows.Answered do
  @moduledoc "Ada checks each widget: approve sets checked_by, send back removes it."
  use AtlasControl.Shop.Flow,
    owner: [via: :card, relation: :held_by, default: {:member, :ada}],
    state: :check,
    present: [
      expected: "Check it",
      answers: [
        [key: "v", label: "Approve", set: :checked_by],
        [key: "z", label: "Send back", remove: :checked_by]
      ]
    ],
    projection: [on: :card, field: :todo, state_field: :step, owner_relation: :held_by]
end

defmodule AtlasBFFContract.Blocks do
  @moduledoc """
  Control's block catalogue: what Control sends and every client renders.

  Blocks know nothing of what they show. Control fills them from rela's description and
  facts; a client renders them without knowing any kind of fact.
  """

  defmacro __using__(_opts) do
    quote do
      # A list inside a section may leave its title to the section.
      defblock :list do
        field :title, :string
        field :rows, {:list, :row}, required: true
        field :empty, :string
        field :actions, {:list, :action}
      end

      # The groups a page's items fall into, each a filter of the page: opening a group's
      # `to` shows only that group's items, with the same groups, that one `active`. A
      # client shows them as it likes (a filter row, a sidebar's sub-items), never per group.
      defblock :groups do
        field :groups, {:list, :group}, required: true
      end

      defblock :item do
        field :title, :string, required: true
        field :fields, {:list, :pair}, required: true
        field :actions, {:list, :action}
        field :links, {:list, :link}
      end

      defblock :single_choice do
        field :question, :string, required: true
        field :options, {:list, :choice_option}, required: true
        field :recommended, :string, required: true
        field :rationale, :string, required: true
        field :revision, :string, required: true
        field :instructions, :string
      end

      # What its owner is to do, step by step (a to-do's instructions): `title` the work in
      # a few words, `why` the lead paragraph (without its "Why:"), `since` when it came
      # to them (ISO 8601, UTC), the steps in order and the one they are at (`current`,
      # from 1). A client shows the steps before `current` as done, that one open with its
      # commands, which it may copy, and the later ones closed. `actions` move the current
      # step (`submit_to` sets it) and answer the to-do, each on its key.
      defblock :steps do
        field :title, :string, required: true
        field :why, :string
        field :since, :string
        field :steps, {:list, :instruction_step}, required: true
        field :current, :integer, required: true
        field :actions, {:list, :action}
      end

      # Submitting sends the inputs' values to the endpoint `submit_to` names.
      defblock :form do
        field :title, :string, required: true
        field :inputs, {:list, :input}, required: true
        field :submit_label, :string, required: true
        field :submit_to, :call, required: true
        field :cancel_to, :string
        field :errors, {:list, :string}
      end

      # A question before something that cannot be undone. Without `confirm_to` it only
      # explains why the thing cannot be done.
      defblock :confirm do
        field :title, :string, required: true
        field :text, :string, required: true
        field :confirm_label, :string
        field :confirm_to, :call
        field :cancel_to, :string, required: true
        # Optional failure code from Facts; never inferred from the human explanation.
        field :code, :string
      end

      # What an agent proposes for a request, and then does: its steps, in order. `state` is
      # planning, proposed, running, done, stopped, failed or cancelled. The user keeps,
      # edits or drops each proposed step before any of it runs. `before` says what became
      # of the previous plan for the same request, when this one follows a refusal.
      defblock :plan do
        field :title, :string, required: true
        field :request, :string, required: true
        field :state, :string, required: true
        field :summary, :string
        field :by, :string
        field :before, :string
        field :steps, {:list, :step}, required: true
      end

      defblock :console_action do
        field :label, :string, required: true
        field :keys, {:list, :string}, required: true
        field :operation, :console_operation, required: true
        field :scope, :console_scope, required: true
        field :available, :boolean, required: true
        field :reason, :string
      end
    end
  end
end

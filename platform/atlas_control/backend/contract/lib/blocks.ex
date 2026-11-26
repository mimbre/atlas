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

      # `key`: the fact the choice is about, which a client shows beside the question.
      defblock :single_choice do
        field :question, :string, required: true
        field :options, {:list, :choice_option}, required: true
        field :recommended, :string, required: true
        field :rationale, :string, required: true
        field :revision, :string, required: true
        field :instructions, :string
        field :key, :string
      end

      # A page's own heading, the first of a stack of simple blocks: what is asked of
      # the viewer (`eyebrow`: "TO DO FOR YOU"), the fact's `key` and the `title`.
      defblock :header do
        field :title, :string, required: true
        field :eyebrow, :string
        field :key, :string
      end

      # A paragraph: its `text`, after its `label` ("Why"), and with `since` (ISO 8601,
      # UTC) how long ago that was, which a client shows after the text ("· 3h ago") and
      # keeps current.
      defblock :text do
        field :text, :string, required: true
        field :label, :string
        field :since, :string
      end

      # One numbered step of instructions (a to-do's): its number `n` (from 1) and its
      # lines in the order written: text, commands (each a line to run as it is, which a
      # client lets the user copy) and routes. A client shows every step in full, each the
      # same, one under the other.
      defblock :instruction do
        field :n, :integer, required: true
        field :lines, {:list, :instruction_line}, required: true
      end

      # What the viewer can answer, in Control's order, each on its key (and the page's
      # More…); `note`: the answer asks a note.
      defblock :answers do
        field :answers, {:list, :panel_answer}, required: true
      end

      # Where its owner decides, as a panel: `heading` (what is asked of them: "TO
      # ACCEPT"), `title`, `key` (the fact's, shown beside the title), `aside` (beside the
      # title: "3 items"), the `byline`; what it is
      # judged on: `items` (a client selects one and shows its details), `checks`, a `box`;
      # then its `answers` in Control's order, each the page's action of the same key.
      # `choose`: the answers are a choice, one selected (the recommended one first) and
      # answered at once, its detail shown. `actions` and `links` open what it refers to.
      defblock :panel do
        field :heading, :string, required: true
        field :title, :string, required: true
        field :key, :string
        field :aside, :string
        field :byline, {:list, :clause}
        field :items, {:list, :panel_item}
        field :checks, {:list, :check}
        field :box, :box
        field :answers, {:list, :panel_answer}
        field :choose, :boolean
        field :actions, {:list, :action}
        field :links, {:list, :link}
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

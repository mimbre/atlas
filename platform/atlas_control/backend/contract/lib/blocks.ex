defmodule AtlasBFFContract.Blocks do
  @moduledoc """
  Control's block catalogue: what Control sends and every client renders.

  Blocks know nothing of what they show. Control fills them from rela's description and
  facts; a client renders them without knowing any kind of fact.
  """

  defmacro __using__(_opts) do
    quote do
      # A list may leave its title to its section, or show progress beside its own title.
      defblock :list do
        field :title, :string, intent: :title
        field :rows, {:list, :row}, required: true
        field :empty, :string, intent: :body
        field :actions, {:list, :action}
        field :aside, :string, intent: :label
      end

      # The groups a page's items fall into, each a filter of the page: opening a group's
      # `to` shows only that group's items, with the same groups, that one `active`. A
      # client shows them as it likes (a filter row, a sidebar's sub-items), never per group.
      defblock :groups do
        field :groups, {:list, :group}, required: true
      end

      defblock :item do
        field :title, :string, intent: :title, required: true
        field :fields, {:list, :pair}, required: true
        field :actions, {:list, :action}
        field :links, {:list, :link}
      end

      # A page's heading: its eyebrow, key, icon and title, with an optional state
      # detail and its ISO 8601 UTC timestamp for a current age beneath the title.
      defblock :header do
        field :title, :string, intent: :title, required: true
        field :eyebrow, :string, intent: :label
        field :key, :string
        field :icon, :string
        field :detail, :string, intent: :body
        field :since, :string
      end

      # A paragraph: its `text`, after its `label` when it has one (an intro paragraph has none), and with `since` (ISO 8601,
      # UTC) how long ago that was, which a client shows after the text ("· 3h ago") and
      # keeps current. `role` error: something went wrong (what a client shows in Prism's
      # error, a tinted card or a red frame).
      # `syntax` markdown opts into Markdown; absent or unknown syntaxes are plain text.
      defblock :text do
        field :text, :string, intent: :body, syntax: :markdown, required: true
        field :syntax, :string
        field :label, :string, intent: :label
        field :since, :string
        field :role, :string
      end

      # One numbered step of instructions (a to-do's): its number `n` (from 1) and its
      # lines in the order written: text, commands (each a line to run as it is, which a
      # client lets the user copy) and routes. A client shows every step in full, each the
      # same, one under the other.
      defblock :instruction do
        field :n, :integer, required: true
        field :lines, {:list, :instruction_line}, required: true
      end

      # What the viewer can answer, in Control's order, each on its key; `note`: the
      # answer asks a note.
      defblock :answers do
        field :answers, {:list, :panel_answer}, required: true
      end

      # What else can be done with the page's subject (change it, hand it over, delete it,
      # create something under it), each on its key, in Control's order: below its
      # answers, quieter than they are. One that is dangerous opens its confirm first.
      defblock :actions do
        field :actions, {:list, :action}, required: true
      end

      # One adopt option of a decision, one block per option in Control's order (the
      # recommended one first): its number `n` (from 1), its `text`, a `badge` in its
      # `tone` (success: "★ Recommended"), what it means (`fields`: its Rule and what
      # follows Then) and its own `answer`, the page's action of the same key. Since 0.38.0
      # a decline is no option block but the page's decline answer (Decline, Decline all)
      # in the `answers` block below. `alone`: the only proposal; its answer is that
      # block's Accept, so a client shows no answer on the card.
      defblock :option do
        field :n, :integer, required: true
        field :text, :string, intent: :body, required: true
        field :badge, :string, intent: :label
        field :tone, :string
        field :fields, {:list, :pair}, required: true
        field :answer, :panel_answer, required: true
        field :alone, :boolean
      end

      # Where its owner decides, as a panel: `heading` (what is asked of them: "TO
      # ACCEPT"), `title`, `key` (the fact's, shown beside the title), `aside` (beside the
      # title: "3 items"), the `byline`; what it is
      # judged on: `items` (a client selects one and shows its details), `checks`, a `box`;
      # then its `answers` in Control's order, each the page's action of the same key.
      # `actions` and `links` open what it refers to. `icon`: the icon of the fact's kind
      # (as on its rows), shown with the heading.
      defblock :panel do
        field :heading, :string, intent: :title, required: true
        field :title, :string, intent: :title, required: true
        field :key, :string
        field :aside, :string, intent: :label
        field :icon, :string
        field :byline, {:list, :clause}
        field :items, {:list, :panel_item}
        field :checks, {:list, :check}
        field :box, :box
        field :answers, {:list, :panel_answer}
        field :actions, {:list, :action}
        field :links, {:list, :link}
      end

      # Submitting sends the inputs' values to the endpoint `submit_to` names.
      defblock :form do
        field :title, :string, intent: :title, required: true
        field :inputs, {:list, :input}, required: true
        field :submit_label, :string, intent: :label, required: true
        field :submit_to, :call, required: true
        field :cancel_to, :string
        field :errors, {:list, :string}, intent: :body
      end

      # A question before something that cannot be undone. Without `confirm_to` it only
      # explains why the thing cannot be done.
      defblock :confirm do
        field :title, :string, intent: :title, required: true
        field :text, :string, intent: :body, required: true
        field :confirm_label, :string, intent: :label
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
        field :title, :string, intent: :title, required: true
        field :request, :string, intent: :body, required: true
        field :state, :string, required: true
        field :summary, :string, intent: :body
        field :by, :string
        field :before, :string, intent: :body
        field :steps, {:list, :step}, required: true
      end

      defblock :console_action do
        field :label, :string, intent: :label, required: true
        field :keys, {:list, :string}, required: true
        field :operation, :console_operation, required: true
        field :scope, :console_scope, required: true
        field :available, :boolean, required: true
        field :reason, :string, intent: :body
      end
    end
  end
end

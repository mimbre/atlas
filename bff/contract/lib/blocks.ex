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

      defblock :item do
        field :title, :string, required: true
        field :fields, {:list, :pair}, required: true
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

      defmarkup :legend do
        field :title, :string, required: true
        field :context, :string, required: true
      end

      # Markup: kinds that cover a stretch of a view model's blocks. All markup nests, of
      # every kind; see AtlasBFF.Markup in the generator. Markup says what a stretch means,
      # never how it looks: each client decides the layout (boxes, columns, tabs) itself.
      # Ask of every new kind: does it name a meaning, or an appearance?

      # A top-level division of a view, with its title. `role` says what it holds: `main`
      # (the item itself), `related` (what it links to) or `todo` (what its owner is to do,
      # shown to the owner only, first). Parts do not nest in parts; sections nest in parts.
      defmarkup :part do
        field :title, :string, required: true
        field :role, :string, required: true
      end

      # A titled stretch of the view; a client may let the user fold a collapsible one.
      defmarkup :section do
        field :title, :string, required: true
        field :collapsible, :boolean
      end

      # The blocks marked, in a tone: info, ok, error or pending.
      defmarkup :highlight do
        field :tone, :string, required: true
      end
    end
  end
end

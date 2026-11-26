defmodule AtlasBFFContract.Markup do
  @moduledoc """
  Control's kinds of markup: what a stretch of a view model's blocks means.
  """

  defmacro __using__(_opts) do
    quote do
      defmarkup :legend do
        field :title, :string, required: true
        field :context, :string, required: true
      end

      # Markup: kinds that cover a stretch of a view model's blocks. All markup nests, of
      # every kind; see AtlasBFF.Markup in the generator. Markup says what a stretch means,
      # never how it looks: each client decides the layout (boxes, columns, tabs) itself.
      # Ask of every new kind: does it name a meaning, or an appearance?

      # A top-level division of a view, with its title. `role` says what it holds: `main`
      # (the item itself), `related` (what it links to), `todo` (what its owner is to do,
      # shown to the owner only, first) or `details` (the item's facts, after what its owner
      # decides; the one part that may stand beside blocks in no part, as the page's last
      # stretch). Parts do not nest in parts; sections nest in parts.
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

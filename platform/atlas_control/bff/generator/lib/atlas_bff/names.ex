defmodule AtlasBFF.Names do
  @moduledoc """
  The names of a view model's parts, in one place: renaming one is changing it here
  (plus the `defmarkup` macro in `AtlasBFF.Schema` and the module `AtlasBFF.Markup`).
  """

  @doc "What Control sends a client: content and markup (d-0020)."
  def view_model, do: "view model"

  @doc "The function that builds or decodes one."
  def view_model_fun, do: :view_model

  @doc "The layer of entries over stretches of blocks, and its key on the wire."
  def markup, do: "markup"
end

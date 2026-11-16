defmodule RelaDSL.Problem do
  @moduledoc """
  One mistake a check finds in a model: `tag` says what is wrong, `names` what it is
  about (kinds, fields, relations, roles, values, as the model names them), and `text`
  how a person reads it. A composition refuses with the text, at the file and line that
  wrote the mistake; a test compares the tag and the names, never the text.
  """

  @enforce_keys [:tag, :names, :text]
  defstruct [:tag, :names, :text]

  @type t :: %__MODULE__{tag: atom, names: [term], text: String.t()}

  @doc "A problem `tag` about `names`, read as `text`."
  def new(tag, names, text) when is_atom(tag) and is_list(names) and is_binary(text),
    do: %__MODULE__{tag: tag, names: names, text: text}

  @doc "The problem with `prefix` before its text (what it is a problem of)."
  def prefix(%__MODULE__{} = p, prefix), do: %{p | text: prefix <> p.text}

  @doc "Tag and names: what a test compares."
  def key(%__MODULE__{tag: tag, names: names}), do: {tag, names}

  defimpl String.Chars do
    def to_string(p), do: p.text
  end
end

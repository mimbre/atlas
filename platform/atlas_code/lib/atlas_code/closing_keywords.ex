defmodule AtlasCode.ClosingKeywords do
  @moduledoc """
  Keeps a pull request description from closing other pull requests or issues when it is
  merged into the default branch (IS-Atlas-136).

  GitHub closes an issue or pull request when a merged pull's description puts a closing
  keyword (close, closes, closed, fix, fixes, fixed, resolve, resolves, resolved, in any case,
  optionally followed by a colon) before a reference: `#n`, `owner/repo#n` or the web address
  of an issue or pull. `defuse/1` puts the reference in parentheses, so the keyword no longer
  stands right before it: GitHub ignores it, a person still reads (and GitHub still links) the
  reference. "fixes #12" becomes "fixes (#12)", "closed #512/#514" becomes
  "closed (#512/#514)"; "see #12" is left alone, and so is a text already defused.

  Every pull request body Atlas writes goes through it: Code's publication body and the
  review an orchestrator asks Code to open. Agents that write a body themselves run it
  through the same function with `mix atlas_code.pr_body` (see its documentation).
  """

  @reference ~S"(?:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#\d+|https?://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/(?:issues|pull)/\d+"
  @closing Regex.compile!(
             ~S"\b(close[sd]?|fix(?:e[sd])?|resolve[sd]?)(:?)(\s+)((?:" <>
               @reference <> ~S")(?:\s*[/,&]\s*(?:" <> @reference <> "))*)",
             "iu"
           )

  @doc "The text with every closing keyword's reference put out of its reach."
  @spec defuse(String.t()) :: String.t()
  def defuse(text) when is_binary(text),
    do: Regex.replace(@closing, text, "\\1\\2\\3(\\4)")

  @doc "How many closing references GitHub would act on the text holds."
  @spec count(String.t()) :: non_neg_integer()
  def count(text) when is_binary(text), do: length(Regex.scan(@closing, text))

  @doc "Whether the text still holds a closing reference GitHub would act on."
  @spec closing?(String.t()) :: boolean()
  def closing?(text) when is_binary(text), do: Regex.match?(@closing, text)
end

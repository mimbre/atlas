defmodule AtlasLearn.Observations do
  @moduledoc """
  The kinds of observation Learn v1 makes, one module each. An observation reads one source
  through that source's own read surface and returns an `AtlasLearn.Observations` map:

    * `name`: what is observed, for the report;
    * `source`: where it was read, in words;
    * `status`: `:read`, `:not_asked` (the caller gave no source) or `{:unavailable, why}`;
    * `records`: the records in the window, each with an `id` patterns cite;
    * `context`: records outside the window a pattern needs (a follow-up chain's start);
    * `notes`: what this source could not tell.
  """

  @doc "Observation modules by their option key, in report order."
  def all,
    do: [
      worker_passes: AtlasLearn.Observations.WorkerPasses,
      code_changes: AtlasLearn.Observations.CodeChanges,
      decisions: AtlasLearn.Observations.Decisions
    ]

  @doc "An observation that could not read its source."
  def unavailable(name, source, why, notes \\ []),
    do: %{
      name: name,
      source: source,
      status: {:unavailable, why},
      records: [],
      context: [],
      notes: notes
    }

  def not_asked(name, why),
    do: %{name: name, source: why, status: :not_asked, records: [], context: [], notes: []}

  @doc "The first line of a text, cut at `limit` characters; nil stays nil."
  def excerpt(text, limit \\ 160)
  def excerpt(nil, _limit), do: nil
  def excerpt(text, limit) when not is_binary(text), do: excerpt(JSON.encode!(text), limit)

  def excerpt(text, limit) do
    line = text |> String.trim() |> String.split("\n", parts: 2) |> hd()
    if String.length(line) > limit, do: String.slice(line, 0, limit) <> "…", else: line
  end
end

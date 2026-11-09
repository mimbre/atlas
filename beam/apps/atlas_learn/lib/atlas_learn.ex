defmodule AtlasLearn do
  @moduledoc """
  Learn, version 1: once a day the coordinator asks what happened in a window (24 hours by
  default). Learn observes the window through the read surfaces the other components already
  have, finds deterministic patterns in it and writes one markdown report.

  Learn has no store and no entities of its own, calls no model and applies nothing: the
  report is evidence for the operator or the coordinator to act on through the normal flow.

  Each observation is asked separately and says itself whether its source could be read, so
  one unreachable source never hides what the others saw.
  """
  alias AtlasLearn.{Observations, Patterns, Report, Window}

  @doc """
  Observe the window, find patterns and write the report to `opts[:out]`.

  Options: `out` (required), `until` (a `DateTime`, required), `hours` (default 24) and,
  per observation, its own options: `worker_passes`, `code_changes`, `decisions` (see each
  module in `AtlasLearn.Observations`). Returns `{:ok, path, patterns}`.
  """
  def run(opts) do
    out = Keyword.fetch!(opts, :out)
    window = Window.ending(Keyword.fetch!(opts, :until), Keyword.get(opts, :hours, 24))
    observations = observe(window, opts)
    patterns = Patterns.find(observations, window)
    File.mkdir_p!(Path.dirname(out))
    File.write!(out, Report.render(window, observations, patterns))
    {:ok, out, patterns}
  end

  @doc "Every v1 observation of `window`, in report order."
  def observe(window, opts) do
    for {key, module} <- Observations.all(),
        do: module.observe(window, Keyword.get(opts, key, []))
  end
end

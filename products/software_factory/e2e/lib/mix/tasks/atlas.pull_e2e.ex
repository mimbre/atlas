defmodule Mix.Tasks.Atlas.PullE2e do
  @shortdoc "The pull-e2e: the go-live gate's end-to-end test (never in CI)"
  @moduledoc """
      bin/atlas-dev pull-e2e [s1 s5 ...]          # the way to run it (pull/run.sh makes <run>)
      mix atlas.pull_e2e --prepare                 # compile into the warm cache (before the timed run)
      mix atlas.pull_e2e --run <run> [s1 ...]      # what the wrapper runs, in <run>
      mix atlas.pull_e2e --reap <run> [--fast]     # stop and prove gone what <run> started

  The real Runtime puller, started without Mix, against Flow's real work source with real
  Facts and Code test instances and a stub agent (`products/software_factory/e2e/pull/README.md`).
  It runs only when asked: no `mix test` starts it and no CI job names it. Exit codes:
  0 passed · 1 a scenario failed · 3 watchdog · 4 environment_too_slow · 5 the reap's proof
  failed · 6 incomplete (a scenario needs a package this tree lacks, e.g. D2).
  """
  use Mix.Task

  alias AtlasE2E.Pull.{Bench, Run}

  @impl true
  def run(args) do
    {opts, filters, invalid} =
      OptionParser.parse(args,
        strict: [run: :string, reap: :string, fast: :boolean, prepare: :boolean, cache: :string]
      )

    cond do
      invalid != [] or (opts[:run] == nil and opts[:reap] == nil and opts[:prepare] == nil) ->
        Mix.raise(
          "usage: mix atlas.pull_e2e --prepare [--cache <dir>] | --run <run> [scenario ...] | --reap <run> [--fast] (or bin/atlas-dev pull-e2e)"
        )

      opts[:prepare] ->
        Mix.Task.run("app.start")
        AtlasE2E.Pull.Prepare.run(opts[:cache] || AtlasE2E.Pull.Prepare.default_cache())
        System.halt(0)

      run = opts[:reap] ->
        reap(run, Keyword.get(opts, :fast, false))

      run = opts[:run] ->
        Mix.Task.run("app.start")
        _ = AtlasFacts.Trust.load()
        System.halt(Run.main(Path.expand(run), filters, cache: opts[:cache]))
    end
  end

  # The wrapper's trap: KILL only (fast), then the proof. A run already reaped proves again.
  defp reap(run, fast) do
    run = Path.expand(run)

    unless File.dir?(run) do
      IO.puts("pull-e2e reap: #{run} is gone; nothing to reap")
      System.halt(0)
    end

    result = Bench.reap(run, fast: fast)

    # The test BEAM did not get to its own end (a signal, the watchdog, a crash): what is
    # worth reading is kept, then the run folder goes.
    Bench.keep(
      run,
      Run.artifacts(run),
      "reaped",
      "reaped by the wrapper (#{if fast, do: "fast", else: "graceful"})\n"
    )

    File.rm_rf!(run)

    case result do
      {:ok, _} -> System.halt(0)
      {:error, _} -> System.halt(5)
    end
  end
end

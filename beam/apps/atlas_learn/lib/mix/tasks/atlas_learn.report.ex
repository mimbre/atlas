defmodule Mix.Tasks.AtlasLearn.Report do
  @shortdoc "Writes Learn's report for the last window (24 hours by default)"
  @moduledoc """
  Observes a window, finds Learn's deterministic patterns and writes the markdown report.
  The coordinator runs it once a day:

      cd beam/apps/atlas_learn && mix atlas_learn.report --out /abs/report.md --env test \\
        [--hours 24] [--until 2026-11-11T06:00:00Z] \\
        [--runtime-home DIR] [--code-home DIR] [--decision-kind KIND] [--atlas EXECUTABLE]

  `--env` (`test` or `prod`) is the environment whose Control the `atlas` client reads.
  The Runtime home defaults to `ATLAS_RUNTIME_HOME`, the Code home to `ATLAS_CODE_HOME`; a
  source that is not given is reported as not asked. It prints the report's path.
  """
  use Mix.Task

  @switches [
    out: :string,
    env: :string,
    hours: :integer,
    until: :string,
    runtime_home: :string,
    code_home: :string,
    decision_kind: :string,
    atlas: :string
  ]

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [],
      do: Mix.raise("Unknown arguments: #{inspect(rest ++ invalid)}")

    out = opts[:out] || Mix.raise("Give --out PATH for the report")
    env = opts[:env]
    if env not in ["test", "prod"], do: Mix.raise("Give --env test or --env prod")

    until =
      case opts[:until] do
        nil -> DateTime.utc_now()
        text -> AtlasLearn.Window.moment(text) || Mix.raise("--until must be ISO 8601")
      end

    # Not app.start: the umbrella's runtime.exs belongs to the core and Runtime nodes.
    Mix.Task.run("compile")

    {:ok, path, _patterns} =
      AtlasLearn.run(
        out: Path.expand(out),
        until: until,
        hours: opts[:hours] || 24,
        worker_passes: [runtime_home: opts[:runtime_home] || System.get_env("ATLAS_RUNTIME_HOME")],
        code_changes: [code_home: opts[:code_home] || System.get_env("ATLAS_CODE_HOME")],
        decisions: [kind: opts[:decision_kind], env: env, atlas: opts[:atlas]]
      )

    IO.puts(path)
  end
end

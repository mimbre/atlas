defmodule Mix.Tasks.Atlas.Fixtures do
  @shortdoc "Stream schema-derived fixture combinations as JSON lines"
  @moduledoc """
  Run in the configured contract project, for example:

      mix atlas.fixtures --kind block --name item --offset 0 --limit 20

  `--kind` is block, markup or model. `--offset` defaults to 0, `--limit` to 20,
  and `--max-depth` to 8. Enumeration is lazy; large offsets still take time.
  """
  use Mix.Task
  @requirements ["compile"]

  @impl true
  def run(args) do
    {options, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          kind: :string,
          name: :string,
          offset: :integer,
          limit: :integer,
          max_depth: :integer
        ]
      )

    kind = %{"block" => :block, "markup" => :markup, "model" => :model}[options[:kind]]
    offset = options[:offset] || 0
    limit = options[:limit] || 20
    depth = options[:max_depth] || 8

    unless invalid == [] and rest == [] and not is_nil(kind) and is_binary(options[:name]) and
             options[:name] != "" and offset >= 0 and limit > 0 and depth >= 0 do
      Mix.raise("use --kind block|markup|model --name NAME [--offset N --limit N --max-depth N]")
    end

    contract =
      Application.get_env(:atlas_bff, :contract) || Mix.raise("no configured BFF contract")

    contract.__schema__()
    |> AtlasBFF.Targets.FixtureCombinations.stream(kind, options[:name], max_depth: depth)
    |> Stream.drop(offset)
    |> Stream.take(limit)
    |> Enum.each(&IO.puts(JSON.encode!(&1)))
  end
end

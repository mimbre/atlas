defmodule Mix.Tasks.RuntimeBoundary.Gen do
  @shortdoc "Generate the file targets of the configured boundary contracts"
  @moduledoc """
      mix runtime_boundary.gen           # write them
      mix runtime_boundary.gen --check   # fail when one is stale or left over (CI)

  Run in a contract's project, which configures its contract and file targets in its
  `mix.exs` project (design §1.2):

      def project do
        [
          ...,
          runtime_boundary: [
            contracts: [lending: MyContracts.Lending, reading: MyContracts.Reading],
            targets: [json: "../targets/json"],
            root: "../../../.."
          ]
        ]
      end

  `contracts` names each contract (a module that uses `AtlasRuntimeBoundary.Generator.Schema`)
  by the name of its files: `lending` writes `lending.json`, `reading` writes
  `reading.json`, each with a header naming its own contract file. Two contracts with one
  name, or two that would write the same file (a target's `name:` option with several
  contracts), are refused before anything is written. `targets` maps each file target to
  its folder, or to `{folder, options}`; every contract is written to every target.
  `root` (optional, default the project's folder) is what the header's path to the
  contract file is relative to.

  Without a `runtime_boundary` key the task reads the application config instead,
  `config :atlas_runtime_boundary_generator, contract: MyContracts.Lending, targets: ...,
  root: ...`, where the file's name is the module's last part in snake_case. That config
  takes one contract.

  The one file target is `json` (`AtlasRuntimeBoundary.Generator.Targets.Json`); its
  option `name:` overrides the file's name. The compile-time target
  `AtlasRuntimeBoundary.Generator.Targets.Boundary` writes no files.

  Every file starts with an `AtlasRuntimeBoundary.Generator.Header`. A file without
  exactly that header is hand-written and never overwritten. A file with it, in a target's
  folder, that no target writes any more for any contract (a renamed or removed one) is left
  over: the task removes it, and `--check` fails on it, as on a file that would change.
  """
  use Mix.Task

  alias AtlasRuntimeBoundary.Generator.Header

  @requirements ["compile"]
  @app :atlas_runtime_boundary_generator

  # Every file target has `files/2`: a contract's `__schema__/0` and the target's options
  # to `[{path, body}]`, paths relative to the target's folder.
  @targets %{json: AtlasRuntimeBoundary.Generator.Targets.Json}

  @impl true
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [check: :boolean])
    if rest != [], do: Mix.raise("unexpected argument #{Enum.join(rest, " ")}")

    config = config!()
    files = files!(config)

    stale = for {path, body} <- files, File.read(path) != {:ok, body}, do: path
    leftovers = leftovers(files, config.targets)

    cond do
      opts[:check] && (stale != [] or leftovers != []) ->
        Mix.raise(
          "out of date, run `mix runtime_boundary.gen`: " <>
            Enum.join(stale ++ Enum.map(leftovers, &"#{&1} (left over)"), ", ")
        )

      opts[:check] ->
        Mix.shell().info("generated files are up to date")

      true ->
        for path <- stale,
            File.exists?(path),
            not generated?(path),
            do: Mix.raise("#{path} has no generated header; it is not overwritten")

        for path <- leftovers do
          File.rm!(path)
          Mix.shell().info("removed #{path} (left over)")
        end

        for {path, body} <- files, path in stale do
          File.mkdir_p!(Path.dirname(path))
          File.write!(path, body)
          Mix.shell().info("wrote #{path}")
        end

        if stale == [] and leftovers == [], do: Mix.shell().info("generated files are up to date")
    end
  end

  # `[{path, body}]` of every contract in every target. Refuses two contracts writing one
  # path, before anything is written.
  defp files!(config) do
    files =
      for {name, contract} <- config.contracts,
          schema = contract.__schema__(),
          source = Path.relative_to(schema.file, Path.expand(config.root)),
          {target, dir, target_opts} <- config.targets,
          {path, body} <-
            Map.fetch!(@targets, target).files(schema, Keyword.put_new(target_opts, :name, name)),
          do: {name, Path.join(dir, path), Header.put(Path.extname(path), source, body)}

    for {path, names} <- Enum.group_by(files, &elem(&1, 1), &elem(&1, 0)),
        [_, _ | _] = names <- [Enum.uniq(names)] do
      Mix.raise("runtime_boundary: contracts #{Enum.join(names, " and ")} both write #{path}")
    end

    for {_name, path, body} <- files, do: {path, body}
  end

  # Files with the header, in a target's folder, that no target writes now for any contract
  # (once, also when one target's folder is inside another's).
  defp leftovers(files, targets) do
    written = Enum.map(files, &elem(&1, 0))

    for {_target, dir, _opts} <- targets,
        path <- Path.wildcard(Path.join(dir, "**/*")),
        File.regular?(path),
        path not in written,
        generated?(path),
        do: path,
        uniq: true
  end

  defp generated?(path), do: Header.generated?(Path.extname(path), File.read!(path))

  # `%{contracts: [{name, module}], targets: [{target, dir, opts}], root: dir}`, from the
  # project's `runtime_boundary` key, else from the application config.
  defp config! do
    case Mix.Project.config()[:runtime_boundary] do
      nil ->
        contracts =
          case Application.get_env(@app, :contract) do
            nil ->
              Mix.raise("no contract: set `runtime_boundary: [contracts: [name: MyContract]]`")

            module ->
              [{module |> Module.split() |> List.last() |> Macro.underscore(), module}]
          end

        %{
          contracts: contracts,
          targets: targets!(Application.get_env(@app, :targets, [])),
          root: Application.get_env(@app, :root, ".")
        }

      project ->
        unless Keyword.keyword?(project) and
                 Keyword.keys(project) -- [:contracts, :targets, :root] == [],
               do: Mix.raise("runtime_boundary: the keys are contracts:, targets: and root:")

        %{
          contracts: contracts!(project[:contracts]),
          targets: targets!(project[:targets] || []),
          root: project[:root] || "."
        }
    end
  end

  defp contracts!(contracts) do
    unless is_list(contracts) and contracts != [] and
             Enum.all?(
               contracts,
               &match?({name, module} when is_atom(name) and is_atom(module), &1)
             ),
           do:
             Mix.raise(
               "runtime_boundary: expected contracts: [name: Module], got #{inspect(contracts)}"
             )

    for {name, count} <- Enum.frequencies_by(contracts, &elem(&1, 0)), count > 1 do
      Mix.raise("runtime_boundary: two contracts are named #{name}")
    end

    for {name, module} <- contracts, do: {Atom.to_string(name), module}
  end

  defp targets!(targets) do
    for {target, _dir} <- targets, not Map.has_key?(@targets, target) do
      Mix.raise(
        "unknown target #{inspect(target)}; known: #{inspect(@targets |> Map.keys() |> Enum.sort())}"
      )
    end

    for {target, spec} <- targets do
      case spec do
        {dir, opts} when is_binary(dir) and is_list(opts) ->
          {target, dir, opts}

        dir when is_binary(dir) ->
          {target, dir, []}

        other ->
          Mix.raise(
            "target #{inspect(target)}: expected a folder or {folder, options}, got #{inspect(other)}"
          )
      end
    end
  end
end

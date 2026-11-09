defmodule Mix.Tasks.RuntimeBackend.Gen do
  @shortdoc "Generate the file targets of the configured backend contract"
  @moduledoc """
      mix runtime_backend.gen           # write them
      mix runtime_backend.gen --check   # fail when one is stale or left over (CI)

  Run in a contract's project, which configures its contract and file targets in its
  `mix.exs` project:

      def project do
        [
          ...,
          runtime_backend: [
            contracts: [lending: MyContracts.Lending],
            targets: [json: "../targets/rest"],
            root: "../../../.."
          ]
        ]
      end

  `contracts` names the contract (a module that uses `AtlasRuntimeBackend.Generator.Schema`)
  by the name of its files: `lending` writes `lending.json`. It takes exactly one
  contract per project. `targets` maps each file target to its folder, or to
  `{folder, options}`. `root` (optional, default the project's folder) is what the
  header's path to the contract file is relative to.

  Without a `runtime_backend` key the task reads the application config instead,
  `config :atlas_runtime_backend_generator, contract: MyContracts.Lending, targets: ...,
  root: ...`, where the file's name is the module's last part in snake_case.

  The one file target is `json` (`AtlasRuntimeBackend.Generator.Targets.Json`); its
  option `name:` overrides the file's name. `targets: []` writes nothing; `--check` then
  only compiles the contract. The compile-time target
  `AtlasRuntimeBackend.Generator.Targets.Rest` writes no files.

  Every file starts with an `AtlasRuntimeBackend.Generator.Header`. A file without
  exactly that header is hand-written and never overwritten. A file with it, in a target's
  folder, that no target writes any more (a renamed or removed one) is left over: the task
  removes it, and `--check` fails on it, as on a file that would change.
  """
  use Mix.Task

  alias AtlasRuntimeBackend.Generator.Header

  @requirements ["compile"]
  @app :atlas_runtime_backend_generator

  # Every file target has `files/2`: a contract's `__schema__/0` and the target's options
  # to `[{path, body}]`, paths relative to the target's folder.
  @targets %{json: AtlasRuntimeBackend.Generator.Targets.Json}

  @impl true
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [check: :boolean])
    if rest != [], do: Mix.raise("unexpected argument #{Enum.join(rest, " ")}")

    config = config!()
    {name, contract} = config.contract
    schema = contract.__schema__()
    source = Path.relative_to(schema.file, Path.expand(config.root))

    files =
      for {target, dir, target_opts} <- config.targets,
          {path, body} <-
            Map.fetch!(@targets, target).files(schema, Keyword.put_new(target_opts, :name, name)),
          do: {Path.join(dir, path), Header.put(Path.extname(path), source, body)}

    stale = for {path, body} <- files, File.read(path) != {:ok, body}, do: path
    leftovers = leftovers(files, config.targets)

    cond do
      opts[:check] && (stale != [] or leftovers != []) ->
        Mix.raise(
          "out of date, run `mix runtime_backend.gen`: " <>
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

  # Files with the header, in a target's folder, that no target writes now (once, also when
  # one target's folder is inside another's).
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

  # `%{contract: {name, module}, targets: [{target, dir, opts}], root: dir}`, from the
  # project's `runtime_backend` key, else from the application config.
  defp config! do
    case Mix.Project.config()[:runtime_backend] do
      nil ->
        contract =
          case Application.get_env(@app, :contract) do
            nil ->
              Mix.raise("no contract: set `runtime_backend: [contracts: [name: MyContract]]`")

            module ->
              {module |> Module.split() |> List.last() |> Macro.underscore(), module}
          end

        %{
          contract: contract,
          targets: targets!(Application.get_env(@app, :targets, [])),
          root: Application.get_env(@app, :root, ".")
        }

      project ->
        unless Keyword.keyword?(project) and
                 Keyword.keys(project) -- [:contracts, :targets, :root] == [],
               do: Mix.raise("runtime_backend: the keys are contracts:, targets: and root:")

        contract =
          case project[:contracts] do
            [{name, module}] when is_atom(name) and is_atom(module) ->
              {Atom.to_string(name), module}

            [_, _ | _] ->
              Mix.raise("runtime_backend: one contract per project (several come later)")

            other ->
              Mix.raise(
                "runtime_backend: expected contracts: [name: Module], got #{inspect(other)}"
              )
          end

        %{
          contract: contract,
          targets: targets!(project[:targets] || []),
          root: project[:root] || "."
        }
    end
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

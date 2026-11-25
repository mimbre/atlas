defmodule Mix.Tasks.RuntimeBackend.Gen do
  @shortdoc "Generate the file targets of the configured backend contracts"
  @moduledoc """
      mix runtime_backend.gen

  Run in a contract's project, which configures its contract and file targets in its
  `mix.exs` project:

      def project do
        [
          ...,
          runtime_backend: [
            contracts: [lending: MyContracts.Lending, desk: MyContracts.Desk],
            targets: [json: "../targets/rest"],
            root: "../../../.."
          ]
        ]
      end

  `contracts` names each contract (a module that uses `AtlasRuntimeBackend.Generator.Schema`)
  by the name of its files: `lending` writes `lending.json`, `desk` writes `desk.json`.
  Each file target writes every contract's files; a name given twice, or two contracts
  writing one path, fails before anything is written. `targets` maps each file target to its folder, or to
  `{folder, options}`; a target may be given more than once. The option `contracts:`
  (names from `contracts`) limits a target to those contracts, so one target can take
  other options per contract; it is not passed to the target, and a name no contract has
  fails. `root` (optional, default the project's folder) is what the header's path to the
  contract file is relative to.

  Without a `runtime_backend` key the task reads the application config instead,
  `config :atlas_runtime_backend_generator, contract: MyContracts.Lending, targets: ...,
  root: ...`, where the file's name is the module's last part in snake_case.

  The file targets are `json` (`AtlasRuntimeBackend.Generator.Targets.Json`, whose option
  `name:` overrides the file's name), `routes` (`...Targets.Routes`, `<name>/routes.json`)
  and `openapi` (`...Targets.Openapi`, `<name>/openapi.json`; options `security:`,
  `title:`): each contract's route description and OpenAPI document in a folder named
  after it.
  `targets: []` writes nothing. The compile-time target
  `AtlasRuntimeBackend.Generator.Targets.Rest` writes no files.

  Every file starts with an `AtlasRuntimeBackend.Generator.Header`. A file without
  exactly that header is hand-written and never overwritten. A file with it, in a target's
  folder, that no target writes any more (a renamed or removed one) is left over: the task
  removes it. Left over is judged against what all the contracts write, so removing a
  contract leaves its files over. The files are build output: they are not kept in git.
  """
  use Mix.Task

  alias AtlasRuntimeBackend.Generator.Header

  @requirements ["compile"]
  @app :atlas_runtime_backend_generator

  # Every file target has `files/2`: a contract's `__schema__/0` and the target's options
  # to `[{path, body}]`, paths relative to the target's folder.
  @targets %{
    json: AtlasRuntimeBackend.Generator.Targets.Json,
    routes: AtlasRuntimeBackend.Generator.Targets.Routes,
    openapi: AtlasRuntimeBackend.Generator.Targets.Openapi
  }

  @impl true
  def run(args) do
    if args != [], do: Mix.raise("unexpected argument #{Enum.join(args, " ")}")

    config = config!()

    files =
      for {name, contract} <- config.contracts,
          schema <- [contract.__schema__()],
          source <- [Path.relative_to(schema.file, Path.expand(config.root))],
          {target, dir, only, target_opts} <- config.targets,
          only == nil or name in only,
          {path, body} <-
            Map.fetch!(@targets, target).files(schema, Keyword.put_new(target_opts, :name, name)),
          do: {Path.join(dir, path), Header.put(Path.extname(path), source, body)}

    case Enum.map(files, &elem(&1, 0)) |> then(&(&1 -- Enum.uniq(&1))) do
      [] -> :ok
      [path | _] -> Mix.raise("runtime_backend: two contracts write #{path}")
    end

    stale = for {path, body} <- files, File.read(path) != {:ok, body}, do: path
    leftovers = leftovers(files, config.targets)

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

  # Files with the header, in a target's folder, that no target writes now (once, also when
  # one target's folder is inside another's).
  defp leftovers(files, targets) do
    written = Enum.map(files, &elem(&1, 0))

    for {_target, dir, _only, _opts} <- targets,
        path <- Path.wildcard(Path.join(dir, "**/*")),
        File.regular?(path),
        path not in written,
        generated?(path),
        do: path,
        uniq: true
  end

  defp generated?(path), do: Header.generated?(Path.extname(path), File.read!(path))

  # `%{contracts: [{name, module}], targets: [{target, dir, opts}], root: dir}`, from the
  # project's `runtime_backend` key, else from the application config (one contract).
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
          contracts: [contract],
          targets: targets!(Application.get_env(@app, :targets, []), [contract]),
          root: Application.get_env(@app, :root, ".")
        }

      project ->
        unless Keyword.keyword?(project) and
                 Keyword.keys(project) -- [:contracts, :targets, :root] == [],
               do: Mix.raise("runtime_backend: the keys are contracts:, targets: and root:")

        contracts =
          case project[:contracts] do
            [_ | _] = list ->
              unless Keyword.keyword?(list) and Enum.all?(list, fn {_, m} -> is_atom(m) end),
                do:
                  Mix.raise(
                    "runtime_backend: expected contracts: [name: Module, ...], got #{inspect(list)}"
                  )

              case Keyword.keys(list) -- Enum.uniq(Keyword.keys(list)) do
                [] -> :ok
                [name | _] -> Mix.raise("runtime_backend: contract #{name} is named twice")
              end

              for {name, module} <- list, do: {Atom.to_string(name), module}

            other ->
              Mix.raise(
                "runtime_backend: expected contracts: [name: Module, ...], got #{inspect(other)}"
              )
          end

        %{
          contracts: contracts,
          targets: targets!(project[:targets] || [], contracts),
          root: project[:root] || "."
        }
    end
  end

  defp targets!(targets, contracts) do
    for {target, _dir} <- targets, not Map.has_key?(@targets, target) do
      Mix.raise(
        "unknown target #{inspect(target)}; known: #{inspect(@targets |> Map.keys() |> Enum.sort())}"
      )
    end

    for {target, spec} <- targets do
      case spec do
        {dir, opts} when is_binary(dir) and is_list(opts) ->
          {only, opts} = Keyword.pop(opts, :contracts)
          {target, dir, only!(target, only, contracts), opts}

        dir when is_binary(dir) ->
          {target, dir, nil, []}

        other ->
          Mix.raise(
            "target #{inspect(target)}: expected a folder or {folder, options}, got #{inspect(other)}"
          )
      end
    end
  end

  # A target's `contracts:` option: the names (as text) of the contracts it writes, or nil
  # for all.
  defp only!(_target, nil, _contracts), do: nil

  defp only!(target, names, contracts) when is_list(names) do
    known = Enum.map(contracts, &elem(&1, 0))

    for name <- names do
      text = to_string(name)

      unless is_atom(name) and text in known,
        do:
          Mix.raise(
            "target #{inspect(target)}: contracts: names #{inspect(name)}; known: #{Enum.join(known, ", ")}"
          )

      text
    end
  end

  defp only!(target, other, _contracts),
    do:
      Mix.raise(
        "target #{inspect(target)}: expected contracts: [name, ...], got #{inspect(other)}"
      )
end

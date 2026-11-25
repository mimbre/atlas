defmodule Mix.Tasks.RuntimeModel.Gen do
  @shortdoc "Generate the file targets of the configured model contracts"
  @moduledoc """
      mix runtime_model.gen

  Run in a model contract's project, which configures its contracts and file targets:

      config :atlas_runtime_model_generator,
        contracts: [books: MyModel],
        targets: [json: "../targets/json"],
        root: "../../.."

  `contracts` names each contract (`AtlasRuntimeModel.Generator.Schema`); its file is
  named after it (`books.json`). `targets` maps each file target to its folder; `root`
  (optional, default the project's folder) is what the header's path to the contract
  file is relative to. The file target is `json` (`AtlasRuntimeModel.Generator.Targets.Json`).
  The compile-time target (`AtlasRuntimeModel.Generator.Targets.Model`) writes no files.

  Every file starts with an `AtlasRuntimeModel.Generator.Header`. A file without exactly
  that header is hand-written and never overwritten. A file with it, in a target's folder,
  that no target writes any more (a renamed or removed one) is left over: the task removes
  it. The files are build output: they are not kept in git.
  """
  use Mix.Task

  alias AtlasRuntimeModel.Generator.Header

  @requirements ["compile"]
  @app :atlas_runtime_model_generator

  # Every file target has `files/3`: a contract's name, its `__schema__/0` and the
  # target's options to `[{path, body}]`, paths relative to the target's folder.
  @targets %{json: AtlasRuntimeModel.Generator.Targets.Json}

  @impl true
  def run(args) do
    if args != [], do: Mix.raise("unexpected argument #{Enum.join(args, " ")}")

    root = Path.expand(Application.get_env(@app, :root, "."))
    targets = targets!()

    files =
      for {name, contract} <- contracts!(),
          schema = contract.__schema__(),
          source = Path.relative_to(source!(contract), root),
          {target, dir, target_opts} <- targets,
          {path, body} <- Map.fetch!(@targets, target).files(name, schema, target_opts),
          do: {Path.join(dir, path), Header.put(Path.extname(path), source, body)}

    stale = for {path, body} <- files, File.read(path) != {:ok, body}, do: path
    leftovers = leftovers(files, targets)

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

  # Files with the header, in a target's folder, that no target writes now.
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

  # The contract's source file, for the header; the schema shape does not carry it.
  defp source!(contract) do
    case contract.module_info(:compile)[:source] do
      source when is_list(source) -> List.to_string(source)
      _ -> Mix.raise("contract #{inspect(contract)}: its source file is unknown")
    end
  end

  defp contracts! do
    case Application.get_env(@app, :contracts) do
      contracts when is_list(contracts) and contracts != [] ->
        for {name, contract} <- contracts do
          unless is_atom(name) and Code.ensure_loaded?(contract) and
                   function_exported?(contract, :__schema__, 0),
                 do:
                   Mix.raise(
                     "contract #{inspect(name)}: #{inspect(contract)} is no model contract"
                   )

          {name, contract}
        end

      _ ->
        Mix.raise("no contracts: set `config :#{@app}, contracts: [name: MyModel]`")
    end
  end

  defp targets! do
    targets = Application.get_env(@app, :targets, [])

    for {target, _dir} <- targets, not Map.has_key?(@targets, target) do
      Mix.raise(
        "unknown target #{inspect(target)}; known: #{inspect(@targets |> Map.keys() |> Enum.sort())}"
      )
    end

    for {target, spec} <- targets do
      case spec do
        {dir, opts} when is_binary(dir) and is_list(opts) -> {target, dir, opts}
        dir when is_binary(dir) -> {target, dir, []}
        other -> Mix.raise("target #{inspect(target)}: expected a folder, got #{inspect(other)}")
      end
    end
  end
end

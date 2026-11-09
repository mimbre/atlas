defmodule Mix.Tasks.Atlas.Flow.Gen do
  @shortdoc "Generate the flow targets of the configured contract"
  @moduledoc """
      mix atlas.flow.gen           # write them
      mix atlas.flow.gen --check   # fail when one is stale, missing or left over (CI)

  Run in a contract's project, which configures its contract and target folders:

      config :atlas_flow_generator,
        contract: MyFlows,
        targets: [rela: "../targets/rela", diagrams: "../targets/diagrams"],
        root: "../.."

  `contract` uses `AtlasFlowGenerator.Schema`; the task reads only its `__flows__/0`.
  `root` (optional, default the project's folder) is what the header's path to the
  contract file is relative to. The targets:

    * `rela`: `flows.yaml`, every subflow in Rela's format (`AtlasFlowGenerator.Rela`);
    * `diagrams`: `<subflow>.md` for each subflow, its state diagram as Rela draws it.

  **Rela.** When `ATLAS_RELA_BIN` names the folder holding the pinned `rela` (26.11.2;
  the same variable the assembler uses), the task runs `rela flow validate` on the
  generated `flows.yaml` and fails on what Rela refuses, then draws each diagram with
  `rela flow show`. Without it, nothing is validated and diagrams are neither drawn nor
  compared; the task says so. It still fails on a missing or left-over diagram.

  Every file starts with an `AtlasFlowGenerator.Header`. A file without exactly that
  header is hand-written and never overwritten. A file with it, in a target's folder,
  that the task no longer writes is left over: the task removes it, and `--check` fails
  on it, as on a file that would change.
  """
  use Mix.Task

  alias AtlasFlowGenerator.{Header, Rela}

  @requirements ["compile"]
  @targets [:rela, :diagrams]

  @impl true
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [check: :boolean])
    if rest != [], do: Mix.raise("unexpected argument #{Enum.join(rest, " ")}")

    targets = targets!()
    flows = contract!().__flows__()
    root = Path.expand(Application.get_env(:atlas_flow_generator, :root, "."))
    source = flows |> Enum.map(&Path.relative_to(&1.file, root)) |> Enum.uniq() |> Enum.join(", ")

    yaml = Header.put(".yaml", source, Rela.flows_yaml(flows))
    rela = for dir <- List.wrap(targets[:rela]), do: {Path.join(dir, "flows.yaml"), yaml}
    diagram_dir = targets[:diagrams]

    diagram_paths =
      for dir <- List.wrap(diagram_dir), f <- flows, do: Path.join(dir, "#{f.name}.md")

    {diagrams, rela_note} =
      case rela_binary!() do
        nil ->
          {:not_drawn,
           "rela not run (ATLAS_RELA_BIN is not set): flows.yaml was not validated and " <>
             "the diagrams were neither drawn nor compared"}

        binary ->
          case Rela.check(binary, yaml, flows) do
            {:ok, shown} ->
              drawn =
                for {path, one} <- Enum.zip(diagram_paths, shown),
                    do: {path, Header.put(".md", source, Rela.diagram(one))}

              {drawn, nil}

            {:error, message} ->
              Mix.raise(message)
          end
      end

    files = rela ++ if(diagrams == :not_drawn, do: [], else: diagrams)
    stale = for {path, body} <- files, File.read(path) != {:ok, body}, do: path
    missing = if diagrams == :not_drawn, do: Enum.reject(diagram_paths, &File.exists?/1), else: []
    leftovers = leftovers(targets, Enum.map(rela, &elem(&1, 0)) ++ diagram_paths)
    note = fn -> if rela_note, do: Mix.shell().error(rela_note) end

    cond do
      opts[:check] && (stale != [] or missing != [] or leftovers != []) ->
        note.()

        Mix.raise(
          "out of date, run `mix atlas.flow.gen`: " <>
            Enum.join(
              stale ++
                Enum.map(missing, &"#{&1} (missing)") ++ Enum.map(leftovers, &"#{&1} (left over)"),
              ", "
            )
        )

      opts[:check] ->
        Mix.shell().info("generated files are up to date")
        note.()

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
        for path <- missing, do: Mix.shell().error("#{path} is missing and was not drawn")
        note.()
    end
  end

  # Files with the header, in a target's folder, that the task does not write now.
  defp leftovers(targets, written) do
    for {_target, dir} <- targets,
        path <- Path.wildcard(Path.join(dir, "**/*")),
        File.regular?(path),
        path not in written,
        generated?(path),
        do: path
  end

  defp generated?(path), do: Header.generated?(Path.extname(path), File.read!(path))

  defp rela_binary! do
    case System.get_env("ATLAS_RELA_BIN") do
      dir when dir in [nil, ""] ->
        nil

      dir ->
        binary = Path.join(dir, "rela")

        if File.regular?(binary),
          do: binary,
          else: Mix.raise("ATLAS_RELA_BIN: no rela at #{binary}")
    end
  end

  defp contract! do
    case Application.get_env(:atlas_flow_generator, :contract) do
      nil -> Mix.raise("no contract: set `config :atlas_flow_generator, contract: MyFlows`")
      contract -> contract
    end
  end

  defp targets! do
    targets = Application.get_env(:atlas_flow_generator, :targets, [])

    for {target, _dir} <- targets, target not in @targets do
      Mix.raise("unknown target #{inspect(target)}; known: #{inspect(@targets)}")
    end

    targets
  end
end

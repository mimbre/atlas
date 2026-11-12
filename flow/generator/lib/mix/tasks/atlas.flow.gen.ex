defmodule Mix.Tasks.Atlas.Flow.Gen do
  @shortdoc "Generate the flow targets of the configured contract"
  @moduledoc """
      mix atlas.flow.gen           # write them
      mix atlas.flow.gen --check   # fail when one is stale, missing or left over (CI)

  Run in a contract's project, which configures its contract and target folders:

      config :atlas_flow_generator,
        contract: MyFlows,
        gates: MyFlows.Gates,
        targets: [rela: "../targets/rela", atlas: "../targets/atlas", diagrams: "../targets/diagrams"],
        rela_project: "../../rela",
        root: "../.."

  `contract` and `gates` (optional, default the contract) use
  `AtlasFlowGenerator.Schema`; the task reads only the contract's `__flows__/0` and the
  gates' `__gates__/0`. `root` (optional, default the project's folder) is what the
  header's paths to the contract files are relative to: the header names the files of
  the subflows (and gates), after the composition's file when the contract is one. The
  targets:

    * `rela`: `flows.yaml`, every subflow in Rela's format (`AtlasFlowGenerator.Rela`);
    * `atlas`: `flows.json`, what Atlas runs them by, and every gate
      (`AtlasFlowGenerator.Atlas`), bound to that `flows.yaml` by its SHA-256;
    * `diagrams`: `<subflow>.md` for each subflow, its state diagram as Rela draws it.

  **Rela.** When `ATLAS_RELA_BIN` names the folder holding the pinned `rela` (26.11.2;
  the same variable the assembler uses), the task runs Rela on the generated
  `flows.yaml` and fails on what Rela refuses, then draws each diagram with
  `rela flow show`. With `rela_project` (optional) naming a Rela description, Rela
  validates the whole description in a temporary copy, the generated `flows.yaml` in
  place of its own; without it, `rela flow validate` runs in a scratch project
  derived from the subflows (`AtlasFlowGenerator.Rela.check/4`). Without it, nothing is validated and diagrams are neither drawn nor
  compared; the task says so. It still fails on a missing or left-over diagram.

  Every file starts with an `AtlasFlowGenerator.Header`. A file without exactly that
  header is hand-written and never overwritten. A file with it, in a target's folder,
  that the task no longer writes is left over: the task removes it, and `--check` fails
  on it, as on a file that would change.
  """
  use Mix.Task

  alias AtlasFlowGenerator.{Atlas, Header, Rela}

  @requirements ["compile"]
  @targets [:rela, :atlas, :diagrams]

  @impl true
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [check: :boolean])
    if rest != [], do: Mix.raise("unexpected argument #{Enum.join(rest, " ")}")

    targets = targets!()
    contract = contract!()
    flows = contract.__flows__()
    gates = Application.get_env(:atlas_flow_generator, :gates, contract).__gates__()
    flows = AtlasFlowGenerator.Limits.resolve(flows, gates, :prod)
    root = Path.expand(Application.get_env(:atlas_flow_generator, :root, "."))

    # A composition is the root of what was generated, so its file is named first.
    composed =
      if function_exported?(contract, :__composition__, 0),
        do: [contract.__composition__()],
        else: []

    source = fn items ->
      (composed ++ items)
      |> Enum.map(&Path.relative_to(&1.file, root))
      |> Enum.uniq()
      |> Enum.join(", ")
    end

    flows_source = source.(flows)
    yaml = Header.put(".yaml", flows_source, Rela.flows_yaml(flows))

    # flows.json also comes from the gates, and is bound to this run's flows.yaml.
    json =
      Header.put(
        ".json",
        source.(flows ++ gates),
        atlas_json!(flows, gates, Atlas.sha256(yaml))
      )

    pairs =
      for {environment, dirs} <-
            Application.get_env(:atlas_flow_generator, :environment_targets, []),
          resolved = AtlasFlowGenerator.Limits.resolve(contract.__flows__(), gates, environment),
          pair_yaml = Header.put(".yaml", flows_source, Rela.flows_yaml(resolved)),
          :ok = validate_pair!(pair_yaml, resolved),
          pair_json =
            Header.put(
              ".json",
              source.(resolved ++ gates),
              atlas_json!(resolved, gates, Atlas.sha256(pair_yaml))
            ),
          {dir, file, body} <- [
            {dirs[:rela], "flows.yaml", pair_yaml},
            {dirs[:atlas], "flows.json", pair_json}
          ],
          do: {Path.join(dir, file), body}

    always =
      pairs ++
        for(dir <- List.wrap(targets[:rela]), do: {Path.join(dir, "flows.yaml"), yaml}) ++
        for dir <- List.wrap(targets[:atlas]), do: {Path.join(dir, "flows.json"), json}

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
          case Rela.check(binary, yaml, flows, project: rela_project()) do
            {:ok, shown} ->
              drawn =
                for {path, one} <- Enum.zip(diagram_paths, shown),
                    do: {path, Header.put(".md", flows_source, Rela.diagram(one))}

              {drawn, nil}

            {:error, message} ->
              Mix.raise(message)
          end
      end

    files = always ++ if(diagrams == :not_drawn, do: [], else: diagrams)
    stale = for {path, body} <- files, File.read(path) != {:ok, body}, do: path
    missing = if diagrams == :not_drawn, do: Enum.reject(diagram_paths, &File.exists?/1), else: []

    pair_dirs =
      Enum.flat_map(
        Application.get_env(:atlas_flow_generator, :environment_targets, []),
        &elem(&1, 1)
      )

    leftovers = leftovers(targets ++ pair_dirs, Enum.map(always, &elem(&1, 0)) ++ diagram_paths)
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

  defp atlas_json!(flows, gates, sha) do
    Atlas.flows_json(flows, gates, sha)
  rescue
    e in ArgumentError -> Mix.raise("flows.json: " <> Exception.message(e))
  end

  defp validate_pair!(yaml, flows) do
    case rela_binary!() do
      nil ->
        :ok

      binary ->
        case Rela.check(binary, yaml, flows, project: rela_project()) do
          {:ok, _} -> :ok
          {:error, message} -> Mix.raise(message)
        end
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

  defp rela_project do
    with dir when is_binary(dir) <- Application.get_env(:atlas_flow_generator, :rela_project),
         do: Path.expand(dir)
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

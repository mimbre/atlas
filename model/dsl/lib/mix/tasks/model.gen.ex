defmodule Mix.Tasks.Model.Gen do
  @shortdoc "Generate the targets of the configured model"
  @moduledoc """
      mix model.gen                     # write them
      mix model.gen --check             # fail when one is stale, missing or left over (CI)
      mix model.gen --check --base REF  # also check the run identities against REF's
      mix model.gen --contract M --out DIR   # only the Rela project of M, into DIR

  Run in a model's project, which configures its contract and target folders:

      config :rela_dsl,
        contract: MyModel.Office,
        targets: [atlas: "../targets/atlas", diagrams: "../targets/diagrams", proof: "../targets/proof"],
        environment_targets: [test: [rela: "../targets/test/rela", atlas: "../targets/test/atlas"]],
        rela_project: "../../rela",
        root: "../.."

  `contract` is a composition (`RelaDSL.Composition`) or, for subflows alone, a
  module with `__flows__/0` (`RelaDSL.Schema.Composition`), with `gates` (optional,
  default the contract) giving `__gates__/0`. A composition's gates are its concepts'.
  `root` (optional, default the project's folder) is what the headers' paths to the
  model's files are relative to. The targets:

    * `rela` (subflows alone): `flows.yaml`, every subflow in Rela's format;
    * `atlas`: `flows.json`, what Atlas runs them by, and every gate (`RelaDSL.Atlas`),
      bound to that run's `flows.yaml` by its SHA-256;
    * `diagrams`: `<subflow>.md` for each subflow, its state diagram as Rela draws it;
    * `proof` (a composition): `digests.json`, each subflow's digest and states per
      environment, with its history (`RelaDSL.RunIdentity`).

  `environment_targets` write a `flows.yaml` and `flows.json` pair per environment,
  with that environment's gate limits.

  **The Rela project.** With a composition, `rela_project` is the folder of its Rela
  project, and the task writes every file of it that the model describes
  (`RelaDSL.Project`): `schema.yaml`, the module and bindings files, `acl.yaml`,
  `atlas.json`, `flow-runtime.json`, `flows.yaml` and `atlas.manifest.json`. Only
  `data-entry.yaml` there is hand-written. A file under `modules/` or `compositions/`
  that the task does not write is left over. `--out DIR` writes the project of
  `--contract` (a composition, such as a test profile) into `DIR` instead, with a copy
  of the configured project's `data-entry.yaml`, and nothing else.

  **The base.** `--base REF` reads `model/targets/proof/digests.json` (below `root`)
  as `git show REF:…` gives it, and fails on what `RelaDSL.RunIdentity.base_problems/3`
  refuses, so a change cannot approve its own migration. A base that holds no
  `digests.json` yet predates the proof: the task says so and checks nothing against it.

  **Rela.** When `ATLAS_RELA_BIN` names the folder holding the pinned `rela` (26.11.2),
  the task runs Rela on the generated `flows.yaml` and fails on what Rela refuses,
  then draws each diagram with `rela flow show`. With `rela_project`, Rela validates
  the whole description in a temporary copy of it, with the generated files in place;
  without it, in a scratch project derived from the subflows (`RelaDSL.Rela.check/4`).
  Without `ATLAS_RELA_BIN`, nothing is validated and diagrams are neither drawn nor
  compared; the task says so. It still fails on a missing or left-over diagram.

  Every file in a target's folder starts with an `RelaDSL.Header`. A file there without
  exactly that header is hand-written and never overwritten. A file with it that the
  task no longer writes is left over: the task removes it, and `--check` fails on it,
  as on a file that would change.
  """
  use Mix.Task

  alias RelaDSL.{Atlas, Header, Project, Rela, RunIdentity}

  @requirements ["compile"]
  @targets [:rela, :atlas, :diagrams, :proof]
  @digests "model/targets/proof/digests.json"

  @impl true
  def run(args) do
    {opts, rest} =
      OptionParser.parse!(args,
        strict: [check: :boolean, base: :string, out: :string, contract: :string]
      )

    if rest != [], do: Mix.raise("unexpected argument #{Enum.join(rest, " ")}")

    contract = contract!(opts[:contract])
    Code.ensure_loaded!(contract)
    composition? = function_exported?(contract, :__rela__, 1)

    if opts[:out] do
      unless composition?,
        do: Mix.raise("--out writes a composition's Rela project; #{inspect(contract)} is none")

      out(contract, Path.expand(opts[:out]))
    else
      generate(contract, composition?, opts)
    end
  end

  defp out(contract, dir) do
    project =
      rela_project() || Mix.raise("--out needs rela_project: its data-entry.yaml is copied")

    data_entry = File.read!(Path.join(project, "data-entry.yaml"))

    flows = RelaDSL.Limits.resolve(contract.__flows__(), contract.__rela__(:gates), :prod)
    yaml = if flows != [], do: flows_yaml(contract, flows), else: nil

    for {path, body} <- [
          {"data-entry.yaml", data_entry}
          | Project.files(contract.__rela__(:description), data_entry, yaml)
        ] do
      File.mkdir_p!(Path.dirname(Path.join(dir, path)))
      File.write!(Path.join(dir, path), body)
    end

    Mix.shell().info("wrote the Rela project of #{inspect(contract)} to #{dir}")
  end

  defp generate(contract, composition?, opts) do
    targets = targets!(composition?)
    gates = gates!(contract, composition?)
    flows = RelaDSL.Limits.resolve(contract.__flows__(), gates, :prod)
    yaml = flows_yaml(contract, flows)

    # flows.json also comes from the gates, and is bound to this run's flows.yaml.
    json =
      Header.put(
        ".json",
        source(contract, flows ++ gates),
        atlas_json!(flows, gates, Atlas.sha256(yaml))
      )

    project = if composition?, do: project_files(contract, yaml), else: []

    pairs =
      for {environment, dirs} <- Application.get_env(:rela_dsl, :environment_targets, []),
          resolved = RelaDSL.Limits.resolve(contract.__flows__(), gates, environment),
          pair_yaml = flows_yaml(contract, resolved),
          :ok = validate_pair!(pair_yaml, resolved, project),
          pair_json =
            Header.put(
              ".json",
              source(contract, resolved ++ gates),
              atlas_json!(resolved, gates, Atlas.sha256(pair_yaml))
            ),
          {dir, file, body} <- [
            {dirs[:rela], "flows.yaml", pair_yaml},
            {dirs[:atlas], "flows.json", pair_json}
          ],
          do: {Path.join(dir, file), body}

    proof =
      if composition? and targets[:proof] do
        description = contract.__rela__(:description)
        body = RelaDSL.Description.Json.write(description.digests)

        [
          {Path.join(targets[:proof], "digests.json"),
           Header.put(".json", source(contract, flows), body)}
        ]
      else
        []
      end

    always =
      pairs ++
        for(dir <- List.wrap(targets[:rela]), do: {Path.join(dir, "flows.yaml"), yaml}) ++
        for(dir <- List.wrap(targets[:atlas]), do: {Path.join(dir, "flows.json"), json}) ++ proof

    diagram_paths =
      for dir <- List.wrap(targets[:diagrams]), f <- flows, do: Path.join(dir, "#{f.name}.md")

    {diagrams, rela_note} =
      case rela_binary!() do
        nil ->
          {:not_drawn,
           "rela not run (ATLAS_RELA_BIN is not set): flows.yaml was not validated and " <>
             "the diagrams were neither drawn nor compared"}

        binary ->
          case Rela.check(binary, yaml, flows,
                 project: rela_project(),
                 files: description_files(project)
               ) do
            {:ok, shown} ->
              drawn =
                for {path, one} <- Enum.zip(diagram_paths, shown),
                    do: {path, Header.put(".md", source(contract, flows), Rela.diagram(one))}

              {drawn, nil}

            {:error, message} ->
              Mix.raise(message)
          end
      end

    files = project ++ always ++ if(diagrams == :not_drawn, do: [], else: diagrams)
    stale = for {path, body} <- files, File.read(path) != {:ok, body}, do: path
    missing = if diagrams == :not_drawn, do: Enum.reject(diagram_paths, &File.exists?/1), else: []

    pair_dirs =
      Enum.flat_map(Application.get_env(:rela_dsl, :environment_targets, []), &elem(&1, 1))

    leftovers =
      leftovers(targets ++ pair_dirs, Enum.map(always, &elem(&1, 0)) ++ diagram_paths) ++
        owned_leftovers(composition?, Enum.map(project, &elem(&1, 0)))

    note = fn -> if rela_note, do: Mix.shell().error(rela_note) end
    base = if opts[:base], do: base_problems!(contract, composition?, opts[:base]), else: []

    cond do
      opts[:check] && (stale != [] or missing != [] or leftovers != [] or base != []) ->
        note.()

        problems =
          stale ++
            Enum.map(missing, &"#{&1} (missing)") ++ Enum.map(leftovers, &"#{&1} (left over)")

        Mix.raise(
          if(problems != [],
            do: "out of date, run `mix model.gen`: " <> Enum.join(problems, ", "),
            else: ""
          ) <>
            if(base != [],
              do: "\nagainst the base #{opts[:base]}:\n  " <> Enum.join(base, "\n  "),
              else: ""
            )
        )

      opts[:check] ->
        Mix.shell().info("generated files are up to date")
        note.()

      true ->
        if base != [],
          do: Mix.raise("against the base #{opts[:base]}:\n  " <> Enum.join(base, "\n  "))

        owned = Enum.map(project, &elem(&1, 0))

        for path <- stale,
            path not in owned,
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

  defp flows_yaml(contract, flows),
    do: Header.put(".yaml", source(contract, flows), Rela.flows_yaml(flows))

  # The files the header names: the composition's first, then those of the items.
  defp source(contract, items) do
    root = Path.expand(Application.get_env(:rela_dsl, :root, "."))

    composed =
      if function_exported?(contract, :__composition__, 0),
        do: [contract.__composition__()],
        else: []

    (composed ++ items)
    |> Enum.map(&Path.relative_to(&1.file, root))
    |> Enum.uniq()
    |> Enum.join(", ")
  end

  # The Rela project's files, at their paths below rela_project.
  defp project_files(contract, yaml) do
    project =
      rela_project() ||
        Mix.raise("a composition needs rela_project: the folder of its Rela project")

    data_entry = Path.join(project, "data-entry.yaml")

    unless File.regular?(data_entry),
      do: Mix.raise("#{data_entry} is missing: rela-server's setting is hand-written and stays")

    for {path, body} <-
          Project.files(contract.__rela__(:description), File.read!(data_entry), yaml),
        do: {Path.join(project, path), body}
  end

  # What Rela checks the flows against: the generated description, without flows.yaml.
  defp description_files(project) do
    root = rela_project()

    for {path, body} <- project,
        (relative = Path.relative_to(path, root)) != "flows.yaml",
        do: {relative, body}
  end

  defp owned_leftovers(false, _written), do: []

  defp owned_leftovers(true, written) do
    root = rela_project()

    for folder <- Project.owned_folders(),
        path <- Path.wildcard(Path.join([root, folder, "**", "*"])),
        File.regular?(path),
        path not in written,
        do: path
  end

  defp base_problems!(_contract, false, _ref),
    do: Mix.raise("--base checks a composition's run identities")

  defp base_problems!(contract, true, ref) do
    root = Path.expand(Application.get_env(:rela_dsl, :root, "."))

    case System.cmd("git", ["-C", root, "show", "#{ref}:#{@digests}"], stderr_to_stdout: true) do
      {text, 0} ->
        base = JSON.decode!(text)
        description = contract.__rela__(:description)
        RunIdentity.base_problems(base, description.digests, contract.__rela__(:migrations))

      {message, _} ->
        if message =~ ~r/does not exist|exists on disk, but not in/ do
          Mix.shell().info("the base #{ref} holds no #{@digests} yet; its history starts here")
          []
        else
          Mix.raise("--base #{ref}: #{String.trim(message)}")
        end
    end
  end

  defp atlas_json!(flows, gates, sha) do
    Atlas.flows_json(flows, gates, sha)
  rescue
    e in ArgumentError -> Mix.raise("flows.json: " <> Exception.message(e))
  end

  defp validate_pair!(yaml, flows, project) do
    case rela_binary!() do
      nil ->
        :ok

      binary ->
        case Rela.check(binary, yaml, flows,
               project: rela_project(),
               files: description_files(project)
             ) do
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
    with dir when is_binary(dir) <- Application.get_env(:rela_dsl, :rela_project),
         do: Path.expand(dir)
  end

  defp contract!(nil) do
    case Application.get_env(:rela_dsl, :contract) do
      nil -> Mix.raise("no contract: set `config :rela_dsl, contract: MyModel`")
      contract -> contract
    end
  end

  defp contract!(name) do
    module = Module.concat([name])

    case Code.ensure_compiled(module) do
      {:module, ^module} -> module
      {:error, reason} -> Mix.raise("--contract #{name} is #{reason}")
    end
  end

  defp gates!(contract, true) do
    if Application.get_env(:rela_dsl, :gates),
      do: Mix.raise("a composition's gates are its concepts'; do not set gates:"),
      else: contract.__rela__(:gates)
  end

  defp gates!(contract, false), do: Application.get_env(:rela_dsl, :gates, contract).__gates__()

  defp targets!(composition?) do
    targets = Application.get_env(:rela_dsl, :targets, [])

    for {target, _dir} <- targets, target not in @targets do
      Mix.raise("unknown target #{inspect(target)}; known: #{inspect(@targets)}")
    end

    if targets[:proof] && not composition?, do: Mix.raise("the proof target needs a composition")
    targets
  end
end

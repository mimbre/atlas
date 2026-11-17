defmodule AtlasRuntime.Sandbox.Preparation do
  @moduledoc """
  The prepare-step decision (S6 §12 move 6, package A6; shadow: nothing calls it until C6, which
  waits for the `prepare_folder` operations capability, RQ1).

  It decides, from the raw facts of `atlas-runtime workspace facts prepare DEST HOME PATH`
  (`host/workspace/facts_prepare.go`, fetched with
  `AtlasRuntime.Sandbox.Facts.fetch("prepare", [dest, home, path], facts_input(step))`):

    * `begin_record/3`: whether an npm-ci or npm-run of a materialized folder's package may begin,
      and the running `Preparation` record to write first (`snapshot.PlanNPMCI`/`PlanNPMRun`,
      `validOutputs`, `registryOnly`, `host/snapshot/prepare.go:104-370`);
    * `plan/3`: the runner's whole plan (`host/host/prepare.go:67-170`): the "prepared once" rule
      (a repeat reports the recorded outcome), the required tools, the step argv
      (`npmArguments`/`runArguments`), the environment (`preparationKept` and the scratch), the
      writable outputs and the `codex sandbox` setup request for
      `AtlasRuntime.Sandbox.Spec.codex_sandbox(:setup, …)` with the id of its A2g spec row;
    * `load/3`, `ready?/1`, `not_ready_text/2`, `outcome/2`: whether a recorded result is valid
      and ready, and today's texts (`Preparation.valid`, `Ready`, `NotReady`, `preparationOutcome`).

  They are pure: no filesystem I/O. Refusals are `{:error, text}` with today's exact text (B3).
  Running the steps, the lock and the records stay in the helper. The parity tables are
  `test/fixtures/s6/prepare/`; the Go tests assert the same rows against the legacy code.

  A step is `:npm_ci` or `{:npm_run, script, outputs}` (outputs as declared, unsorted).
  """

  # snapshot.NPMRegistry (host/snapshot/prepare.go:20).
  @npm_registry "registry.npmjs.org"

  # npmArguments and runArguments (host/host/prepare.go:30, 34).
  @npm_arguments ["ci", "--ignore-scripts", "--no-audit", "--no-fund"]
  @run_arguments ["run", "--ignore-scripts", "--offline"]

  # preparationKept (host/host/prepare.go:38): all a preparation inherits from the caller.
  @kept ["HOME", "USER", "LOGNAME", "PATH", "LANG", "LC_ALL", "LC_CTYPE", "CODEX_HOME"]

  # preparationEnvironment (host/host/prepare.go:262-278): the scratch's directories and empty files.
  @scratch_dirs [
    {"TMPDIR", "tmp"},
    {"XDG_CACHE_HOME", "cache"},
    {"npm_config_cache", "npm-cache"}
  ]
  @scratch_files [
    {"npm_config_userconfig", "user-npmrc"},
    {"npm_config_globalconfig", "global-npmrc"}
  ]

  # The required tools and their refusals (host/host/prepare.go:107, 112).
  @tools [
    {"codex", "Preparation requires the installed Codex sandbox (codex on PATH)"},
    {"npm", "Preparation requires npm on PATH"}
  ]
  @run_tools [{"node", "Preparation requires node on PATH"}]

  # The A2g setup rows (test/fixtures/s6/spec/codex_sandbox.json) whose spec each step uses.
  @setup_rows %{"npm-ci" => "setup.npm-ci-network", "npm-run" => "setup.npm-run-no-network"}

  # The scratch in a plan: the helper creates it (MkdirTemp under <home>/scratch) after deciding.
  @scratch "$SCRATCH"

  # Go regexps match `$` only at the end of the text; `\z` is the same here.
  @script_name ~r/\A[A-Za-z0-9][A-Za-z0-9:._-]{0,63}\z/
  @snapshot_id ~r/\Asha256:[0-9a-f]{64}\z/

  @states ["running", "succeeded", "failed"]

  # The Preparation fields in their JSON order (snapshot.Preparation), with their types.
  @fields [
    {"version", :int},
    {"destination", :string},
    {"snapshot_id", :string},
    {"kind", :string},
    {"path", :string},
    {"script", :string},
    {"outputs", :strings},
    {"state", :string},
    {"reason", :string},
    {"exit_code", :int_pointer},
    {"started_at", :string},
    {"ended_at", :string},
    {"previous", :preparation}
  ]
  @omit_empty ["script", "reason", "exit_code", "ended_at", "previous"]

  @doc "The scratch token in a plan's paths."
  def scratch_token, do: @scratch

  @doc "The A2g setup spec row id of a step kind (`npm-ci` | `npm-run`)."
  def setup_row(kind), do: Map.fetch!(@setup_rows, kind)

  @doc "The `prepare` facts input for step: the outputs to lstat and the tools to look up (B4)."
  def facts_input(:npm_ci), do: %{"outputs" => [], "tools" => tool_names(:npm_ci)}

  def facts_input({:npm_run, _script, outputs}),
    do: %{"outputs" => outputs, "tools" => tool_names(:npm_run)}

  defp tool_names(kind), do: for({name, _} <- required_tools(kind), do: name)

  defp required_tools(:npm_ci), do: @tools
  defp required_tools(:npm_run), do: @tools ++ @run_tools

  # Readiness

  @doc "Whether workers may start in the folder of a valid record (Preparation.Ready)."
  def ready?(%{"state" => state}), do: state == "succeeded"

  @doc "The step a record holds of kind: itself, or the npm-ci an npm-run follows (Preparation.Step)."
  def step(nil, _kind), do: nil
  def step(%{"kind" => kind} = record, kind), do: record
  def step(%{"previous" => %{"kind" => kind} = previous}, kind), do: previous
  def step(_record, _kind), do: nil

  @doc "How refusals name a step (Preparation.Describe)."
  def describe(%{"kind" => kind, "path" => path} = record) do
    case record["script"] do
      script when is_binary(script) and script != "" ->
        "#{kind} preparation of #{path} (script #{script})"

      _ ->
        "#{kind} preparation of #{path}"
    end
  end

  @doc "Where the private diagnostics of a step are (Preparation.Diagnostics)."
  def diagnostics(%{"kind" => "npm-run", "destination" => dest}, home),
    do: Path.join(private_dir(home, dest), "npm-run")

  def diagnostics(%{"destination" => dest}, home), do: private_dir(home, dest)

  @doc "The worker-readable result file of dest's preparation (snapshot.PreparationResult)."
  def result_path(home, dest), do: Path.join(preparation_dir(home, dest), "result.json")

  defp private_dir(home, dest), do: Path.join(preparation_dir(home, dest), "private")

  defp preparation_dir(home, dest),
    do: Path.join([home, "preparations", hex(:crypto.hash(:sha256, dest))])

  defp hex(bytes), do: Base.encode16(bytes, case: :lower)

  @doc "The refusal of a folder whose recorded step is not ready (Preparation.NotReady)."
  def not_ready_text(record, home) do
    outcome =
      if record["state"] == "running",
        do: "has no recorded outcome: it is still running or was interrupted",
        else: "failed (#{record["reason"] || ""})"

    "Materialized folder #{record["destination"]} is not ready: its #{describe(record)} #{outcome}. " <>
      "The folder and the diagnostics in #{diagnostics(record, home)} are kept; " <>
      "materialize the snapshot into a fresh folder and prepare that one"
  end

  @doc """
  The command result of a recorded step (preparationOutcome): `{result, nil}` when ready, else
  `{result, not_ready_text}`.
  """
  def outcome(record, home) do
    result = %{
      "destination" => record["destination"],
      "snapshot_id" => record["snapshot_id"],
      "kind" => record["kind"],
      "path" => record["path"],
      "outputs" => record["outputs"],
      "state" => record["state"],
      "ready" => ready?(record),
      "reason" => nil_if_empty(record["reason"]),
      "exit_code" => record["exit_code"],
      "started_at" => record["started_at"],
      "ended_at" => nil_if_empty(record["ended_at"]),
      "diagnostics" => diagnostics(record, home)
    }

    result =
      if (record["script"] || "") != "",
        do: Map.put(result, "script", record["script"]),
        else: result

    {result, if(ready?(record), do: nil, else: not_ready_text(record, home))}
  end

  @doc """
  The recorded preparation of dest from the `preparation` fact (LoadPreparation): `{:ok, nil}`
  for a folder never prepared, `{:ok, record}` (normalized as Go encodes it), or the refusal.
  """
  def load(fact, home, dest) do
    cond do
      fact["absent"] == true ->
        {:ok, nil}

      is_binary(fact["error"]) ->
        {:error, fact["error"]}

      true ->
        with {:ok, record} <- decode(fact["raw"]),
             true <- valid?(record, dest) do
          {:ok, record}
        else
          _ -> {:error, "invalid preparation result #{result_path(home, dest)} for #{dest}"}
        end
    end
  end

  # Strict decoding as LoadPreparation's decoder does it: unknown fields refused, a field name
  # matched exactly or else case-insensitively, null leaves a field's zero value, and any type
  # mismatch refuses. The record is normalized to what Go encodes (omitempty fields dropped).
  defp decode(nil), do: {:ok, zero_record()}

  defp decode(raw) when is_map(raw) do
    Enum.reduce_while(raw, {:ok, zero_values()}, fn {key, value}, {:ok, acc} ->
      case field(key) do
        nil ->
          {:halt, :error}

        {name, type} ->
          case decode_value(type, value) do
            {:ok, :zero} -> {:cont, {:ok, acc}}
            {:ok, decoded} -> {:cont, {:ok, Map.put(acc, name, decoded)}}
            :error -> {:halt, :error}
          end
      end
    end)
    |> case do
      {:ok, values} -> {:ok, normalize(values)}
      :error -> :error
    end
  end

  defp decode(_raw), do: :error

  defp field(key) do
    Enum.find(@fields, fn {name, _} -> name == key end) ||
      Enum.find(@fields, fn {name, _} -> String.downcase(name) == String.downcase(key) end)
  end

  defp decode_value(_type, nil), do: {:ok, :zero}

  defp decode_value(:int, value) when is_integer(value) and abs(value) < 0x8000000000000000,
    do: {:ok, value}

  defp decode_value(:int_pointer, value), do: decode_value(:int, value)
  defp decode_value(:string, value) when is_binary(value), do: {:ok, value}

  defp decode_value(:strings, value) when is_list(value) do
    if Enum.all?(value, &(is_binary(&1) or is_nil(&1))),
      do: {:ok, Enum.map(value, &(&1 || ""))},
      else: :error
  end

  defp decode_value(:preparation, value) when is_map(value), do: decode(value)
  defp decode_value(_type, _value), do: :error

  defp zero_values, do: %{}

  defp zero_record, do: normalize(zero_values())

  # Every field with its zero value where it was absent or null; omitempty fields dropped when
  # empty, as json.Marshal writes a Preparation.
  defp normalize(values) do
    @fields
    |> Enum.map(fn {name, type} -> {name, Map.get(values, name, zero(type))} end)
    |> Enum.reject(fn {name, value} -> name in @omit_empty and value in [nil, ""] end)
    |> Map.new()
  end

  defp zero(:int), do: 0
  defp zero(:string), do: ""
  defp zero(_type), do: nil

  @doc "Whether record is a well-formed recorded preparation of dest (Preparation.valid)."
  def valid?(record, dest) do
    record["destination"] == dest and is_binary(record["snapshot_id"]) and
      Regex.match?(@snapshot_id, record["snapshot_id"]) and safe?(record["path"]) and
      record["state"] in @states and valid_version?(record, dest)
  end

  defp valid_version?(%{"version" => 1} = record, _dest) do
    record["kind"] == "npm-ci" and (record["script"] || "") == "" and is_nil(record["previous"]) and
      record["outputs"] == npm_outputs(record["path"])
  end

  defp valid_version?(%{"version" => 2} = record, dest) do
    previous = record["previous"]

    record["kind"] == "npm-run" and Regex.match?(@script_name, record["script"] || "") and
      valid_outputs(record["path"], record["outputs"] || []) == :ok and is_map(previous) and
      previous["version"] == 1 and valid?(previous, dest) and
      previous["snapshot_id"] == record["snapshot_id"] and previous["path"] == record["path"] and
      ready?(previous)
  end

  defp valid_version?(_record, _dest), do: false

  # The plan of one step (host/snapshot/prepare.go)

  # npmOutputs: an npm-ci of path writes only path/node_modules.
  defp npm_outputs(path), do: [path <> "/node_modules"]

  @doc """
  Whether the step may begin in the verified folder, and the running record to write before
  anything runs (PlanNPMCI / PlanNPMRun). `opts[:now]` is the record's `started_at`.
  """
  def begin_record(step, facts, opts \\ []) do
    refusing(fn -> begin_record!(step, facts, Keyword.get(opts, :now, now())) end)
  end

  defp begin_record!(:npm_ci, facts, now) do
    folder = folder!(facts)
    root = folder["root"]
    path = facts["path"]
    tracked = tracked(facts)
    preparation = recorded!(facts)

    if preparation,
      do:
        refuse(
          "#{root} already has a #{preparation["kind"]} preparation of #{preparation["path"]}"
        )

    if not safe?(path) or owner(folder["repositories"], path) == nil,
      do:
        refuse(
          "--npm-ci #{go_quote(path)} is not a folder inside a materialized repository; use REPO_PATH or REPO_PATH/SUBDIR"
        )

    package_folder!(facts, root, tracked)

    for name <- ["package.json", "package-lock.json"] do
      case tracked[path <> "/" <> name] do
        "file" ->
          :ok

        _ ->
          refuse(
            "#{path}/#{name} is not a tracked file; an npm-ci preparation installs a tracked package-lock.json"
          )
      end
    end

    for output <- npm_outputs(path) do
      case tracks(tracked, output) do
        nil ->
          :ok

        first ->
          refuse(
            "#{first} is tracked in the snapshot; a preparation never excludes tracked files"
          )
      end
    end

    unchanged!(
      facts,
      root,
      "a preparation installs exactly the snapshot's lockfile into a freshly materialized folder. A changed package-lock.json must first be part of a snapshot"
    )

    registry_only!(facts["lockfile"], path)

    %{
      "version" => 1,
      "destination" => root,
      "snapshot_id" => folder["snapshot_id"],
      "kind" => "npm-ci",
      "path" => path,
      "outputs" => npm_outputs(path),
      "state" => "running",
      "started_at" => now
    }
  end

  defp begin_record!({:npm_run, script, outputs}, facts, now) do
    folder = folder!(facts)
    root = folder["root"]
    path = facts["path"]
    tracked = tracked(facts)
    installed = recorded!(facts)

    if installed && installed["kind"] == "npm-run",
      do: refuse("#{root} already has an #{describe(installed)}")

    if installed == nil or installed["path"] != path or not ready?(installed),
      do:
        refuse(
          "--npm-run #{path} requires a succeeded --npm-ci preparation of #{path} in #{root} first; the script runs offline with the installed node_modules"
        )

    if not Regex.match?(@script_name, script),
      do: refuse("--script #{go_quote(script)} is not a package.json script name")

    package_folder!(facts, root, tracked)

    scripts =
      case facts["package"] do
        %{"read_error" => error} -> refuse(error)
        %{"decode_error" => error} -> refuse("#{path}/package.json is not valid JSON: #{error}")
        %{"scripts" => scripts} -> scripts || %{}
      end

    case scripts[script] do
      command when is_binary(command) ->
        if go_fields(command) == [], do: refuse_script(script, path)

      _ ->
        refuse_script(script, path)
    end

    outputs = Enum.sort(outputs)

    case valid_outputs(path, outputs) do
      :ok -> :ok
      {:error, text} -> refuse(text)
    end

    repository = owner(folder["repositories"], path)
    chains = Map.new(facts["outputs"] || [], &{&1["output"], &1["chain"]})

    for output <- outputs do
      if owner(folder["repositories"], output) != repository,
        do: refuse("--output #{output} is outside the repository of #{path}")

      output_chain!(output, Map.fetch!(chains, output), tracked)
    end

    unchanged!(
      facts,
      root,
      "an npm-run preparation regenerates exactly the snapshot's files in a freshly prepared folder"
    )

    %{
      "version" => 2,
      "destination" => root,
      "snapshot_id" => folder["snapshot_id"],
      "kind" => "npm-run",
      "path" => path,
      "script" => script,
      "outputs" => outputs,
      "state" => "running",
      "started_at" => now,
      "previous" => installed
    }
  end

  defp refuse_script(script, path),
    do:
      refuse(
        "script #{go_quote(script)} is not in the tracked #{path}/package.json; an npm-run preparation runs only a declared script"
      )

  # The sandbox grants an output by path, so it and every existing folder above it must be real.
  defp output_chain!(output, chain, tracked) do
    last = length(chain) - 1

    chain
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {%{"rel" => rel, "type" => type} = item, index}, :ok ->
      cond do
        type == "absent" ->
          {:halt, :ok}

        type == "error" ->
          refuse(item["error"])

        type == "symlink" or (index != last and type != "dir") or type not in ["dir", "file"] or
            (Map.has_key?(tracked, rel) and tracked[rel] != "file") ->
          refuse(
            "--output #{output}: #{rel} is not a real directory or, for the output itself, a tracked or new regular file"
          )

        true ->
          {:cont, :ok}
      end
    end)
  end

  # packageFolder (host/snapshot/prepare.go:231-247).
  defp package_folder!(facts, root, tracked) do
    for %{"rel" => rel, "type" => type} <- facts["chain"],
        type != "dir" or Map.has_key?(tracked, rel) do
      refuse("#{rel} is not a directory in #{root}")
    end

    for %{"rel" => rel, "present" => present} <- facts["npmrc"],
        present or Map.has_key?(tracked, rel) do
      refuse(
        "project #{rel} is not supported: a preparation installs only from the public npm registry with empty npm configuration"
      )
    end

    :ok
  end

  # unchanged (host/snapshot/prepare.go:250-260).
  defp unchanged!(facts, root, what) do
    case facts["changes"] do
      %{"error" => error} ->
        refuse(error)

      %{"count" => 0} ->
        :ok

      %{"count" => count, "first" => %{"change" => change, "path" => path}} ->
        refuse(
          "#{root} has #{count} change(s) since it was materialized, first #{change} #{path}; #{what}, " <>
            "so materialize the snapshot into a new folder. Nothing was discarded"
        )
    end
  end

  # registryOnly (host/snapshot/prepare.go:372-416): integrity-pinned tarballs from the public
  # npm registry only.
  defp registry_only!(%{"read_error" => error}, _path), do: refuse(error)

  defp registry_only!(%{"decode_error" => error}, path),
    do: refuse("#{path}/package-lock.json is not valid JSON: #{error}")

  defp registry_only!(lock, path) do
    packages = lock["packages"]

    if lock["lockfile_version"] not in [2, 3] or packages == nil,
      do: refuse("#{path}/package-lock.json needs lockfileVersion 2 or 3 with a packages map")

    for name <- Enum.sort(Map.keys(packages)), name != "" do
      pkg = packages[name]
      reason = package_problem(name, pkg)
      if reason, do: refuse("#{path}/package-lock.json #{reason}")
    end

    :ok
  end

  defp package_problem(name, pkg) do
    url = pkg["url"]
    integrity = go_fields(pkg["integrity"])

    cond do
      not String.starts_with?(name, "node_modules/") ->
        "installs #{go_quote(name)} outside node_modules; workspaces and local packages are not supported"

      pkg["link"] or pkg["in_bundle"] ->
        "installs #{go_quote(name)} as a link or bundled package, not from the registry"

      not registry_url?(url) ->
        "resolves #{go_quote(name)} to #{go_quote(pkg["resolved"])}, not to https://#{@npm_registry}/"

      integrity == [] or Enum.any?(integrity, &(not String.starts_with?(&1, "sha512-"))) ->
        "pins #{go_quote(name)} without a sha512 integrity"

      true ->
        nil
    end
  end

  defp registry_url?(%{} = url) do
    url["scheme"] == "https" and url["host"] == @npm_registry and url["user"] == false and
      url["opaque"] == "" and url["raw_query"] == "" and url["fragment"] == ""
  end

  defp registry_url?(_url), do: false

  @doc """
  The declared outputs of an npm-run of path, checked without the filesystem (validOutputs):
  sorted, distinct, not nested, never node_modules, the manifests or a folder holding the package.
  """
  def valid_outputs(_path, []),
    do:
      {:error,
       "an npm-run preparation declares no --output; declare every path its script writes"}

  def valid_outputs(path, outputs) do
    [modules] = npm_outputs(path)

    outputs
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {output, i}, :ok ->
      previous = if i > 0, do: Enum.at(outputs, i - 1)

      problem =
        cond do
          not safe?(output) ->
            "--output #{go_quote(output)} is not a relative path inside the destination"

          i > 0 and previous >= output ->
            if previous == output,
              do: "--output #{output} is declared twice",
              else: "the outputs of an npm-run preparation are not sorted"

          within?(modules, output) or within?(output, modules) ->
            "--output #{output} overlaps #{modules}, which the npm-ci preparation installed and the script only reads"

          within?(output, path) ->
            "--output #{output} contains the package folder #{path}; declare only the paths the script writes"

          output in [path <> "/package.json", path <> "/package-lock.json"] ->
            "--output #{output} is the package's own manifest"

          other = Enum.find(Enum.take(outputs, i), &(within?(&1, output) or within?(output, &1))) ->
            "--output #{output} is inside --output #{other}; declare each path once"

          true ->
            nil
        end

      if problem, do: {:halt, {:error, problem}}, else: {:cont, :ok}
    end)
  end

  # The runner's plan (host/host/prepare.go)

  @doc """
  The runner's decision for step (prepare, `host/host/prepare.go:67-170`):

    * `{:repeat, result, error}`: the same step was recorded; nothing runs, and the recorded
      outcome is reported (`error` is the not-ready text, or nil);
    * `{:ok, plan}`: `record` (to begin), `codex`, `dir`, `argv`, `env` (scratch paths name
      `#{@scratch}`), `scratch` (`dirs` and `files` the helper creates in it), `writable` and
      `setup_row`, the A2g spec row of its `codex sandbox` setup (`setup_request/3` builds the
      request for `Spec.codex_sandbox(:setup, …)`);
    * `{:error, text}`.

  `opts`: `:env` (the caller's environment, name to value; only `preparationKept` passes),
  `:now` (the record's `started_at`).
  """
  def plan(step, facts, opts \\ []) do
    refusing(fn -> plan!(step, facts, opts) end)
    |> case do
      {:ok, {:repeat, result, error}} -> {:repeat, result, error}
      other -> other
    end
  end

  defp plan!(step, facts, opts) do
    {kind, script, outputs} =
      case step do
        :npm_ci -> {"npm-ci", "", []}
        {:npm_run, script, outputs} -> {"npm-run", script, outputs}
      end

    root = folder!(facts)["root"]
    home = facts["home"]
    path = facts["path"]

    # A folder is prepared once: a repeat of the same step reports its recorded outcome.
    case step(recorded!(facts), kind) do
      nil ->
        :ok

      recorded ->
        if recorded["path"] != path or (recorded["script"] || "") != script or
             (kind == "npm-run" and recorded["outputs"] != Enum.sort(outputs)),
           do:
             refuse(
               "#{root} already has a #{describe(recorded)}; a folder is prepared once, with one npm-ci and at most one npm-run after it; materialize the snapshot into a fresh folder for another"
             )

        {result, error} = outcome(recorded, home)
        throw({:result, {:repeat, result, error}})
    end

    record = begin_record!(step, facts, Keyword.get(opts, :now, now()))
    tools = tools!(facts, root, required_tools(if(kind == "npm-ci", do: :npm_ci, else: :npm_run)))
    writable = for output <- record["outputs"], do: root <> "/" <> output
    dir = root <> "/" <> path

    argv =
      if kind == "npm-ci",
        do: [tools["npm"] | @npm_arguments],
        else: [tools["npm"] | @run_arguments] ++ [script]

    %{
      "record" => record,
      "codex" => tools["codex"],
      "dir" => dir,
      "argv" => argv,
      "env" => environment(kind, Keyword.get(opts, :env, %{})),
      "scratch" => %{
        "dirs" => for({_, name} <- @scratch_dirs, do: name),
        "files" => for({_, name} <- @scratch_files, do: name)
      },
      "writable" => writable,
      "setup_row" => setup_row(kind)
    }
  end

  @doc """
  The `Spec.codex_sandbox(:setup, …)` request of a plan for the folder scope `scope`, with the
  scratch the helper created (`setupArguments` and `prepare.go:152-161`).
  """
  def setup_request(plan, scope, scratch) do
    %{
      "decision" => "codex_sandbox",
      "kind" => "setup",
      "step" => plan["record"]["kind"],
      "scope" => scope,
      "origin" => "client_named",
      "writable" => plan["writable"],
      "scratch" => scratch,
      "dir" => plan["dir"],
      "argv" => Enum.map(plan["argv"], &String.replace(&1, @scratch, scratch))
    }
  end

  # The required tools, each looked up on PATH and never inside the folder (prepare.go:117-132).
  defp tools!(facts, root, required) do
    found = Map.new(facts["tools"] || [], &{&1["name"], &1})

    for {name, refusal} <- required, into: %{} do
      tool = Map.get(found, name, %{"error" => "not looked up"})

      cond do
        Map.has_key?(tool, "error") or not absolute?(tool["found"]) ->
          refuse(refusal)

        Map.has_key?(tool, "resolve_error") ->
          refuse(tool["resolve_error"])

        within?(root, tool["found"]) or within?(root, tool["resolved"]) ->
          refuse("#{name} #{tool["found"]} is inside the folder being prepared")

        true ->
          {name, tool["found"]}
      end
    end
  end

  # preparationEnvironment (host/host/prepare.go:255-279) and npm-run's offline flag (167).
  defp environment(kind, caller) do
    kept = for name <- @kept, Map.has_key?(caller, name), do: "#{name}=#{caller[name]}"
    dirs = for {name, dir} <- @scratch_dirs, do: "#{name}=#{@scratch}/#{dir}"
    files = for {name, file} <- @scratch_files, do: "#{name}=#{@scratch}/#{file}"
    fixed = ["npm_config_registry=https://#{@npm_registry}/", "npm_config_update_notifier=false"]
    offline = if kind == "npm-run", do: ["npm_config_offline=true"], else: []
    kept ++ dirs ++ files ++ fixed ++ offline
  end

  # Facts

  defp folder!(%{"folder" => %{"error" => error}}), do: refuse(error)
  defp folder!(%{"folder" => folder}), do: folder

  defp recorded!(facts) do
    case load(facts["preparation"] || %{"absent" => true}, facts["home"], folder!(facts)["root"]) do
      {:ok, record} -> record
      {:error, text} -> refuse(text)
    end
  end

  defp tracked(facts) do
    case facts["tracked"] do
      %{"error" => error} -> refuse(error)
      entries -> Map.new(entries, &{&1["path"], &1["kind"]})
    end
  end

  # tracks: the first tracked path within output.
  defp tracks(tracked, output) do
    tracked |> Map.keys() |> Enum.filter(&within?(output, &1)) |> Enum.min(fn -> nil end)
  end

  defp owner(repositories, path), do: Enum.find(repositories || [], &within?(&1, path))

  # Rules shared with package snapshot

  # safe (host/snapshot/snapshot.go:487-502): Code's path rule.
  defp safe?(path) when is_binary(path) do
    String.valid?(path) and not String.contains?(path, ["\\", "\x7f"]) and
      not Enum.any?(:binary.bin_to_list(path), &(&1 < 0x20)) and
      Enum.all?(String.split(path, "/"), fn segment ->
        segment not in ["", ".", ".."] and String.downcase(segment, :ascii) != ".git"
      end)
  end

  defp safe?(_path), do: false

  defp within?(dir, path) when is_binary(dir) and is_binary(path),
    do: path == dir or String.starts_with?(path, dir <> "/")

  defp within?(_dir, _path), do: false

  defp absolute?(path), do: is_binary(path) and String.starts_with?(path, "/")

  # unicode.IsSpace: what strings.TrimSpace and strings.Fields cut on.
  @go_space [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680] ++
              Enum.to_list(0x2000..0x200A) ++ [0x2028, 0x2029, 0x202F, 0x205F, 0x3000]

  defp go_fields(nil), do: []
  defp go_fields(text), do: go_fields_split(text)

  defp go_fields_split(text) do
    text
    |> String.to_charlist()
    |> Enum.chunk_by(&(&1 in @go_space))
    |> Enum.reject(fn chunk -> hd(chunk) in @go_space end)
    |> Enum.map(&List.to_string/1)
  end

  # strconv.Quote (Go's %q) for the texts that quote a path or name: printable characters as
  # they are, `"` and `\` escaped, the C escapes, other control bytes as \xNN, other
  # non-printable runes as \uNNNN.
  defp go_quote(text) when is_binary(text) do
    escaped =
      text
      |> String.codepoints()
      |> Enum.map(fn
        "\"" -> "\\\""
        "\\" -> "\\\\"
        "\a" -> "\\a"
        "\b" -> "\\b"
        "\f" -> "\\f"
        "\n" -> "\\n"
        "\r" -> "\\r"
        "\t" -> "\\t"
        "\v" -> "\\v"
        <<c>> when c < 0x20 or c == 0x7F -> "\\x" <> hex2(c)
        <<c::utf8>> when (c >= 0x80 and c < 0xA0) or c == 0xAD -> "\\u" <> hex4(c)
        char -> char
      end)

    "\"" <> Enum.join(escaped) <> "\""
  end

  defp hex2(c), do: c |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")
  defp hex4(c), do: c |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")

  defp nil_if_empty(value) when value in [nil, ""], do: nil
  defp nil_if_empty(value), do: value

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp refusing(fun) do
    {:ok, fun.()}
  catch
    {:refuse, text} -> {:error, text}
    {:result, result} -> {:ok, result}
  end

  defp refuse(text), do: throw({:refuse, text})
end

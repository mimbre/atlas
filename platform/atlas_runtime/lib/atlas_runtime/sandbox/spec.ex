defmodule AtlasRuntime.Sandbox.Spec do
  @moduledoc """
  The sandbox spec decision (S6 §12 move 2, package A2e; shadow: nothing calls it in the
  launch path until C2).

  `build/2` decides an agent's spec and `codex_sandbox/3` a `codex sandbox` run's spec, in the
  neutral shape B7 names and `host/host/render.go` renders (`DecodeSpec`): every entry list,
  network choice, tool list, permission mode, environment change, the 44-byte rule and the
  inspector re-allow. They are pure functions of a request and the raw facts of
  `atlas-runtime workspace facts launch` (`host/workspace/facts_launch.go`), fetched with
  `AtlasRuntime.Sandbox.Facts.fetch("launch", [], facts_input(request))`; they do no I/O.
  A refusal is `{:error, text}` with today's exact text (B3).

  Each rule names the Go code it replaces, which stays the decision until C2. The parity table
  is `test/fixtures/s6/spec/` (A2g); the Go test asserts the same rows against the legacy code.

  ## Request

  A map with string keys, as a row's `input` (`test/fixtures/s6/spec/README.md`):
  `harness` (`codex` | `claude`), `scope` (the permission scope) or `sandbox` and `workspace`
  (a plain turn), `folder` (a Codex folder turn's folder: its scratch is
  `<scope home>/scratch/<basename>`), `inspector`, `questions`, `origin` (`runtime_chosen` |
  `client_named`, B13: the start form decides it, never the path) and, for Claude with a
  scope, `temporary` (the private temp whose length the 44-byte rule checks; spec paths name
  it `$TEMPORARY`). A `codex_sandbox/3` request has `scope`, `origin` and, for `:setup`,
  `step`, `writable` and `scratch`.

  ## Runtime home

  The denied home is the scope's own `home` when it names one, else the helper's own home
  (`deniedRuntimeHome`, `host.go:641-658`, reported as the fact `own_home`). Production passes
  the Runtime's `state.dir` as both (`service.ex:636`, `native.ex:126-127`). `env.unset` always
  lists `ATLAS_RUNTIME_HOME`.
  """

  alias AtlasRuntime.Sandbox.HomeLayout

  # The private temp in spec paths (render.TemporaryToken): decided before the helper creates it.
  @temporary "$TEMPORARY"

  # The user's known credential and control locations, relative to the user home
  # (credentialPaths, codex.go:283-284).
  @credential_paths [
    ".codex",
    ".config/gh",
    ".ssh",
    ".aws",
    ".docker",
    "Library/Keychains",
    ".git-credentials",
    ".config/git",
    ".netrc",
    ".claude",
    ".claude.json",
    ".local/state/atlas-runtime",
    ".gitconfig",
    ".erlang.cookie"
  ]

  # The toolchain locations a folder worker may read in its denied user home: asdf and
  # .tool-versions, Mix archives, the Hex cache, the Go module cache and the pinned rela (homeReadNames,
  # codex.go:290).
  @home_read_names [".asdf", ".tool-versions", ".hex", ".mix", "go/pkg/mod", ".cache/atlas"]

  # A preparation also denies ~/.npmrc (setupArguments, codex.go:460).
  @setup_names [".npmrc"]

  # snapshot.NPMRegistry (host/snapshot/prepare.go:20).
  @npm_registry "registry.npmjs.org"

  # The domains a dedicated repository reaches (repositoryArguments, codex.go:77-78).
  @repository_domains ["github.com", "api.github.com"]

  # Claude 2.1.280 redirects a longer child-temp path to the shared /tmp/claude-<uid>
  # (claudeTemporaryRoots, claude.go:476-479).
  @child_temp_limit 44

  # A folder repository's own Git entries an agent reads but never writes (repositoryGitNames).
  @repository_git_names ["config", "hooks"]

  @claude_repository_denies [".agents", ".codex", ".aws", ".claude", ".git/config", ".git/hooks"]

  @folder_caches [
    {"TMPDIR", "tmp"},
    {"GOCACHE", "go-build"},
    {"GOTMPDIR", "go-tmp"},
    {"XDG_CACHE_HOME", "cache"},
    {"npm_config_cache", "npm"}
  ]

  @doc "The private-temp token in spec paths."
  def temporary_token, do: @temporary

  @doc "The credential paths, relative to the user home (credentialPaths)."
  def credential_paths, do: @credential_paths

  @doc "The toolchain paths a folder worker may read, relative to the user home (homeReadNames)."
  def home_read_names, do: @home_read_names

  @doc """
  The `launch` facts input for `request` (B4, R4): the name lists come from here, never from
  the helper.
  """
  def facts_input(request) do
    scope = scope(request)
    home = text(scope["home"])
    root = scope["root"]
    profile = scope["profile"]

    %{
      "user_names" => %{
        "credential" => @credential_paths,
        "read" => @home_read_names,
        "setup" => @setup_names
      },
      "homes" => if(home != "", do: [home], else: []),
      "home_names" => HomeLayout.names(),
      "paths" =>
        ["/tmp", "/var/tmp"] ++
          if(is_binary(request["workspace"]) and request["workspace"] != "",
            do: [request["workspace"]],
            else: []
          ),
      "root" =>
        if(profile == "dedicated-repository" and is_binary(root) and absolute?(root),
          do: clean(root),
          else: ""
        ),
      "markers" =>
        if(
          profile == "materialized-folder" and is_binary(root) and home != "",
          do: [%{"home" => home, "root" => root}],
          else: []
        )
    }
  end

  @doc """
  The spec of an agent launch (`permissionArguments`/`sandboxArguments` for Codex,
  `claudeCommand` and the `claude*Settings` for Claude, `host.go:110-155, 250-322`).
  """
  def build(request, facts) do
    refusing(fn ->
      scope = request["scope"]
      home = runtime_home(text(scope(request)["home"]), facts)

      spec = %{
        "version" => 1,
        "harness" => request["harness"],
        "runtime_home" => home,
        "env" => env(),
        "scratch" => ""
      }

      case request["harness"] do
        "codex" -> codex_agent(spec, request, scope, home, facts)
        "claude" -> claude_agent(spec, request, scope, home, facts)
        other -> refuse("Unknown native harness #{inspect(other)}")
      end
    end)
  end

  @doc """
  The spec of a `codex sandbox` run (B12): `:setup` (a preparation step, `setupArguments` and
  `prepare.go:107-166`) or `:pre_exec` (a Claude worker's managed-repository preparation,
  `host.go:690-709`). Whether `codex` resolves is the helper's B8 (d) refusal at render time.
  """
  def codex_sandbox(kind, request, facts) when kind in [:setup, :pre_exec] do
    refusing(fn ->
      scope = scope(request)

      spec = %{
        "version" => 1,
        "harness" => "codex",
        "runner" => "codex-sandbox",
        "kind" => Atom.to_string(kind),
        "env" => env(),
        "scratch" => ""
      }

      codex_sandbox(kind, spec, request, scope, facts)
    end)
  end

  defp codex_sandbox(:setup, spec, request, scope, facts) do
    writable = Enum.map(list(request["writable"]), &text/1)
    scratch = text(request["scratch"])
    user = resolved_user!(facts)
    entries = setup_entries(scope, writable, scratch, user, facts)

    network =
      if request["step"] == "npm-ci",
        do: {domains([@npm_registry]), true},
        else: {network_none(), false}

    {table, proxy} = network

    Map.merge(spec, %{
      "codex" => codex("atlas_setup", ":read-only", entries, table, proxy, ""),
      "runtime_home" => text(scope["home"]),
      "scratch" => scratch,
      "workspace" => workspace(text(scope["root"]), request)
    })
  end

  defp codex_sandbox(:pre_exec, spec, request, scope, facts) do
    home = runtime_home("", facts)
    {codex, root, names} = repository_codex(scope, home, facts)

    spec
    |> Map.merge(%{
      "codex" => codex,
      "runtime_home" => home,
      "workspace" => workspace(root, request)
    })
    |> home_names(names)
  end

  # deniedRuntimeHome (host.go:641-658): the scope's own home, else the helper's own.
  defp runtime_home(scope_home, _facts) when scope_home != "", do: scope_home

  defp runtime_home("", facts) do
    case facts["own_home"] do
      %{"home" => home} -> home
      %{"error" => error} -> refuse(error)
    end
  end

  # Codex agents

  defp codex_agent(spec, request, scope, home, facts) do
    fields = scope(request)
    profile = fields["profile"]
    folder? = profile == "materialized-folder"
    scope_home = text(fields["home"])

    scratch =
      if folder?,
        do: clean(Path.join([scope_home, "scratch", base(text(request["folder"]))])),
        else: ""

    {codex, root, names} =
      cond do
        scope == nil -> plain_codex(request, home, facts)
        profile == "dedicated-repository" -> repository_codex(fields, home, facts)
        profile == "materialized-folder" -> folder_codex(fields, scratch, request, facts)
        true -> refuse("Unknown permission profile")
      end

    spec =
      spec
      |> Map.merge(%{
        "codex" => codex,
        "scratch" => scratch,
        "workspace" => workspace(root, request)
      })
      |> home_names(names)

    if folder?,
      do:
        Map.put(
          spec,
          "env",
          folder_env(spec["env"], scope_home, text(request["inspector"]), scratch)
        ),
      else: spec
  end

  # sandboxArguments (codex.go:89-106): the mode's built-in, the Runtime home and the Code
  # token denied, no network; a workspace below the home keeps the mode's access to it.
  defp plain_codex(request, home, facts) do
    {base, name, access} =
      if request["sandbox"] == "workspace-write",
        do: {":workspace", "atlas_workspace_write", "write"},
        else: {":read-only", "atlas_read_only", "read"}

    workspace = resolved!(facts, text(request["workspace"]))
    denied = runtime_entries(home, workspace, facts)
    denied = if within?(home, workspace), do: [[workspace, access] | denied], else: denied
    {codex(name, base, denied, network_none(), false, ""), workspace, []}
  end

  # repositoryArguments (codex.go:63-83): write the repository and its .git, read .agents,
  # .codex and .aws, deny the Runtime home and the Code token (repositoryRuntimeEntries).
  defp repository_codex(scope, home, facts) do
    root =
      case scope["root"] do
        root when is_binary(root) -> clean(root)
        _ -> refuse("Dedicated repository scope requires a root path")
      end

    entries = [
      [root, "write"],
      [clean(Path.join(root, ".git")), "write"],
      [clean(Path.join(root, ".agents")), "read"],
      [clean(Path.join(root, ".codex")), "read"],
      [clean(Path.join(root, ".aws")), "read"]
    ]

    denied = repository_runtime_entries(home, root, facts)
    names = if within?(home, root), do: HomeLayout.managed_denied(), else: []

    codex =
      codex(
        "atlas_repository",
        ":read-only",
        entries ++ denied,
        domains(@repository_domains),
        true,
        "live"
      )

    {codex, root, names}
  end

  # folderArguments/workerArguments (codex.go:326-428).
  defp folder_codex(scope, scratch, request, facts) do
    # permissionArguments asks for the user home first (codex.go:45-48).
    _ = user_home!(facts)
    root = text(scope["root"])
    entries = worker_entries(scope, [[root, "write"]], scratch, text(request["inspector"]), facts)
    {codex("atlas_folder", ":read-only", entries, loopback(scratch), true, "disabled"), root, []}
  end

  # workerArguments' entry list (codex.go:347-415): write only the project and scratch, deny
  # the user home except the homeReadable toolchain paths, read only the record, baseline and
  # the markers, deny Git metadata, the Runtime home, the Code token and the credentials, and
  # re-allow only the inspector itself inside a denied path.
  defp worker_entries(scope, project, scratch, inspector, facts) do
    root = text(scope["root"])
    home = text(scope["home"])
    record = text(scope["record"])
    baseline = text(scope["baseline"])
    repositories = list(scope["repositories"])

    if root == "" or home == "" or record == "" or baseline == "" or repositories == [] or
         scratch == "" or inspector == "",
       do: refuse("Materialized folder scope is incomplete")

    paths = Enum.map(project, &hd/1)
    writable = for [path, "write"] <- project, do: path
    writable_inspector(inspector, writable ++ [scratch])
    user = resolved_user!(facts)
    socket_denies = socket_entries(home, paths ++ [scratch])

    entries =
      project ++
        [[scratch, "write"], [user, "none"], [home, "none"]] ++
        socket_denies ++
        [[record, "read"], [baseline, "read"], [clean(Path.join(root, ".git")), "none"]]

    entries = entries ++ for path <- present_markers(facts, home, root), do: [path, "read"]
    entries = entries ++ Enum.flat_map(repositories, &repository_git_entries(root, &1))
    denied = denied_entries(home, user, [], paths ++ [scratch], facts)
    none = for [path, "none"] <- entries ++ denied, path != user, do: path
    readable = home_readable(user, none, paths ++ [scratch], facts)
    entries = entries ++ Enum.map(readable, &[&1, "read"]) ++ denied

    if Enum.any?(entries, fn [path, access] -> access == "none" and within?(path, inspector) end),
      do: entries ++ [[inspector, "read"]],
      else: entries
  end

  # setupArguments' entry list (codex.go:438-472).
  defp setup_entries(scope, writable, scratch, user, facts) do
    root = text(scope["root"])
    home = text(scope["home"])
    repositories = list(scope["repositories"])

    if root == "" or home == "" or repositories == [] or writable == [] or scratch == "",
      do: refuse("Materialized folder scope is incomplete")

    outputs =
      for output <- writable do
        if not within?(root, output) or output == root,
          do: refuse("Materialized folder scope is incomplete")

        [output, "write"]
      end

    entries =
      outputs ++
        [[scratch, "write"], [home, "none"], [clean(Path.join(root, ".git")), "none"]] ++
        for(path <- repositories, do: [repository_git(root, path), "none"])

    entries ++ denied_entries(home, user, @setup_names, writable ++ [scratch], facts)
  end

  defp repository_git(root, path) when is_binary(path), do: clean(Path.join([root, path, ".git"]))
  defp repository_git(_root, _path), do: refuse("Materialized folder scope is incomplete")

  # repositoryGitEntries (codex.go): a repository's own .git is the agent's (IS-Atlas-14), in
  # the writable folder, so it may stage and commit there; its configuration and hooks stay
  # read-only. A repository that is the folder itself keeps the folder's .git denied.
  defp repository_git_entries(root, path) do
    git = repository_git(root, path)

    if git == clean(Path.join(root, ".git")),
      do: [[git, "none"]],
      else: for(name <- @repository_git_names, do: [join(git, name), "read"])
  end

  # A folder worker's environment (host.go:287-302): the inspector first on PATH, this home and
  # inspector, Git without user or system configuration or user excludes file, and temp and
  # caches in the scratch.
  defp folder_env(env, home, inspector, scratch) do
    caches = for {name, cache} <- @folder_caches, do: {name, scratch <> "/" <> cache}

    %{
      env
      | "prefix_path" => dir(inspector),
        "set" =>
          env["set"] ++
            [
              ["ATLAS_RUNTIME_HOME", home],
              ["ATLAS_RUNTIME_EXECUTABLE", inspector],
              ["GIT_CONFIG_GLOBAL", "/dev/null"],
              ["GIT_CONFIG_NOSYSTEM", "1"],
              ["GIT_CONFIG_COUNT", "1"],
              ["GIT_CONFIG_KEY_0", "core.excludesFile"],
              ["GIT_CONFIG_VALUE_0", "/dev/null"]
            ] ++
            for({name, path} <- caches, do: [name, path]),
        "mkdirs" => env["mkdirs"] ++ for({_name, path} <- caches, do: path)
    }
  end

  # Entry lists (codex.go:111-280, 475-512)

  # runtimeEntries (codex.go:111-132): the home, the Code token and its directory, and the
  # sockets; none may be the project.
  defp runtime_entries(home, project, facts) do
    if home == "" or not absolute?(home), do: refuse("Runtime home must be an absolute path")
    if project == home, do: refuse("Workspace #{project} is the Runtime home")
    token = token_entries(home, [], facts)

    if Enum.any?(token, fn [path, _] -> path == project end),
      do: refuse("Workspace #{project} is the Code token directory")

    [[home, "none"]] ++ token ++ socket_entries(home, [project])
  end

  # socketEntries (codex.go:141-153).
  defp socket_entries(home, projects) do
    for name <- HomeLayout.sockets() do
      path = join(home, name)

      for project <- projects,
          within?(path, project),
          do: refuse("Workspace #{project} is inside the Runtime socket #{path}")

      [path, "none"]
    end
  end

  # repositoryRuntimeEntries (codex.go:184-216): a home or token directory that contains the
  # repository is denied entry by entry off its ancestor chain, and in the home every
  # HomeLayout denied name followed by the atomic temps (sensitiveHomeNames' order, fixed P0)
  # and every sibling worker.
  defp repository_runtime_entries(home, root, facts) do
    denied =
      Enum.flat_map(runtime_entries(home, root, facts), fn [path, _] = entry ->
        if within?(path, root), do: off_chain_entries(path, root, facts), else: [entry]
      end)

    if within?(home, root) do
      names =
        for name <- HomeLayout.managed_denied() do
          path = join(home, name)

          if within?(path, root),
            do: refuse("Repository #{root} is inside the Runtime home's #{path}")

          [path, "none"]
        end

      denied ++ names ++ sibling_worker_globs(home, root)
    else
      denied
    end
  end

  # siblingWorkerGlobs (codex.go:224-258): deny-read globs for every other <home>/workers entry.
  defp sibling_worker_globs(home, root) do
    workers = clean(Path.join(home, HomeLayout.workers()))

    if within?(workers, root) and root != workers do
      [name | _] =
        root |> String.replace_prefix(workers <> "/", "") |> String.split("/", parts: 2)

      unless name |> :binary.bin_to_list() |> Enum.all?(&worker_byte?/1),
        do:
          refuse(
            "Worker directory #{join(workers, name)} cannot be excluded by a Codex deny-read glob"
          )

      prefix =
        for <<byte <- workers>>, into: "" do
          case byte do
            ?\\ -> refuse("Runtime home #{home} cannot be written as a Codex deny-read glob")
            byte when byte in ~c"*?[]{}" -> "[" <> <<byte>> <> "]"
            byte -> <<byte>>
          end
        end

      base = prefix <> "/"
      size = byte_size(name)
      at = fn k -> binary_part(name, k, 1) end

      middle =
        for k <- 1..(size - 1)//1 do
          [
            base <> binary_part(name, 0, k) <> "[!" <> at.(k) <> "]*",
            base <> binary_part(name, 0, k - 1) <> "[" <> at.(k - 1) <> "]"
          ]
        end

      patterns =
        [base <> "[!" <> at.(0) <> "]*"] ++ List.flatten(middle) ++ [base <> name <> "[!/]*"]

      Enum.flat_map(patterns, &[[&1, "none"], [&1 <> "/**", "none"]])
    else
      []
    end
  end

  defp worker_byte?(c),
    do: c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in [?-, ?_, ?.]

  # offChainEntries (codex.go:262-280): every existing entry of top and of each directory below
  # it down to root that is not on the path to root.
  defp off_chain_entries(top, root, facts), do: off_chain(top, root, facts, [])

  defp off_chain(root, root, _facts, acc), do: acc

  defp off_chain(directory, root, facts, acc) do
    [segment | _] =
      root |> String.replace_prefix(directory <> "/", "") |> String.split("/", parts: 2)

    next = join(directory, segment)

    if next == directory,
      do: raise(ArgumentError, "no ancestor chain from #{directory} to #{root}")

    case listing(facts, directory) do
      "absent" ->
        acc

      %{"error" => error} ->
        refuse(error)

      %{"entries" => names} ->
        denied = for name <- names, (path = join(directory, name)) != next, do: [path, "none"]
        off_chain(next, root, facts, acc ++ denied)
    end
  end

  # tokenEntries (codex.go:475-487).
  defp token_entries(home, writable, facts) do
    case code_token(home, facts) do
      "" ->
        []

      token ->
        directory = dir(token)

        for path <- writable,
            path == directory or String.starts_with?(path, directory <> "/"),
            do: refuse("Code token directory #{directory} contains #{path}")

        [[token, "none"], [directory, "none"]]
    end
  end

  # codeToken (codex.go:555-569), decided on code.json as written.
  defp code_token(home, facts) do
    case home_facts!(facts, home)["code_json"] do
      "absent" ->
        ""

      %{"read_error" => error} ->
        refuse(error)

      %{"token_file" => token_file} = fact ->
        unless absolute?(token_file), do: refuse(code_json_refusal())

        case fact["token"] do
          %{"resolved" => token} -> token
          %{"error" => error} -> refuse(error)
        end

      %{"error" => "decode"} ->
        refuse(code_json_refusal())
    end
  end

  defp code_json_refusal, do: "Runtime code.json must name an absolute token_file"

  # deniedEntries (codex.go:491-512): the token entries, the credential paths plus extra
  # (relative to user) and CODEX_HOME, resolved.
  defp denied_entries(home, _user, extra, writable, facts) do
    token = token_entries(home, writable, facts)
    credentials = Enum.map(@credential_paths, &user_name!(facts, "credential", &1))
    extras = Enum.map(extra, &user_name!(facts, "setup", &1))
    token ++ Enum.map(credentials ++ extras ++ codex_home(facts), &[&1, "none"])
  end

  defp codex_home(facts) do
    case facts["env_paths"]["CODEX_HOME"] do
      nil -> []
      fact -> [resolution!(fact)]
    end
  end

  # homeReadable (codex.go:296-318): each absolute PATH entry and each homeReadNames entry,
  # resolved, when it is inside user (not user itself) and inside no denied or writable path.
  defp home_readable(user, denied, writable, facts) do
    covered = denied ++ writable

    candidates =
      for(entry <- facts["path_entries"], absolute?(entry["entry"]), do: entry) ++
        Enum.map(@home_read_names, &user_name_fact!(facts, "read", &1))

    Enum.reduce(candidates, [], fn candidate, readable ->
      path = resolution!(candidate)

      if path == user or not within?(user, path) or path in readable or
           Enum.any?(covered, &within?(&1, path)),
         do: readable,
         else: readable ++ [path]
    end)
  end

  # writableInspector (codex.go:545-552).
  defp writable_inspector(inspector, writable) do
    for path <- writable, within?(path, inspector) do
      refuse(
        "Runtime executable #{inspector} is inside worker-writable #{path}; install atlas-runtime outside the materialized folder and worker temp"
      )
    end

    :ok
  end

  # Claude

  defp claude_agent(spec, request, scope, home, facts) do
    base_tools =
      if scope != nil, do: ["Bash", "Read", "Glob", "Grep"], else: ["Read", "Glob", "Grep"]

    temporary = if scope != nil, do: text(request["temporary"]), else: ""

    {spec, settings, root} =
      if scope != nil do
        fields = scope(request)
        user = resolved_user!(facts)
        inspector = text(request["inspector"])
        root = clean(text(fields["root"]))

        spec = %{
          spec
          | "env" => %{spec["env"] | "set" => [["CLAUDE_CODE_TMPDIR", @temporary]]}
        }

        spec = Map.put(spec, "temporary", %{"parent" => user})

        case fields["profile"] do
          "materialized-folder" ->
            settings = claude_folder_settings(fields, temporary, user, inspector, facts)

            spec = %{
              spec
              | "scratch" => @temporary,
                "env" => folder_env(spec["env"], text(fields["home"]), inspector, @temporary)
            }

            {spec, settings, root}

          _ ->
            {spec, claude_repository_settings(fields, temporary, home, facts), root}
        end
      else
        workspace = text(request["workspace"])
        settings = claude_read_only_settings(workspace, home, facts)
        root = resolved!(facts, workspace)

        # The file tools' Read rules cannot deny a home containing the workspace
        # (claude.go:483-486): the spec names the sockets it does deny.
        spec = if within?(home, root), do: home_names(spec, HomeLayout.sockets()), else: spec
        {spec, settings, root}
      end

    settings = if temporary != "", do: tokenize(settings, temporary), else: settings

    {tools, mode} =
      if request["questions"] == true,
        do: {base_tools ++ ["AskUserQuestion"], "manual"},
        else: {base_tools, "dontAsk"}

    Map.merge(spec, %{
      "claude" => %{
        "tools" => tools,
        "allowed_tools" => base_tools,
        "permission_mode" => mode,
        "settings" => settings
      },
      "workspace" => workspace(root, request)
    })
  end

  # claudeRepositorySettings (claude.go:258-294).
  defp claude_repository_settings(scope, temporary, home, facts) do
    root =
      case scope["root"] do
        root when is_binary(root) -> clean(root)
        _ -> refuse("Dedicated repository scope requires a root path")
      end

    roots = claude_temporary_roots(root, temporary, "Claude dedicated repositories", facts)
    own = for name <- @claude_repository_denies, do: join(root, name)

    {deny, deny_read, allow_read, rules} =
      Enum.reduce(runtime_entries(home, root, facts), {roots ++ own, [], [], []}, fn [path, _],
                                                                                     {deny,
                                                                                      deny_read,
                                                                                      allow_read,
                                                                                      rules} ->
        deny_read = deny_read ++ [path]

        case Enum.filter([root, temporary], &within?(path, &1)) do
          [] -> {deny ++ [path], deny_read, allow_read, rules ++ ["Read(/" <> path <> ")"]}
          contained -> {deny, deny_read, allow_read ++ contained, rules}
        end
      end)

    network =
      if facts["platform"] == "darwin",
        do: %{"allowMachLookup" => ["com.apple.trustd.agent"]},
        else: %{}

    settings(
      sandbox(
        %{
          "allowWrite" => [root, temporary],
          "denyWrite" => deny,
          "denyRead" => deny_read,
          "allowRead" => allow_read
        },
        Map.merge(%{"allowedDomains" => scope["network_hosts"]}, network),
        false
      ),
      rules
    )
  end

  # claudeFolderSettings/claudeWorkerSettings (claude.go:306-451) for a materialized folder:
  # writable is the folder, nothing is frozen, and Bash may open pseudo-terminals.
  defp claude_folder_settings(scope, temporary, user, inspector, facts) do
    root = text(scope["root"])
    home = text(scope["home"])
    record = text(scope["record"])
    baseline = text(scope["baseline"])
    repositories = list(scope["repositories"])
    writable = [root]
    frozen = []

    if root == "" or home == "" or record == "" or baseline == "" or repositories == [] or
         inspector == "",
       do: refuse("Materialized folder scope is incomplete")

    project = frozen ++ writable

    roots =
      Enum.reduce(project, nil, fn path, _ ->
        claude_temporary_roots(path, temporary, "Claude materialized folders", facts)
      end)

    writable_inspector(inspector, writable ++ [temporary])
    sockets = for [path, _] <- socket_entries(home, project ++ [temporary]), do: path

    # A repository's own .git is the agent's (claude.go): only the folder's is protected; its
    # configuration and hooks are read-only (git_read_only).
    protected = [home] ++ sockets ++ [clean(Path.join(root, ".git"))]

    protected =
      case code_token(home, facts) do
        "" -> protected
        token -> protected ++ [token, dir(token)]
      end

    configuration = claude_configuration(facts)

    credentials =
      [configuration] ++
        Enum.map(@credential_paths, &user_name!(facts, "credential", &1)) ++ codex_home(facts)

    protected =
      Enum.reduce(credentials, protected, fn path, protected ->
        if path in protected, do: protected, else: protected ++ [path]
      end)

    for path <- protected,
        allowed <- project ++ [temporary],
        allowed == path or String.starts_with?(allowed, path <> "/"),
        do: refuse("Protected path #{path} contains #{allowed}")

    rules =
      Enum.map(protected, &("Read(/" <> &1 <> ")")) ++
        for tool <- ["Edit", "Write"], path <- frozen, do: tool <> "(/" <> path <> ")"

    markers = present_markers(facts, home, root)

    allow_read =
      [
        record,
        baseline,
        clean(Path.join(configuration, "shell-snapshots")),
        clean(Path.join(configuration, "session-env"))
      ] ++
        markers

    git_read_only =
      for path <- repositories,
          [entry, "read"] <- repository_git_entries(root, path),
          do: entry

    read_only = frozen ++ [record, baseline] ++ markers ++ git_read_only
    readable = home_readable(user, protected, project ++ [temporary], facts)
    allow_read = allow_read ++ project ++ [temporary] ++ readable

    allow_read =
      if within?(user, inspector) or Enum.any?(protected, &within?(&1, inspector)),
        do: allow_read ++ [inspector],
        else: allow_read

    settings(
      sandbox(
        %{
          "allowWrite" => writable ++ [temporary],
          "denyWrite" => roots ++ protected ++ read_only,
          "denyRead" => [user | protected],
          "allowRead" => allow_read
        },
        %{
          "allowedDomains" => [],
          "strictAllowlist" => true,
          "allowUnixSockets" => [temporary],
          "allowLocalBinding" => true
        },
        true
      ),
      rules
    )
  end

  # CLAUDE_CONFIG_DIR, else ~/.claude, resolved (claude.go:373-376, 415).
  defp claude_configuration(facts) do
    case facts["env_paths"]["CLAUDE_CONFIG_DIR"] do
      nil -> user_name!(facts, "credential", ".claude")
      fact -> resolution!(fact)
    end
  end

  # claudeTemporaryRoots (claude.go:455-481): root outside every system temp root, and the
  # private temp within Claude's child-temp limit.
  defp claude_temporary_roots(root, temporary, subject, facts) do
    system =
      case facts["system_temp"] do
        %{"error" => error} -> refuse(error)
        fact -> resolution!(fact)
      end

    roots =
      [resolved!(facts, "/tmp"), resolved!(facts, "/var/tmp"), system]
      |> Enum.uniq()
      |> Enum.sort()

    for path <- roots,
        root == path or String.starts_with?(root, String.replace_suffix(path, "/", "") <> "/"),
        do: refuse(subject <> " must be outside system temporary directories")

    if byte_size(join(temporary, "claude-" <> Integer.to_string(facts["uid"]))) >
         @child_temp_limit,
       do: refuse("Claude private native temp path exceeds the 44-byte child-temp limit")

    roots
  end

  # claudeReadOnlySettings (claude.go:487-505): Read rules for the denied entries that do not
  # contain the workspace; no sandbox (the turn has no Bash).
  defp claude_read_only_settings(workspace, home, facts) do
    workspace = resolved!(facts, workspace)

    rules =
      for [path, _] <- runtime_entries(home, workspace, facts),
          not within?(path, workspace),
          do: "Read(/" <> path <> ")"

    %{"permissions" => %{"deny" => rules}}
  end

  # The claudeSettings JSON (claude.go:217-251) with its omitempty fields left out.
  defp settings(sandbox, rules),
    do: %{"sandbox" => sandbox, "permissions" => %{"deny" => nil_if_empty(rules)}}

  defp sandbox(filesystem, network, pty) do
    filesystem = omit_empty(filesystem, ["denyRead", "allowRead"])

    network =
      %{"allowAllUnixSockets" => false, "allowLocalBinding" => false}
      |> Map.merge(network)
      |> omit_empty(["allowUnixSockets", "allowMachLookup"])
      |> Map.reject(fn {key, value} -> key == "strictAllowlist" and value != true end)

    sandbox = %{
      "enabled" => true,
      "failIfUnavailable" => true,
      "allowUnsandboxedCommands" => false,
      "excludedCommands" => [],
      "filesystem" => filesystem,
      "network" => network
    }

    if pty, do: Map.put(sandbox, "allowPty", true), else: sandbox
  end

  defp omit_empty(map, keys),
    do: Map.reject(map, fn {key, value} -> key in keys and value in [nil, []] end)

  defp nil_if_empty([]), do: nil
  defp nil_if_empty(list), do: list

  # The private temp's paths in the sandbox become $TEMPORARY (render.go withTemporary's inverse).
  defp tokenize(%{"sandbox" => sandbox} = settings, temporary) do
    replace = fn paths ->
      Enum.map(paths, fn path ->
        if path == temporary or String.starts_with?(path, temporary <> "/"),
          do: @temporary <> String.replace_prefix(path, temporary, ""),
          else: path
      end)
    end

    filesystem =
      Map.new(sandbox["filesystem"], fn {key, paths} -> {key, replace.(paths)} end)

    network =
      case sandbox["network"] do
        %{"allowUnixSockets" => sockets} = network ->
          %{network | "allowUnixSockets" => replace.(sockets)}

        network ->
          network
      end

    %{settings | "sandbox" => %{sandbox | "filesystem" => filesystem, "network" => network}}
  end

  defp tokenize(settings, _temporary), do: settings

  # Spec parts

  defp env,
    do: %{"set" => [], "unset" => ["ATLAS_RUNTIME_HOME"], "prefix_path" => "", "mkdirs" => []}

  defp workspace(root, request), do: %{"root" => root, "origin" => request["origin"]}

  defp home_names(spec, []), do: spec
  defp home_names(spec, names), do: Map.put(spec, "home_names", names)

  defp codex(profile, base, entries, network, proxy, web_search) do
    %{
      "profile" => profile,
      "base" => base,
      "entries" => entries,
      "network" => network,
      "network_proxy" => proxy,
      "web_search" => web_search
    }
  end

  defp network_none,
    do: %{"mode" => "none", "domains" => [], "unix_sockets" => [], "local_binding" => false}

  defp domains(domains),
    do: %{
      "mode" => "domains",
      "domains" => domains,
      "unix_sockets" => [],
      "local_binding" => false
    }

  defp loopback(scratch),
    do: %{
      "mode" => "loopback",
      "domains" => [],
      "unix_sockets" => [scratch],
      "local_binding" => true
    }

  # Facts

  defp home_facts!(facts, home) do
    case facts["homes"] do
      %{^home => fact} -> fact
      _ -> raise ArgumentError, "the launch facts do not cover the Runtime home #{home}"
    end
  end

  defp listing(facts, directory) do
    case facts["listings"] do
      %{^directory => listing} -> listing
      _ -> raise ArgumentError, "the launch facts do not list #{directory}"
    end
  end

  defp present_markers(facts, home, root) do
    marker =
      Enum.find(facts["markers"], &(&1["home"] == home and &1["root"] == root)) ||
        raise ArgumentError, "the launch facts lack the markers of #{root}"

    for kind <- ["rebind", "preparation"], reduce: [] do
      present ->
        case marker[kind] do
          %{"error" => error} -> refuse(error)
          %{"present" => true, "path" => path} -> present ++ [path]
          %{"present" => false} -> present
        end
    end
  end

  defp user_home!(facts) do
    case facts["user"] do
      %{"home" => home} -> home
      %{"error" => error} -> refuse(error)
    end
  end

  defp resolved_user!(facts) do
    _ = user_home!(facts)

    case facts["user"] do
      %{"resolved" => user} -> user
      %{"error" => error} -> refuse(error)
    end
  end

  defp user_name!(facts, list, name), do: resolution!(user_name_fact!(facts, list, name))

  defp user_name_fact!(facts, list, name) do
    Enum.find(facts["user_names"][list] || [], &(&1["name"] == name)) ||
      raise ArgumentError, "the launch facts do not resolve #{list} name #{name}"
  end

  defp resolved!(facts, path) do
    case facts["resolved"] do
      %{^path => fact} -> resolution!(fact)
      _ -> raise ArgumentError, "the launch facts do not resolve #{path}"
    end
  end

  defp resolution!(%{"resolved" => path}), do: path
  defp resolution!(%{"error" => error}), do: refuse(error)

  # Refusals

  defp refusing(fun) do
    {:ok, fun.()}
  catch
    {:refuse, text} -> {:error, text}
  end

  defp refuse(text), do: throw({:refuse, text})

  # Values and Go's path functions (path/filepath on Unix)

  defp scope(%{"scope" => scope}) when is_map(scope), do: scope
  defp scope(_request), do: %{}

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: ""

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []

  defp absolute?(path), do: String.starts_with?(path, "/")

  @doc false
  def within?(dir, path), do: path == dir or String.starts_with?(path, dir <> "/")

  # filepath.Join of two elements.
  defp join(left, right) do
    case Path.join(left, right) do
      "" -> ""
      joined -> clean(joined)
    end
  end

  @doc false
  # filepath.Clean.
  def clean(""), do: "."

  def clean(path) do
    rooted = String.starts_with?(path, "/")

    parts =
      path
      |> String.split("/")
      |> Enum.reject(&(&1 in ["", "."]))
      |> Enum.reduce([], fn
        "..", [previous | rest] when previous != ".." -> rest
        "..", [] when rooted -> []
        part, acc -> [part | acc]
      end)
      |> Enum.reverse()

    case {rooted, parts} do
      {true, parts} -> "/" <> Enum.join(parts, "/")
      {false, []} -> "."
      {false, parts} -> Enum.join(parts, "/")
    end
  end

  # filepath.Dir.
  defp dir(path) do
    case :binary.matches(path, "/") do
      [] -> "."
      matches -> clean(binary_part(path, 0, elem(List.last(matches), 0) + 1))
    end
  end

  # filepath.Base.
  defp base(""), do: "."

  defp base(path) do
    case String.trim_trailing(path, "/") do
      "" -> "/"
      trimmed -> trimmed |> String.split("/") |> List.last()
    end
  end
end

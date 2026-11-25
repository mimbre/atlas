defmodule AtlasAgent.RuntimeInstall do
  @moduledoc """
  `atlas runtime install` (IS-Atlas-116, UC-Atlas-50): a supervisor gets, from Control,
  the one command that installs a Runtime on a Mac.

      atlas runtime install --machine <name> --workers <w1,w2> --for <holder> \\
        --build <released build> --source <work source URL> --git <Code Git URL> \\
        [--releases <URL>] [--new-credential] [--env test|prod]

  It makes the machinery `<name>` in the environment through Control (`put machinery`,
  linked `runs_for` the supervisor), with the sha256 of a credential it makes here: 32
  random bytes, which never reach Control, rela or a log. Flow's work source and Code's
  Git endpoint admit the Runtime by it (the credentials registered in Facts), without a
  core secret. Then it prints the install command, with the credential in the environment
  of the installer (`ATLAS_RUNTIME_CREDENTIAL=…`), never in a process's arguments. The
  installer (`atlas-runtime-install.sh` of the release `atlas-runtime-<build>`) installs
  the released Runtime and Code, writes `machine.json` and the credential file, and runs
  `install.sh`, which loads the launch agents.

  The credential is shown once. For a machinery that is there already the command is
  refused, unless `--new-credential` replaces its credential (the old one is turned away
  within 10 s) and prints the command with the new one.
  """

  @releases "https://github.com/mimbre/atlas/releases/download"
  @name ~r/\A[a-z][a-z0-9-]{0,23}\z/
  @worker ~r/\A[a-z][a-z0-9_-]{0,63}\z/
  @build ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/
  @holder ~r/\A[A-Za-z0-9._-]{1,64}\z/

  @usage """
  atlas runtime install --machine <name> --workers <w1,w2> --for <holder> --build <build>
                        --source <work source https URL> --git <Code Git https URL>
                        [--releases <URL>] [--new-credential]
  """

  def usage, do: @usage

  @doc "The options of `atlas runtime install ARGS`: `{:ok, options}` or `{:error, why}`."
  def options(args) do
    {renew?, args} = {"--new-credential" in args, List.delete(args, "--new-credential")}

    with {:ok, flags} <- flags(args, %{}),
         {:ok, machine} <-
           want(
             flags,
             "machine",
             &Regex.match?(@name, &1),
             "a lower-case name of at most 24 letters, digits or -, e.g. mac-mini"
           ),
         {:ok, workers} <-
           want(
             flags,
             "workers",
             &workers?/1,
             "a comma-separated list of worker names, e.g. dev1,dev2"
           ),
         {:ok, holder} <-
           want(
             flags,
             "for",
             &Regex.match?(@holder, &1),
             "the key of the supervisor whose work it takes"
           ),
         {:ok, build} <-
           want(
             flags,
             "build",
             &Regex.match?(@build, &1),
             "a released build, e.g. master-0123456789ab"
           ),
         {:ok, source} <- want(flags, "source", &https?/1, "the work source's https:// URL"),
         {:ok, git} <- want(flags, "git", &https?/1, "Code's Git endpoint's https:// URL"),
         {:ok, releases} <- releases(flags["releases"]),
         [] <- Map.keys(flags) -- ~w(machine workers for build source git releases) do
      {:ok,
       %{
         machine: machine,
         workers: String.split(workers, ","),
         for: holder,
         build: build,
         source: source,
         git: git,
         releases: releases,
         renew: renew?
       }}
    else
      unknown when is_list(unknown) ->
        {:error, "unknown option --#{hd(unknown)}\n" <> @usage}

      error ->
        error
    end
  end

  @doc "A new credential: 32 random bytes, base64url without padding (a bearer token68)."
  def credential, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  @doc "Its sha256 as Flow keeps it: 64 lowercase hex."
  def sha256(credential), do: Base.encode16(:crypto.hash(:sha256, credential), case: :lower)

  @doc """
  The install command for `options` in environment `env` with `credential`: the
  installer, fetched from the release, run by zsh with its arguments, the credential in
  its environment only.
  """
  def command(options, env, credential) do
    installer = "#{options.releases}/atlas-runtime-#{options.build}/atlas-runtime-install.sh"

    args =
      [
        "--build",
        options.build,
        "--env",
        env,
        "--machine",
        options.machine,
        "--workers",
        Enum.join(options.workers, ","),
        "--source",
        options.source,
        "--git",
        options.git
      ] ++ if(options.releases == @releases, do: [], else: ["--releases", options.releases])

    "curl -fsSL #{sh_quote(installer)} | ATLAS_RUNTIME_CREDENTIAL=#{sh_quote(credential)} /bin/zsh -s -- " <>
      Enum.map_join(args, " ", &sh_quote/1)
  end

  @doc """
  Makes (or, with `renew`, gives a new credential to) the machinery through `client`, then
  `{:runtime_install, %{"machinery", "for", "command"}}`; a refusal as Control gave it.
  """
  def run(options, client, api \\ AtlasAgent) do
    credential = credential()
    sha = sha256(credential)
    cause = "atlas runtime install: #{options.machine} for #{options.for}"

    made =
      case {api.get(client, options.machine), options.renew} do
        {{:ok, _item}, false} ->
          {:refused,
           [
             "#{options.machine} is there already; its credential cannot be shown again. " <>
               "Give it a new one with --new-credential"
           ]}

        {{:ok, _item}, true} ->
          api.set(
            client,
            options.machine,
            %{"credential_sha256" => sha, "runs_for" => options.for},
            cause
          )

        {_none, _renew} ->
          with {:ok, key} <-
                 api.put(
                   client,
                   "machinery",
                   %{"name" => options.machine, "credential_sha256" => sha},
                   nil,
                   cause
                 ) do
            case api.set(client, key, %{"runs_for" => options.for}, cause) do
              {:ok, key} ->
                {:ok, key}

              {:refused, reasons} ->
                {:refused, ["#{key} is made, but not linked to #{options.for}" | reasons]}

              other ->
                other
            end
          end
      end

    case made do
      {:ok, key} ->
        {:runtime_install,
         %{
           "machinery" => key,
           "for" => options.for,
           "command" => command(options, client.env, credential)
         }}

      other ->
        other
    end
  end

  @doc "What `atlas runtime install` prints."
  def text(%{"machinery" => key, "for" => holder, "command" => command}) do
    """
    Machinery #{key} is made for #{holder}. Control keeps only the sha256 of its credential,
    which is in the command below and shown only now.

    On the Mac, logged in as the user that runs the Runtime, run:

     #{command}

    It installs the released Runtime and Code and loads their launch agents; running it again
    changes nothing. The credential is in the installer's environment, never in a process's
    arguments; the command starts with a space, so a shell with HIST_IGNORE_SPACE keeps it
    out of its history. Then give the Runtime its configuration through Control:

      atlas set #{key} configuration=@policy.json
    """
  end

  defp flags(["--" <> name, value | rest], flags) when name != "",
    do: flags(rest, Map.put(flags, name, value))

  defp flags([], flags), do: {:ok, flags}
  defp flags(args, _flags), do: {:error, "unexpected #{Enum.join(args, " ")}\n" <> @usage}

  defp want(flags, name, check, what) do
    case flags[name] do
      nil -> {:error, "runtime install needs --#{name}: #{what}\n" <> @usage}
      value -> if check.(value), do: {:ok, value}, else: {:error, "--#{name} must be #{what}"}
    end
  end

  defp releases(nil), do: {:ok, @releases}

  defp releases(url),
    do:
      if(https?(url),
        do: {:ok, String.trim_trailing(url, "/")},
        else: {:error, "--releases must be an https:// URL"}
      )

  defp workers?(text) do
    names = String.split(text, ",")
    Enum.all?(names, &Regex.match?(@worker, &1)) and Enum.uniq(names) == names
  end

  defp https?(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil}
      when is_binary(host) and host != "" ->
        not String.match?(url, ~r/[\s'"\\\x00-\x1f\x7f]/)

      _ ->
        false
    end
  end

  # Single quotes for zsh; every value is checked to hold none.
  defp sh_quote(text), do: "'" <> text <> "'"
end

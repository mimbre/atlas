defmodule AtlasAgent.RuntimeInstallTest do
  # IS-Atlas-116: `atlas runtime install` makes the machinery with only the sha256 of a
  # credential made here, links its supervisor, and prints the install command, the
  # credential in the installer's environment and never in a process's arguments.
  use ExUnit.Case, async: true

  alias AtlasAgent.RuntimeInstall

  @args ~w(--machine new-mac --workers dev1,dev2 --for ada --build master-0123456789ab
           --source https://flow.example.ts.net:7596 --git https://flow.example.ts.net:7597)

  defmodule Api do
    @moduledoc "Control, as far as the command uses it: what was asked goes to the test."
    def get(%{test: test, existing: existing}, key) do
      send(test, {:get, key})
      if key in existing, do: {:ok, %{"key" => key}}, else: {:error, "#{key} not found"}
    end

    def put(%{test: test}, kind, values, parent, _cause) do
      send(test, {:put, kind, values, parent})
      {:ok, values["name"]}
    end

    def set(%{test: test}, key, values, _cause) do
      send(test, {:set, key, values})
      {:ok, key}
    end
  end

  defp client(existing \\ []), do: %{env: "prod", test: self(), existing: existing}

  test "options: every one checked, the credential never one of them" do
    assert {:ok, o} = RuntimeInstall.options(@args)
    assert o.machine == "new-mac" and o.workers == ["dev1", "dev2"] and o.for == "ada"
    refute o.renew

    assert {:error, "runtime install needs --git" <> _} =
             RuntimeInstall.options(Enum.drop(@args, -2))

    assert {:error, "--machine must be" <> _} =
             RuntimeInstall.options(["--machine", "Mac Mini" | Enum.drop(@args, 2)])

    assert {:error, "--source must be" <> _} =
             RuntimeInstall.options(
               Enum.take(@args, 8) ++
                 ["--source", "http://flow.example:7596"] ++ Enum.drop(@args, 10)
             )

    assert {:error, "--workers must be" <> _} =
             RuntimeInstall.options(
               Enum.map(@args, fn
                 "dev1,dev2" -> "dev1,dev1"
                 arg -> arg
               end)
             )

    assert {:error, "unknown option --credential" <> _} =
             RuntimeInstall.options(@args ++ ["--credential", "x"])
  end

  test "it makes the machinery with the credential's sha256 and links its supervisor" do
    {:ok, o} = RuntimeInstall.options(@args)
    assert {:runtime_install, made} = RuntimeInstall.run(o, client(), Api)

    assert_received {:put, "machinery", %{"name" => "new-mac", "credential_sha256" => sha}, nil}
    assert_received {:set, "new-mac", %{"runs_for" => "ada"}}
    assert made["machinery"] == "new-mac"

    [_, credential] = Regex.run(~r/ATLAS_RUNTIME_CREDENTIAL='([^']+)'/, made["command"])
    assert RuntimeInstall.sha256(credential) == sha
    assert byte_size(Base.url_decode64!(credential, padding: false)) == 32

    # The credential is in zsh's environment, not in curl's or zsh's arguments.
    [curl, zsh] = String.split(made["command"], " | ")
    refute curl =~ credential

    assert zsh =~
             ~r{\AATLAS_RUNTIME_CREDENTIAL='[^']+' /bin/zsh -s -- '--build' 'master-0123456789ab' '--env' 'prod' '--machine' 'new-mac' '--workers' 'dev1,dev2'}

    [_, args] = String.split(zsh, " -s -- ")
    refute args =~ credential

    assert curl ==
             "curl -fsSL 'https://github.com/mimbre/atlas/releases/download/atlas-runtime-master-0123456789ab/atlas-runtime-install.sh'"

    assert RuntimeInstall.text(made) =~ "\n #{made["command"]}\n"
  end

  test "a machinery that is there is refused, unless it gets a new credential" do
    {:ok, o} = RuntimeInstall.options(@args)
    assert {:refused, [why]} = RuntimeInstall.run(o, client(["new-mac"]), Api)
    assert why =~ "--new-credential"
    refute_received {:put, _, _, _}
    refute_received {:set, _, _}

    {:ok, o} = RuntimeInstall.options(@args ++ ["--new-credential"])
    assert {:runtime_install, made} = RuntimeInstall.run(o, client(["new-mac"]), Api)
    assert_received {:set, "new-mac", %{"credential_sha256" => sha, "runs_for" => "ada"}}
    [_, credential] = Regex.run(~r/ATLAS_RUNTIME_CREDENTIAL='([^']+)'/, made["command"])
    assert RuntimeInstall.sha256(credential) == sha
  end

  test "each command has its own credential" do
    refute RuntimeInstall.credential() == RuntimeInstall.credential()
  end
end

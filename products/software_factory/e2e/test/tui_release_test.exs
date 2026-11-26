defmodule AtlasE2E.TuiReleaseTest do
  # IS-Atlas-76, D-0105: a running TUI takes a release. Control (here a test Control on
  # loopback, whose contract is made newer than the client's) welcomes it with its newer
  # version; the TUI ends with the page it showed, `bin/atlas tui` takes the newest build
  # as at start (pull, clean-build, compile) and starts it again on that page. When the
  # update makes nothing current, the TUI starts anyway: bin/atlas says why, and the TUI's
  # status line says both versions and that it is not updated.
  #
  # Each test runs bin/atlas of a main clone of its own, on develop, made from this working
  # tree (its tracked and untracked files, as `git add -A` takes them, through an index of
  # its own: this checkout's index and branches are not touched) and pulling from a bare
  # repository of its own. The tests without a terminal run the update's failures (the
  # TUI then starts, and ends at once without a terminal); the last one runs the real TUI
  # in tmux, and is skipped without it.
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @moduletag timeout: 600_000
  @identity [
    {"GIT_AUTHOR_NAME", "atlas test"},
    {"GIT_AUTHOR_EMAIL", "test@atlas"},
    {"GIT_COMMITTER_NAME", "atlas test"},
    {"GIT_COMMITTER_EMAIL", "test@atlas"}
  ]

  defp git(dir, args, env \\ []) do
    {out, 0} = System.cmd("git", ["-C", dir | args], env: env, stderr_to_stdout: true)
    String.trim(out)
  end

  defp tmp! do
    dir = Path.join(System.tmp_dir!(), "atlas-release-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    # Resolved, as bin/atlas resolves its own checkout (/var → /private/var on macOS).
    {real, 0} = System.cmd("/bin/sh", ["-c", ~s(cd "$0" && pwd -P), dir])
    String.trim(real)
  end

  # `{dir, clone, upstream}`: a main clone on develop of this working tree.
  defp main_clone! do
    dir = tmp!()
    index = Path.join(dir, "index")
    File.cp!(git(@root, ["rev-parse", "--path-format=absolute", "--git-path", "index"]), index)
    git(@root, ["add", "-A"], [{"GIT_INDEX_FILE", index}])
    tree = git(@root, ["write-tree"], [{"GIT_INDEX_FILE", index}])
    commit = git(@root, ["commit-tree", tree, "-m", "the tree under test"], @identity)
    upstream = Path.join(dir, "up.git")
    git(dir, ["init", "-q", "--bare", upstream])

    git(@root, [
      "-c",
      "core.hooksPath=/dev/null",
      "push",
      "-q",
      upstream,
      "#{commit}:refs/heads/develop"
    ])

    clone = Path.join(dir, "atlas")
    git(dir, ["clone", "-q", "-b", "develop", upstream, clone])
    {dir, clone, upstream}
  end

  # The test Control: a loopback listener, and settings of an environment on this Mac
  # whose Control it is.
  defp control!(dir) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :line,
        active: false,
        ip: {127, 0, 0, 1},
        reuseaddr: true
      ])

    {:ok, {_, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    file = Path.join(dir, "test.json")

    settings = %{
      "env" => "test",
      "actors" => %{"decider" => "melle"},
      "control" => %{"host" => "127.0.0.1", "port" => port},
      "rela" => %{
        "url" => "http://127.0.0.1:2/api/v1",
        "port" => 2,
        "data" => Path.join(dir, "rela"),
        "bin" => Path.join(dir, "bin")
      },
      "facts" => %{"data" => Path.join(dir, "beam")},
      "reconcile_seconds" => 60
    }

    File.write!(file, JSON.encode!(settings))
    {listener, file}
  end

  # bin/atlas tui of `clone`, as its own run after a TUI of `clone` at its HEAD ended for a
  # Control on 0.99.0 (what bin/atlas hands itself, see its header).
  defp after_update(clone, file) do
    System.cmd(Path.join(clone, "bin/atlas"), ["tui", "--env", "test"],
      env: [
        {"ATLAS_ENV_FILE", file},
        {"ATLAS_NO_UPDATE", nil},
        {"ATLAS_TUI_TO", "/k/part"},
        {"ATLAS_TUI_TOO_OLD", git(clone, ["rev-parse", "HEAD"])},
        {"ATLAS_TUI_SPECS", "0.99.0 0.24.0"}
      ],
      cd: clone,
      stderr_to_stdout: true
    )
  end

  # It says why it is not updated, then starts the TUI anyway (here without a terminal, so
  # the TUI ends at once).
  defp started_anyway(out) do
    assert out =~ ". Starting it anyway; some parts may look plain.\n"
    assert out =~ "the TUI needs a terminal"
  end

  test "the pull fails: it says why, and starts the TUI anyway" do
    {dir, clone, upstream} = main_clone!()
    {_listener, file} = control!(dir)
    File.rename!(upstream, upstream <> ".gone")

    assert {out, 1} = after_update(clone, file)

    assert out =~
             "atlas: Control test speaks 0.99.0; this build is 0.24.0 and could not be updated: " <>
               "the pull of develop failed ("

    started_anyway(out)
  end

  test "develop has nothing newer: it says so, and starts the TUI anyway" do
    {dir, clone, _upstream} = main_clone!()
    {_listener, file} = control!(dir)
    short = git(clone, ["rev-parse", "--short", "HEAD"])

    assert {out, 1} = after_update(clone, file)

    assert out =~
             "atlas: Control test speaks 0.99.0; this build is 0.24.0 and could not be updated: " <>
               "develop has nothing newer than this build (#{short})."

    started_anyway(out)
  end

  test "the main clone is not on develop: it says so, and starts the TUI anyway" do
    {dir, clone, _upstream} = main_clone!()
    {_listener, file} = control!(dir)
    git(clone, ["switch", "-q", "-c", "elsewhere"])

    assert {out, 1} = after_update(clone, file)
    assert out =~ "could not be updated: the main clone #{clone} is on elsewhere, not develop."
    started_anyway(out)
  end

  describe "a real TUI under bin/atlas, in tmux" do
    @describetag skip: is_nil(System.find_executable("tmux"))

    test "welcomed by a newer Control it restarts on the newer build, on the page it showed; a failed update then stays, saying so" do
      {dir, clone, upstream} = main_clone!()
      {listener, file} = control!(dir)
      server = "atlas-release-#{System.unique_integer([:positive])}"
      on_exit(fn -> System.cmd("tmux", ["-L", server, "kill-server"], stderr_to_stdout: true) end)

      # The newer build, on develop: the same tree with a newer contract.
      ours = contract_version(clone)
      newer = bump(ours)
      work = Path.join(dir, "work")
      git(dir, ["clone", "-q", "-b", "develop", upstream, work])
      set_contract_version(work, newer)
      git(work, ["commit", "-q", "-am", "contract #{newer}"], @identity)

      log = Path.join(dir, "run.log")

      command =
        "cd #{clone} && env -u ATLAS_NO_UPDATE ATLAS_ENV_FILE=#{file} bin/atlas tui --env test " <>
          "2>>#{log}; echo \"[atlas exited $?]\"; sleep 600"

      tmux(server, ["new-session", "-d", "-s", "console", "-x", "120", "-y", "30", command])

      # The TUI on the build as it is: it opens the start page, then the person goes to Parts.
      {socket, hello} = hello(listener, 120_000)
      assert %{"op" => "hello", "spec" => ^ours} = hello
      handshake(socket, hello, "/k/widget")
      see(server, "▸ Widgets")
      tmux(server, ["send-keys", "-t", "console", "Tab"])
      assert %{"op" => "open", "to" => "/k/part"} = read(socket)
      send_message(socket, content("/k/part"))
      see(server, "▸ Parts")

      # Develop has the newer build; Control is deployed with its contract.
      git(work, ["push", "-q", "origin", "develop"])
      :gen_tcp.close(socket)
      {older, hello} = hello(listener, 10_000)
      assert %{"op" => "hello", "spec" => ^ours} = hello
      newer_control(older, newer)

      # Without anything typed: the newer build, back on Parts.
      {socket, hello} = hello(listener, 300_000)
      assert %{"op" => "hello", "spec" => ^newer} = hello
      welcome(socket, hello, "/k/widget")
      assert %{"op" => "open", "to" => "/k/part"} = read(socket)
      send_message(socket, content("/k/part"))
      see(server, "▸ Parts")
      assert git(clone, ["rev-parse", "HEAD"]) == git(work, ["rev-parse", "HEAD"])

      assert File.read!(log) =~
               "Control test speaks #{newer}; this build is #{ours}. Taking the newest build, then back to /k/part."

      # Another release, which this clone cannot pull: the TUI starts again on the same
      # build, stays with the newer Control, and its status line says so.
      newest = bump(newer)
      File.rename!(upstream, upstream <> ".gone")
      :gen_tcp.close(socket)
      {older, hello} = hello(listener, 10_000)
      assert %{"op" => "hello", "spec" => ^newer} = hello
      newer_control(older, newest)

      {socket, hello} = hello(listener, 300_000)
      assert %{"op" => "hello", "spec" => ^newer} = hello
      welcome(socket, hello, "/k/widget", newest)
      assert %{"op" => "open", "to" => "/k/part"} = read(socket)
      send_message(socket, content("/k/part"))
      see(server, "▸ Parts")
      see(server, "test speaks #{short(newest)}, this TUI #{short(newer)} · not updated")

      assert File.read!(log) =~
               "atlas: Control test speaks #{newest}; this build is #{newer} and could not be " <>
                 "updated: the pull of develop failed ("

      assert File.read!(log) =~ "Starting it anyway; some parts may look plain."
    end
  end

  # The test Control's side.

  # A client's hello, and its socket. bin/atlas first sees whether Control answers (a
  # connection that closes unsaid): that is no client.
  defp hello(listener, wait) do
    {:ok, socket} = :gen_tcp.accept(listener, wait)

    case :gen_tcp.recv(socket, 0, 10_000) do
      {:ok, line} -> {socket, JSON.decode!(line)}
      {:error, :closed} -> hello(listener, wait)
    end
  end

  defp send_message(socket, message), do: :gen_tcp.send(socket, [JSON.encode!(message), "\n"])

  defp read(socket) do
    {:ok, line} = :gen_tcp.recv(socket, 0, 10_000)
    JSON.decode!(line)
  end

  # A Control on a newer contract welcomes the client with it; a TUI started by bin/atlas
  # then ends to take the newest build.
  defp newer_control(socket, ours) do
    send_message(socket, %{
      "op" => "welcome",
      "surface" => "console",
      "env" => "test",
      "spec" => ours
    })

    {:error, :closed} = :gen_tcp.recv(socket, 0, 60_000)
  end

  defp short(version), do: String.replace_suffix(version, ".0", "")

  # After hello: welcome on the client's contract, the compatibility page, boot, and the
  # start page it opens.
  defp handshake(socket, hello, start) do
    welcome(socket, hello, start)
    assert %{"op" => "open", "to" => ^start} = read(socket)
    send_message(socket, content(start))
  end

  # Welcome (on `control`'s contract; the client's when not given), the compatibility page,
  # and boot with `start` as Control's start page.
  defp welcome(socket, %{"op" => "hello", "spec" => spec}, start, control \\ nil) do
    send_message(socket, %{
      "op" => "welcome",
      "surface" => "console",
      "env" => "test",
      "spec" => control || spec
    })

    send_message(socket, content("/"))
    assert %{"op" => "boot"} = read(socket)
    send_message(socket, shell(spec, start))
  end

  defp shell(spec, start) do
    %{
      "op" => "boot",
      "title" => "Atlas Console",
      "env" => "test",
      "spec" => spec,
      "revision" => "fixture",
      "initial_to" => start,
      "tabs" => [
        %{"id" => "widgets", "label" => "Widgets", "to" => "/k/widget", "section" => "work"},
        %{"id" => "parts", "label" => "Parts", "to" => "/k/part", "section" => "work"}
      ]
    }
  end

  defp content(path) do
    actions = [
      action("next", "Tab", "tab_next", path),
      action("previous", "Shift+Tab", "tab_previous", path)
    ]

    %{
      "op" => "page",
      "path" => path,
      "title" => "Widgets",
      "reason" => "open",
      "actions_revision" => "fixture",
      "blocks" => [
        %{
          "id" => "list",
          "type" => "list",
          "props" => %{
            "title" => "Widgets",
            "rows" => [%{"id" => "W1", "label" => "First widget", "to" => "/k/widget/W1"}]
          }
        }
        | actions
      ],
      "markup" => [
        %{
          "kind" => "legend",
          "start" => "next",
          "end" => "previous",
          "props" => %{"title" => "Navigation", "context" => "browse"}
        }
      ]
    }
  end

  defp action(id, key, name, path) do
    %{
      "id" => id,
      "type" => "console_action",
      "props" => %{
        "label" => id,
        "keys" => [key],
        "operation" => %{"name" => name},
        "available" => true,
        "scope" => %{"page" => path, "revision" => "fixture", "context" => "browse"}
      }
    }
  end

  # The contract version, as the build compiles it into the TUI's hello.

  defp contract_file(clone),
    do: Path.join(clone, "platform/atlas_control/backend/contract/lib/contract.ex")

  defp contract_version(clone) do
    [_, version] = Regex.run(~r/^  version "([0-9.]+)"$/m, File.read!(contract_file(clone)))
    version
  end

  defp set_contract_version(clone, version) do
    file = contract_file(clone)

    File.write!(
      file,
      Regex.replace(~r/^  version "[0-9.]+"$/m, File.read!(file), ~s(  version "#{version}"))
    )
  end

  defp bump(version),
    do: version |> Version.parse!() |> Map.update!(:minor, &(&1 + 1)) |> to_string()

  # The screen.

  defp tmux(server, args) do
    {output, 0} = System.cmd("tmux", ["-L", server | args], stderr_to_stdout: true)
    output
  end

  defp screen(server), do: tmux(server, ["capture-pane", "-p", "-t", "console"])

  # The screen once it shows `expected`, read again whenever tmux says the pane changed: a
  # control-mode client of the session (its `%output` lines) is the wake source.
  defp see(server, expected) do
    AtlasTestAwait.until(
      fn ->
        screen = screen(server)
        if String.contains?(screen, expected), do: screen
      end,
      wake:
        {:subscribe,
         fn ->
           Port.open({:spawn_executable, System.find_executable("tmux")}, [
             :binary,
             args: ["-L", server, "-C", "attach", "-t", "console"]
           ])
         end},
      cap: 300_000,
      label: "the screen to show #{inspect(expected)}",
      state: fn -> %{screen: screen(server)} end
    )
  end
end

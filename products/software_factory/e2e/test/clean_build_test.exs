defmodule AtlasE2E.CleanBuildTest do
  # IS-Atlas-67: after a Mix app is renamed and moved (as spec/ became bff/), what is left
  # of the old build must not stop the next start. A copy of that rename, small: two Mix
  # projects in a git repository of their own, built, then the dependency renamed.
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @clean Path.join(@root, "bin/clean-build")

  setup do
    dir = Path.join(System.tmp_dir!(), "atlas-clean-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    # The same Elixir as the repository, for a version manager that reads it.
    File.cp!(Path.join(@root, ".tool-versions"), Path.join(dir, ".tool-versions"))
    %{dir: dir}
  end

  defp write(dir, path, text) do
    file = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, text)
  end

  defp run!(dir, command, args) do
    {out, status} = System.cmd(command, args, cd: dir, stderr_to_stdout: true)
    if status != 0, do: flunk("#{command} #{Enum.join(args, " ")} failed:\n#{out}")
    out
  end

  defp git!(dir, args),
    do:
      run!(dir, "git", [
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@t",
        "-c",
        "core.hooksPath=/dev/null" | args
      ])

  defp dep(dir, folder, app) do
    module = app |> to_string() |> Macro.camelize()

    write(dir, "#{folder}/mix.exs", """
    defmodule #{module}.MixProject do
      use Mix.Project
      def project, do: [app: :#{app}, version: "0.1.0"]
      def application, do: []
    end
    """)

    write(dir, "#{folder}/lib/dep.ex", "defmodule Dep do\n  def hi, do: :hi\nend\n")
  end

  defp main(dir, app, folder) do
    write(dir, "main/mix.exs", """
    defmodule Main.MixProject do
      use Mix.Project
      def project, do: [app: :main, version: "0.1.0", deps: [{:#{app}, path: "../#{folder}"}]]
      def application, do: [mod: {Main, []}]
    end
    """)
  end

  defp start(dir),
    do:
      System.cmd("mix", ["run", "-e", "IO.puts(:started)"],
        cd: Path.join(dir, "main"),
        stderr_to_stdout: true
      )

  test "a renamed and moved app: its old build output goes, and the app starts", %{dir: dir} do
    write(dir, ".gitignore", "_build\ndeps\n")
    dep(dir, "spec", :dep_old)
    main(dir, :dep_old, "spec")

    write(
      dir,
      "main/lib/main.ex",
      "defmodule Main do\n  use Application\n  def start(_, _), do: (Dep.hi(); Supervisor.start_link([], strategy: :one_for_one))\nend\n"
    )

    git!(dir, ["init", "-q"])
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-qm", "one"])
    assert {out, 0} = start(dir)
    assert out =~ "started"

    # The rename, as on develop: the folder moves, the app gets a new name.
    git!(dir, ["mv", "spec", "bff"])
    dep(dir, "bff", :dep_new)
    main(dir, :dep_new, "bff")
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-qm", "two"])

    # What a pull leaves of the old folder: its build output, nothing tracked. And a file
    # nobody tracks elsewhere, beside build output of its own.
    File.mkdir_p!(Path.join(dir, "spec/_build/dev"))
    write(dir, "spec/.DS_Store", "")
    write(dir, "notes/mine.txt", "keep me")
    write(dir, "notes/_build/x", "")

    # Mix compares times to the second: a rename that lands in the second of the last build
    # (here made so) is not noticed, and main's .app still names the old app.
    built =
      File.stat!(Path.join(dir, "main/_build/dev/lib/main/ebin/main.app"), time: :posix).mtime

    File.touch!(Path.join(dir, "main/mix.exs"), built)

    # Without the clean, Mix tries to start the old app.
    assert {out, 1} = start(dir)
    assert out =~ "Could not start application dep_old"

    out = run!(dir, @clean, [dir, "--moved"])
    assert out =~ "atlas: removed spec/, which held only build output (its project moved)"

    assert out =~
             "atlas: removed the build output of dep_old in main/_build/dev/lib: no mix.exs " <>
               "declares it any more; main named it, and is built again"

    refute File.exists?(Path.join(dir, "spec"))
    assert {out, 0} = start(dir)
    assert out =~ "started"

    # Nothing tracked, and no other untracked file, is touched; a second run says nothing.
    assert File.read!(Path.join(dir, "notes/mine.txt")) == "keep me"
    assert git!(dir, ["status", "--porcelain"]) == "?? notes/\n"
    assert run!(dir, @clean, [dir, "--moved"]) == ""
  end

  test "without the moved folders, only stale _build entries go; a fresh build is left", %{
    dir: dir
  } do
    write(
      dir,
      "lone/mix.exs",
      "defmodule Lone.MixProject do\n  use Mix.Project\n  def project, do: [app: :lone, version: \"0.1.0\"]\nend\n"
    )

    write(dir, ".gitignore", "_build\n")
    git!(dir, ["init", "-q"])
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-qm", "one"])
    run!(Path.join(dir, "lone"), "mix", ["compile"])
    File.mkdir_p!(Path.join(dir, "lone/_build/dev/lib/gone/ebin"))

    out = run!(dir, @clean, [dir])
    assert out =~ "removed the build output of gone in lone/_build/dev/lib"
    assert File.dir?(Path.join(dir, "lone/_build/dev/lib/lone"))
    refute File.exists?(Path.join(dir, "lone/_build/dev/lib/gone"))
  end

  test "outside a git repository it changes nothing", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "p/_build/dev/lib/any"))
    assert run!(dir, @clean, [dir, "--moved"]) == ""
    assert File.dir?(Path.join(dir, "p/_build/dev/lib/any"))
  end
end

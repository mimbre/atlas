defmodule AtlasRuntime.Test.GitBaseTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "separate VMs serve fresh bases without disturbing earlier fixtures", %{tmp_dir: dir} do
    helper = Path.expand("../support/git_base.ex", __DIR__)

    script = ~S'''
    served = AtlasRuntime.Test.GitBase.serve("b-1", %{"README.md" => "base\n"})
    IO.puts(served.url)
    '''

    serve = fn ->
      {output, 0} =
        System.cmd("elixir", ["--erl", "+S 1", "-r", helper, "-e", script],
          env: [{"TMPDIR", dir}],
          stderr_to_stdout: true
        )

      String.trim(output)
    end

    first = serve.()
    sentinel = Path.join(first, "sentinel")
    File.write!(sentinel, "untouched")
    second = serve.()

    refute first == second
    assert File.read!(sentinel) == "untouched"

    for url <- [first, second] do
      repo = Path.join([url, "bases", "b-1"])
      {base, 0} = System.cmd("git", ~w(ls-tree -r --name-only refs/atlas/bases/b-1^), cd: repo)
      {prepared, 0} = System.cmd("git", ~w(ls-tree -r --name-only refs/atlas/bases/b-1), cd: repo)
      assert String.split(base) == ["README.md"]
      assert String.split(prepared) == ["README.md", "deps/dep/mix.exs"]
    end
  end
end

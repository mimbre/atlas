defmodule AtlasRuntime.Test.GitBase do
  @moduledoc """
  A base served over Git as Code's Git endpoint serves it to a Runtime: a repository at
  `<url>/bases/<base_id>` whose ref `refs/atlas/bases/<base_id>` holds the base's files.
  `serve/2` answers the `git` option of `AtlasRuntime.Sources.Import.base/5`.
  """

  @doc "A new, empty place to serve bases from: the `url` of `serve/3`."
  def url,
    do: Path.join(System.tmp_dir!(), "atlas-code-git-#{System.unique_integer([:positive])}")

  @doc "Serves `files` (`%{path => content}`, relative to the base's root) as base `base_id`."
  def serve(base_id, files), do: serve(url(), base_id, files)

  @doc "`serve/2` at `url`, next to the bases already served there."
  def serve(url, base_id, files) do
    repo = Path.join([url, "bases", base_id])
    File.mkdir_p!(repo)

    for {path, content} <- files do
      File.mkdir_p!(Path.dirname(Path.join(repo, path)))
      File.write!(Path.join(repo, path), content)
    end

    git(repo, ["init", "-q"])
    git(repo, ["add", "-A"])
    git(repo, ["commit", "-q", "--allow-empty", "-m", base_id])
    git(repo, ["update-ref", "refs/atlas/bases/" <> base_id, "HEAD"])
    %{url: url, env: fn -> [] end}
  end

  defp git(dir, args) do
    config =
      ~w(-c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null)

    {_, 0} = System.cmd("git", config ++ args, cd: dir, stderr_to_stdout: true)
  end
end

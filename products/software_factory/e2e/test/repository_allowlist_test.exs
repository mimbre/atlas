defmodule AtlasE2E.RepositoryAllowlistTest do
  @moduledoc """
  Every allow-list of Code's integrate receiver (`code.repositories`) holds the repository the
  model's work tasks build from (the package's `author` task, `input: [repository: …]` in
  `model/contract/software/package.ex`), read from the generated flows. Otherwise Atlas builds
  on one repository and its receiver refuses every pull request of it as
  `repository_not_allowed` (`AtlasCode.Effects`, an exact owner/repo match).

  An environment may instead allow no repository at all, on purpose: then its receiver refuses
  every request offline (test on Fly, `docs/guides/prod.md`). Only those named in
  `@allows_none` may.
  """
  use ExUnit.Case, async: true

  @factory Path.expand("../..", __DIR__)
  @allows_none ["test"]

  # {flows file, flow, owner/repo} of every task input that names a repository.
  defp built do
    for file <- Path.wildcard(Path.join(@factory, "model/targets/**/flows.json")),
        {flow, spec} <- JSON.decode!(File.read!(file))["flows"],
        {_state, state} <- spec["states"] || %{},
        url = get_in(state, ["spec", "input", "repository"]),
        is_binary(url),
        do: {Path.relative_to(file, @factory), flow, owner_repo(url)}
  end

  defp owner_repo(url) do
    case Regex.run(~r{\Ahttps://github\.com/([^/]+)/([^/]+?)(?:\.git)?/?\z}, url) do
      [_, owner, repo] -> owner <> "/" <> repo
      _ -> flunk("#{url} is no GitHub repository URL")
    end
  end

  defp repositories, do: built() |> Enum.map(&elem(&1, 2)) |> Enum.uniq()

  defp environments do
    for file <- Path.wildcard(Path.join(@factory, "environments/*/core.json")) do
      {file |> Path.dirname() |> Path.basename(), JSON.decode!(File.read!(file))}
    end
  end

  test "the package task names the repository it builds from, in every generated target" do
    built = built()
    targets = Path.wildcard(Path.join(@factory, "model/targets/**/flows.json"))

    assert targets != []

    for target <- targets do
      assert Enum.any?(built, fn {file, flow, _} ->
               file == Path.relative_to(target, @factory) and flow == "package"
             end),
             "#{target} has no package task with a repository input"
    end
  end

  test "every environment's allow-list holds the repository the work tasks build from" do
    repositories = repositories()
    assert repositories != []

    checked =
      for {env, settings} <- environments(), code = settings["code"], code != nil do
        allowed = code["repositories"]
        assert is_list(allowed), "environments/#{env}/core.json: code.repositories is no list"

        if env in @allows_none and allowed == [] do
          :ok
        else
          missing = repositories -- allowed

          assert missing == [],
                 "environments/#{env}/core.json: code.repositories #{inspect(allowed)} lacks " <>
                   "#{inspect(missing)}, which the model builds from"
        end

        env
      end

    # Prod integrates, so it must be among the checked environments, with a non-empty list.
    assert "prod" in checked
    assert "prod" not in @allows_none
  end

  test "the e2e instance allows the repository the work tasks build from" do
    allowed = AtlasE2E.Instance.code("unused")["repositories"]
    assert repositories() -- allowed == []
  end
end

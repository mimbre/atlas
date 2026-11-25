defmodule Model.RepositoryAllowlistTest do
  @moduledoc """
  Every allow-list of Code's integrate receiver (`code.repositories`) holds the repository the
  model's work tasks build from (the package's `author` task, `input: [repository: …]` in
  `model/contract/software/package.ex`), read from the compiled model's flows, per
  environment. Otherwise Atlas builds
  on one repository and its receiver refuses every pull request of it as
  `repository_not_allowed` (`AtlasCode.Effects`, an exact owner/repo match).

  A static check of the compiled model and the environments' files (no Atlas started), so it runs with the model's tests, in
  CI's `model-contract` job.

  An environment may instead allow no repository at all, on purpose: then its receiver refuses
  every request offline (test on Fly, `docs/guides/prod.md`). Only those named in
  `@allows_none` may.
  """
  use ExUnit.Case, async: true

  @factory Path.expand("../../..", __DIR__)
  @allows_none ["test"]

  @model Model.AtlasEyra

  # Each environment the model is compiled for.
  defp model_environments, do: @model.__rela__(:description).environments

  # {environment, flow, owner/repo} of every task input that names a repository.
  defp built do
    for env <- model_environments(),
        {flow, spec} <-
          RelaDSL.Flow.Subflow.definitions(@model.__flows__(), @model.__rela__(:gates), env),
        {_state, state} <- spec["states"] || %{},
        url = get_in(state, ["spec", "input", "repository"]),
        is_binary(url),
        do: {env, flow, owner_repo(url)}
  end

  defp owner_repo(input), do: github_repo(input) || flunk("#{input} names no GitHub repository")

  # The owner/repo of a repository input: Code's repository name, `github.com/<owner>/<repo>`
  # (the keys of Code's config.json, as the package task names it), or a GitHub HTTPS URL of it.
  # nil for anything else.
  defp github_repo(input) do
    case Regex.run(
           ~r{\A(?:https://)?github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?/?\z},
           input
         ) do
      [_, owner, repo] -> owner <> "/" <> repo
      _ -> nil
    end
  end

  defp repositories, do: built() |> Enum.map(&elem(&1, 2)) |> Enum.uniq()

  defp environments do
    for file <- Path.wildcard(Path.join(@factory, "environments/*/core.json")) do
      {file |> Path.dirname() |> Path.basename(), JSON.decode!(File.read!(file))}
    end
  end

  test "a repository input is Code's repository name or a GitHub HTTPS URL, nothing else" do
    for input <- [
          "github.com/mimbre/atlas",
          "https://github.com/mimbre/atlas",
          "https://github.com/mimbre/atlas.git"
        ] do
      assert github_repo(input) == "mimbre/atlas", input
    end

    for input <- [
          "gitlab.com/mimbre/atlas",
          "https://gitlab.com/mimbre/atlas",
          "github.com.evil/mimbre/atlas",
          "evilgithub.com/mimbre/atlas",
          "http://github.com/mimbre/atlas",
          "github.com/mimbre",
          "github.com/mimbre/atlas/extra",
          "mimbre/atlas",
          ""
        ] do
      assert github_repo(input) == nil, input
    end
  end

  test "the package task names the repository it builds from, in every environment" do
    built = built()

    for env <- model_environments() do
      assert Enum.any?(built, fn {e, flow, _} -> e == env and flow == "package" end),
             "#{env} has no package task with a repository input"
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
end

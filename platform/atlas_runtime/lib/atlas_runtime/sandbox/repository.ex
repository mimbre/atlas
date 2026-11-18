defmodule AtlasRuntime.Sandbox.Repository do
  @moduledoc """
  The managed-repository request and preparation plan (S6 A4, design §12 item 4). Shadow:
  nothing calls it in production yet (C4 switches `Service` and the helper over).

  The helper inspects and executes; this module decides. It does no filesystem I/O: the
  request's facts come from `atlas-runtime workspace facts repository HOME BRANCH` (see
  `facts_request/3`), and the plan it returns is run by the helper's `workspace.RunPlan`
  (`host/workspace/plan.go`). Every rule and refusal text is today's Go one, in Go's order:

    * `request/4` replaces `workspaceRequest` (`host/workspace/workspace.go:263-295`);
    * `plan/3` replaces the decisions in `workspace.Prepare` (`workspace.go:629-774`): the
      request re-check, continuation vs fresh, the git hardening options, the clone, the marker
      identity, the origin and branch checks, the fetch refspec and the base.
  """

  # workspace.go:264 (Go regexp: `$` is end of text, hence \z).
  @url ~r/\Ahttps:\/\/github\.com\/([A-Za-z0-9][A-Za-z0-9-]*)\/([A-Za-z0-9_.-]+)\z/
  # workspace.go:162-166, workspaceDedicatedScope.
  @network_hosts ["github.com", "api.github.com"]
  # workspace.go:666-670: no hooks, no fsmonitor, no background maintenance, only gh credentials.
  @git_config [
    "core.hooksPath=/dev/null",
    "core.fsmonitor=false",
    "maintenance.auto=false",
    "gc.auto=0",
    "credential.helper=",
    "credential.helper=!gh auth git-credential"
  ]
  # workspace.go:658-665: git never prompts.
  @git_env ["GIT_TERMINAL_PROMPT=0"]
  # workspace.go:656.
  @marker ".git/atlas-runtime-repository.json"
  # workspace.go:761-768.
  @base_pattern "^(?:[0-9a-f]{40}|[0-9a-f]{64})$"

  @url_refused "Repository must be an HTTPS github.com owner/repository URL"
  @name_refused "Invalid repository name"
  @branch_refused "Task branch must be a new explicit Git branch other than develop"
  @symlink_refused "Managed repository path must not contain symlinks"
  @changed "Managed repository request changed"
  @unmanaged "Refusing an unmanaged or mismatched repository"

  @doc """
  The arguments and stdin input for `Facts.fetch("repository", args, input)` that
  `request/4` (and `plan/3`, for the home `plan_home/2` derives) decides on. The managed path
  is asked for only when the URL names one.
  """
  def facts_request(home, url, branch) when is_binary(home) and is_binary(branch) do
    paths =
      case owner_and_name(url) do
        {:ok, owner, name} -> [managed_path(owner, name)]
        {:error, _} -> []
      end

    {[home, branch], %{"paths" => paths}}
  end

  @doc """
  The managed repository for `url` and `branch` under `home` (a work's `workers/<id>`):
  `{:ok, %{"permissions" => dedicated scope, "repository" => %{"url", "branch"}}}` or
  `{:error, text}`.
  """
  def request(_home, url, branch, facts) do
    with {:ok, owner, name} <- owner_and_name(url),
         :ok <- branch_ok(branch, facts["branch"]) do
      root = workspace_path(facts["home"] <> "/" <> managed_path(owner, name))

      case facts["resolved"][managed_path(owner, name)] do
        %{"resolved" => ^root} ->
          {:ok,
           %{
             "permissions" => dedicated_scope(root),
             "repository" => %{
               "url" => "https://github.com/#{owner}/#{name}.git",
               "branch" => branch
             }
           }}

        %{"resolved" => _other} ->
          {:error, @symlink_refused}

        %{"error" => text} ->
          {:error, text}
      end
    end
  end

  @doc """
  The Runtime home a prepared repository's request is re-checked under: three levels above the
  scope's root (`workspace.go:634-642`). `{:ok, home}` or `{:error, text}`.
  """
  def plan_home(scope, repository) do
    with {:ok, root, _url, _branch} <- plan_fields(scope, repository) do
      Enum.reduce_while(1..3, {:ok, root}, fn _, {:ok, path} ->
        case go_dir(path) do
          ^path -> {:halt, {:error, @changed}}
          parent -> {:cont, {:ok, parent}}
        end
      end)
    end
  end

  @doc """
  The preparation plan for a managed repository, or `{:error, text}`. `facts` are the
  repository facts for `plan_home/2`'s home and the repository's URL and branch.
  """
  def plan(scope, repository, facts) do
    with {:ok, _root, url, branch} <- plan_fields(scope, repository),
         {:ok, home} <- plan_home(scope, repository),
         {:ok, expected} <- request(home, url, branch, facts),
         :ok <- same_request(expected, scope, url, branch),
         continuation = Map.has_key?(repository, "base_sha"),
         :ok <- no_chosen_base(repository, continuation) do
      identity = %{"version" => 1, "url" => url}
      tail = if continuation, do: continued(branch), else: fresh(branch)

      {:ok,
       %{
         "version" => 1,
         "url" => url,
         "branch" => branch,
         "git_config" => @git_config,
         "git_env" => @git_env,
         "continuation" => continuation,
         "when_created" =>
           [
             %{
               "step" => "clone",
               "args" => ["clone", "--origin", "origin", "--branch", "develop", url, "."]
             },
             %{"step" => "expect_scope"},
             %{"step" => "write_marker", "path" => @marker, "identity" => identity}
           ] ++ tail,
         "when_existing" =>
           [
             %{
               "step" => "expect_marker",
               "path" => @marker,
               "identity" => identity,
               "error" => @unmanaged,
               "extra_error" => "Invalid repository marker JSON"
             },
             %{"step" => "expect_scope"},
             %{
               "step" => "expect_origin",
               "args" => ["remote", "get-url", "origin"],
               "url" => url,
               "error" => "Managed repository origin does not match the request"
             }
           ] ++ tail
       }}
    end
  end

  # A continuation keeps its saved branch and never fetches, resets or switches (workspace.go:727-736).
  defp continued(branch) do
    [
      %{
        "step" => "expect_current_branch",
        "args" => ["branch", "--show-current"],
        "branch" => branch,
        "error" => "Saved repository branch changed; continuation will not switch it"
      }
    ]
  end

  # A fresh task branches from develop as this preparation fetches it (workspace.go:737-772).
  defp fresh(branch) do
    [
      %{
        "step" => "expect_clean",
        "args" => ["status", "--porcelain", "--untracked-files=all"],
        "error" => "Managed repository has uncommitted work; nothing was reset or stashed"
      },
      %{
        "step" => "expect_no_ref",
        "args" => ["show-ref", "--verify", "--quiet", "refs/heads/" <> branch],
        "error" => "Task branch already exists or cannot be checked"
      },
      %{
        "step" => "fetch",
        "args" => ["fetch", "--no-tags", "origin", "+refs/heads/*:refs/remotes/origin/*"]
      },
      %{
        "step" => "expect_no_ref",
        "args" => ["show-ref", "--verify", "--quiet", "refs/remotes/origin/" <> branch],
        "error" => "Task branch already exists remotely or cannot be checked"
      },
      %{
        "step" => "resolve_base",
        "args" => ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/develop^{commit}"],
        "pattern" => @base_pattern,
        "error" => "Remote develop is not in the fetched repository"
      },
      %{
        "step" => "checkout_new",
        "args" => ["checkout", "--no-overwrite-ignore", "--no-track", "-b", branch]
      }
    ]
  end

  # workspace.go:630-635.
  defp plan_fields(%{"root" => root}, %{"url" => url, "branch" => branch})
       when is_binary(root) and is_binary(url) and is_binary(branch),
       do: {:ok, root, url, branch}

  defp plan_fields(_scope, _repository), do: {:error, @changed}

  # workspace.go:647-649: the scope and URL the request would give now, compared as Go's JSONEqual.
  defp same_request(expected, scope, url, branch) do
    actual = %{"permissions" => scope, "repository" => %{"url" => url, "branch" => branch}}
    if json_equal?(expected, actual), do: :ok, else: {:error, @changed}
  end

  # workspace.go:651-655: a base chosen elsewhere is refused; presence, not truthiness, counts.
  defp no_chosen_base(repository, continuation) do
    if Map.has_key?(repository, "resolved_commit") and not continuation,
      do: {:error, @changed},
      else: :ok
  end

  defp owner_and_name(url) when is_binary(url) do
    case Regex.run(@url, url) do
      [_, owner, name] ->
        owner = String.downcase(owner, :ascii)
        name = name |> String.downcase(:ascii) |> trim_suffix(".git")
        if name in ["", ".", ".."], do: {:error, @name_refused}, else: {:ok, owner, name}

      nil ->
        {:error, @url_refused}
    end
  end

  defp owner_and_name(_url), do: {:error, @url_refused}

  defp trim_suffix(string, suffix) do
    if String.ends_with?(string, suffix),
      do: binary_part(string, 0, byte_size(string) - byte_size(suffix)),
      else: string
  end

  defp managed_path(owner, name), do: "repositories/" <> owner <> "/" <> name

  # workspace.go:272-278: git must accept the name as a branch, unchanged, and it is not develop.
  defp branch_ok(branch, %{"stdout" => stdout, "code" => code}) do
    if code != 0 or go_trim_space(stdout) != branch or branch == "develop",
      do: {:error, @branch_refused},
      else: :ok
  end

  defp dedicated_scope(root) do
    %{
      "profile" => "dedicated-repository",
      "version" => 1,
      "root" => root,
      "git_dir" => workspace_path(root <> "/.git"),
      "network_hosts" => @network_hosts
    }
  end

  @doc false
  # workspacePath (workspace.go:66-86): pathlib collapses dots and separators, keeps '..', and
  # keeps a leading "//" (but not "///").
  def workspace_path(path) do
    prefix =
      cond do
        String.starts_with?(path, "//") and not String.starts_with?(path, "///") -> "//"
        String.starts_with?(path, "/") -> "/"
        true -> ""
      end

    case prefix <>
           (path |> String.split("/") |> Enum.reject(&(&1 in ["", "."])) |> Enum.join("/")) do
      "" -> "."
      result -> result
    end
  end

  @doc false
  # Go's filepath.Dir: everything up to the last separator, cleaned.
  def go_dir(path) do
    case :binary.matches(path, "/") do
      [] -> "."
      matches -> path |> binary_part(0, elem(List.last(matches), 0) + 1) |> go_clean()
    end
  end

  # Go's filepath.Clean (Unix).
  defp go_clean(""), do: "."

  defp go_clean(path) do
    rooted = String.starts_with?(path, "/")

    parts =
      path
      |> String.split("/")
      |> Enum.reduce([], fn
        part, acc when part in ["", "."] -> acc
        "..", [last | rest] when last != ".." -> rest
        "..", [] when rooted -> []
        part, acc -> [part | acc]
      end)
      |> Enum.reverse()
      |> Enum.join("/")

    case {rooted, parts} do
      {true, parts} -> "/" <> parts
      {false, ""} -> "."
      {false, parts} -> parts
    end
  end

  # Go's strings.TrimSpace: Unicode White_Space at both ends.
  @white_space [
                 0x09..0x0D,
                 0x20..0x20,
                 0x85..0x85,
                 0xA0..0xA0,
                 0x1680..0x1680,
                 0x2000..0x200A,
                 0x2028..0x2029,
                 0x202F..0x202F,
                 0x205F..0x205F,
                 0x3000..0x3000
               ]
               |> Enum.flat_map(&Enum.to_list/1)

  defp go_trim_space(string) when is_binary(string) do
    string
    |> String.to_charlist()
    |> Enum.drop_while(&(&1 in @white_space))
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 in @white_space))
    |> Enum.reverse()
    |> List.to_string()
  rescue
    # Not valid UTF-8: no git branch name matches it anyway.
    _ -> string
  end

  @doc false
  # workspace.JSONEqual (workspace.go:575-627), expected on the left: maps and lists compare
  # exactly; an expected integer equals the same integer, an equal float, or (as Python has it)
  # a boolean of value 0 or 1; anything else compares with ==.
  def json_equal?(left, right) when is_map(left) do
    is_map(right) and map_size(left) == map_size(right) and
      Enum.all?(left, fn {key, item} ->
        Map.has_key?(right, key) and json_equal?(item, right[key])
      end)
  end

  def json_equal?(left, right) when is_list(left) do
    is_list(right) and length(left) == length(right) and
      Enum.all?(Enum.zip(left, right), fn {item, other} -> json_equal?(item, other) end)
  end

  def json_equal?(left, right) when is_integer(left) do
    case right do
      true -> left == 1
      false -> left == 0
      right when is_integer(right) -> left == right
      right when is_float(right) -> right == left
      _ -> false
    end
  end

  def json_equal?(left, right), do: left === right
end

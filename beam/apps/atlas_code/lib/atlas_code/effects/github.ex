defmodule AtlasCode.Effects.GitHub do
  @moduledoc """
  What `AtlasCode.Effects` asks of GitHub, and GitHub's REST API answering it. `slug` is
  `owner/repo`; `number` a pull's number; commits are full SHAs.

  `config` is the GitHub connector's (`connectors.github` in the core's settings), so
  Code adds no secret of its own:

    * `api`: the API's base URL, `https://api.github.com`;
    * `token_env`: the environment variable that holds the token (on Fly a secret of the
      core's app), or `token_command`: the command that prints it (`["gh", "auth",
      "token"]`). Read once per call; the token stays in memory for that call only and is
      never written or logged. Without either, GitHub is called anonymously and refuses
      every write.

  Every callback may also answer `{:error, :unavailable}` (GitHub unreachable, a rate
  limit, a server error: nothing to conclude, ask again later) or `{:error, {:refused,
  reason}}` (`unauthorized`, `forbidden`, `not_found`, `no_token`: GitHub refused and
  did nothing).
  """

  @type config :: map()
  @type error :: {:error, :unavailable | {:refused, String.t()}}

  @doc "The pull: `state` (`open`, `closed`), `merged`, `head`, `base` (a branch), `mergeable` (nil while GitHub works it out) and `merge_commit`."
  @callback pull(config, slug :: String.t(), number :: pos_integer()) :: {:ok, map()} | error

  @doc "How `head` compares to `base` (a branch or commit): `ahead_by`, `behind_by`."
  @callback compare(config, String.t(), base :: String.t(), head :: String.t()) ::
              {:ok, %{String.t() => non_neg_integer()}} | error

  @doc "The parents of a commit, in order."
  @callback parents(config, String.t(), commit :: String.t()) :: {:ok, [String.t()]} | error

  @doc """
  CI on a commit: `:success` when there is at least one check or status and every one
  succeeded (or was neutral or skipped), `{:failure, names}` when one failed, otherwise
  `:pending`.
  """
  @callback checks(config, String.t(), commit :: String.t()) ::
              {:ok, :success | :pending | {:failure, [String.t()]}} | error

  @doc """
  Ask GitHub to merge the base into the pull's branch, only while its head is `head`.
  `{:unprocessable, message}`: GitHub would not, for another reason than a conflict
  (its expected head did not match, maintainers may not edit the branch, …).
  """
  @callback update_branch(config, String.t(), pos_integer(), head :: String.t()) ::
              :ok | {:error, :conflict | {:unprocessable, String.t()}} | error

  @doc "Merge the pull, only while its head is `head`; the merge commit."
  @callback merge(config, String.t(), pos_integer(), head :: String.t(), method :: String.t()) ::
              {:ok, String.t()} | {:error, :head_moved | {:not_mergeable, String.t()}} | error

  @behaviour __MODULE__

  @failed ~w(failure cancelled timed_out action_required stale startup_failure)
  @passed ~w(success neutral skipped)

  @impl true
  def pull(config, slug, number) do
    with {:ok, p} <- get(config, "/repos/#{slug}/pulls/#{number}") do
      {:ok,
       %{
         "state" => p["state"],
         "merged" => p["merged"] == true,
         "head" => get_in(p, ["head", "sha"]),
         "base" => get_in(p, ["base", "ref"]),
         "mergeable" => p["mergeable"],
         "merge_commit" => p["merge_commit_sha"]
       }}
    end
  end

  @impl true
  def compare(config, slug, base, head) do
    with {:ok, c} <- get(config, "/repos/#{slug}/compare/#{ref(base)}...#{head}") do
      {:ok, %{"ahead_by" => c["ahead_by"], "behind_by" => c["behind_by"]}}
    end
  end

  @impl true
  def parents(config, slug, commit) do
    with {:ok, c} <- get(config, "/repos/#{slug}/commits/#{commit}") do
      {:ok, Enum.map(c["parents"] || [], & &1["sha"])}
    end
  end

  @impl true
  def checks(config, slug, commit) do
    with {:ok, runs} <- get(config, "/repos/#{slug}/commits/#{commit}/check-runs?per_page=100"),
         {:ok, status} <- get(config, "/repos/#{slug}/commits/#{commit}/status?per_page=100") do
      {:ok, conclusion(runs, status)}
    end
  end

  @doc false
  # Pure, for tests: what the check runs and the combined status of one commit say.
  def conclusion(runs, status) do
    check_runs = runs["check_runs"] || []
    statuses = status["statuses"] || []

    failed =
      for(r <- check_runs, r["status"] == "completed", r["conclusion"] in @failed, do: r["name"]) ++
        for s <- statuses, s["state"] in ["failure", "error"], do: s["context"]

    cond do
      failed != [] ->
        {:failure, Enum.sort(failed)}

      status["state"] in ["failure", "error"] ->
        {:failure, ["combined_status"]}

      # Both APIs paginate. Missing counts and unseen contexts are not green evidence.
      not complete?(runs["total_count"], check_runs) or
          not complete?(status["total_count"], statuses) ->
        :pending

      statuses != [] and status["state"] != "success" ->
        :pending

      check_runs == [] and statuses == [] ->
        :pending

      Enum.all?(check_runs, &(&1["status"] == "completed" and &1["conclusion"] in @passed)) and
          Enum.all?(statuses, &(&1["state"] == "success")) ->
        :success

      true ->
        :pending
    end
  end

  defp complete?(count, entries),
    do: is_integer(count) and count >= 0 and count == length(entries)

  @impl true
  def update_branch(config, slug, number, head) do
    call(config, :put, "/repos/#{slug}/pulls/#{number}/update-branch", %{
      "expected_head_sha" => head
    })
    |> update_answer()
  end

  @doc false
  # Pure, for tests: what an update-branch call's classified response means.
  def update_answer(response) do
    case response do
      {:ok, _} ->
        :ok

      {:error, {:status, 422, body}} ->
        if body =~ ~r/conflict/i,
          do: {:error, :conflict},
          else: {:error, {:unprocessable, message(body)}}

      {:error, {:status, _, _}} ->
        {:error, :unavailable}

      other ->
        other
    end
  end

  @impl true
  def merge(config, slug, number, head, method) do
    call(config, :put, "/repos/#{slug}/pulls/#{number}/merge", %{
      "sha" => head,
      "merge_method" => method
    })
    |> merge_answer()
  end

  @doc false
  # Pure, for tests: what a merge call's classified response means.
  def merge_answer(response) do
    case response do
      {:ok, %{"merged" => true, "sha" => sha}} when is_binary(sha) ->
        {:ok, sha}

      {:ok, _} ->
        {:error, :unavailable}

      {:error, {:status, 409, _}} ->
        {:error, :head_moved}

      {:error, {:status, status, body}} when status in [405, 422] ->
        {:error, {:not_mergeable, message(body)}}

      other ->
        other
    end
  end

  # -- HTTP --

  # A read GitHub answers with another status than it documents tells nothing.
  defp get(config, path) do
    case call(config, :get, path) do
      {:error, {:status, _, _}} -> {:error, :unavailable}
      other -> other
    end
  end

  defp call(config, method, path, body \\ nil) do
    case token(config) do
      {:ok, token} -> request(config, token, method, path, body)
      {:error, _} = error -> error
    end
  rescue
    # A crash here would print its arguments, the token among them.
    _ -> {:error, :unavailable}
  end

  defp request(config, token, method, path, body) do
    url = String.trim_trailing(config["api"] || "https://api.github.com", "/") <> path

    headers =
      [
        {~c"accept", ~c"application/vnd.github+json"},
        {~c"x-github-api-version", ~c"2022-11-28"},
        {~c"user-agent", ~c"atlas-code"}
      ] ++ if(token, do: [{~c"authorization", String.to_charlist("Bearer " <> token)}], else: [])

    request =
      if body,
        do: {String.to_charlist(url), headers, ~c"application/json", JSON.encode!(body)},
        else: {String.to_charlist(url), headers}

    options = [timeout: 15_000, connect_timeout: 5_000] ++ ssl(url)

    case :httpc.request(method, request, options, body_format: :binary) do
      {:ok, {{_, status, _}, response_headers, raw}} -> classify(status, response_headers, raw)
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  @doc false
  # Pure, for tests: one HTTP response as the callbacks above read it.
  def classify(status, headers, raw) do
    cond do
      status in 200..299 ->
        case JSON.decode(raw) do
          {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
          _ when raw == "" -> {:ok, %{}}
          _ -> {:error, :unavailable}
        end

      status == 401 ->
        {:error, {:refused, "unauthorized"}}

      status == 403 ->
        if rate_limited?(headers, raw),
          do: {:error, :unavailable},
          else: {:error, {:refused, "forbidden"}}

      status == 404 ->
        {:error, {:refused, "not_found"}}

      status in [405, 409, 422] ->
        {:error, {:status, status, raw}}

      true ->
        {:error, :unavailable}
    end
  end

  defp rate_limited?(headers, raw),
    do:
      Enum.any?(headers, fn {k, v} -> k == ~c"x-ratelimit-remaining" and v == ~c"0" end) or
        raw =~ ~r/rate limit/i

  defp message(raw) do
    case JSON.decode(raw) do
      {:ok, %{"message" => m}} when is_binary(m) -> String.slice(m, 0, 200)
      _ -> ""
    end
  end

  defp ref(name), do: URI.encode(name, &(URI.char_unreserved?(&1) or &1 == ?/))

  defp ssl("https:" <> _) do
    [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 4,
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]
  end

  defp ssl(_url), do: []

  # The token for one call, as the GitHub connector reads it. What a command prints is
  # never logged.
  defp token(%{"token_env" => name}) when is_binary(name) do
    case System.get_env(name) do
      token when token in [nil, ""] -> {:error, {:refused, "no_token"}}
      token -> {:ok, String.trim(token)}
    end
  end

  defp token(%{"token_command" => [command | args]}) when is_binary(command) do
    with path when is_binary(path) <- System.find_executable(command),
         {out, 0} when out != "" <- System.cmd(path, args, stderr_to_stdout: false) do
      {:ok, String.trim(out)}
    else
      _ -> {:error, {:refused, "no_token"}}
    end
  end

  defp token(_config), do: {:ok, nil}
end

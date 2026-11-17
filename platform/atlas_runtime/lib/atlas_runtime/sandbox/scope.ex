defmodule AtlasRuntime.Sandbox.Scope do
  @moduledoc """
  The permission-scope decision (S6 A1, design §12 item 1), in shadow: not wired into the
  Service yet (C1 does that).

  It decides on the raw facts of `atlas-runtime workspace facts dedicated PATH` and
  `workspace facts folder DEST HOME` (`host/workspace/facts_scope.go`, fetched with
  `AtlasRuntime.Sandbox.Facts.fetch/3`) and does no filesystem I/O. It applies the rules of the
  legacy Go decisions in their order and with their texts (B3):

    * `dedicated/1`: `Scope` (`host/workspace/workspace.go`), the `dedicated-repository` scope;
    * `folder/2`: `FolderScope` and `FolderScopeBeforePreparation`, the `materialized-folder`
      scope of a `client_named` folder (`folder{path}`, D44, B13).

  Each returns the scope map or `{:error, text}`. The parity table is
  `test/fixtures/s6/scope/*.json`. The `review-packet` profile is not ported (B9), and the
  `runtime_chosen` folder rules (`base`, `from_work`) come with S6 C0d.
  """

  @network_hosts ["github.com", "api.github.com"]

  @doc """
  The `dedicated-repository` scope of a repository root from its `dedicated` facts.

  The managed repository's re-check uses it with a Runtime-chosen root; the rules do not
  depend on the origin.
  """
  def dedicated(facts) when is_map(facts) do
    with {:ok, root} <- path(facts["absolute"]),
         {:ok, resolved} <- path(facts["resolved"]),
         git_dir = facts["git_dir"]["path"],
         :ok <- own_git_dir(root, resolved, facts["git_dir"]),
         :ok <- rev_parse(facts["rev_parse"], [root, git_dir, git_dir]),
         :ok <- unshared(facts["shared"]),
         :ok <- unlinked(facts["metadata_link"]),
         :ok <- codex_config(facts["codex_config"], "Dedicated repository") do
      %{
        "profile" => "dedicated-repository",
        "version" => 1,
        "root" => root,
        "git_dir" => git_dir,
        "network_hosts" => @network_hosts
      }
    end
  end

  @doc """
  The `materialized-folder` scope of a folder from its `folder` facts, for `origin`.

  `:client_named` (a `folder{path}` start) keeps today's rules: a folder that overlaps the
  Runtime home either way is refused. A `{:runtime_chosen, work_id}` folder is decided from
  S6 C0d on and is not accepted here.
  """
  def folder(facts, :client_named) when is_map(facts) do
    with :ok <- absolute(facts),
         {:ok, home} <- path(facts["home_resolved"]),
         :ok <- outside_home(facts["dest"], facts["dest_canonical"], home),
         {:ok, verified} <- verified(facts["verified"]),
         root = verified["root"],
         :ok <- canonical(root, facts["dest_clean"]),
         :ok <- outside_git(facts["git"]),
         :ok <- codex_config(facts["codex_config"], "Materialized folder"),
         :ok <- not_packet(facts["packet"], root),
         :ok <- ready(facts["preparation"], home) do
      Map.merge(verified, %{"profile" => "materialized-folder", "version" => 1, "home" => home})
    end
  end

  def folder(_facts, {:runtime_chosen, _work}),
    do: raise(ArgumentError, "Runtime-chosen folder scopes are decided from S6 C0d on")

  # A fact that is a path, or the error its inspection returned (passed on as the refusal).
  defp path(%{"path" => path}), do: {:ok, path}
  defp path(%{"error" => error}), do: {:error, error}

  defp own_git_dir(root, root, %{"type" => "dir"}), do: :ok

  defp own_git_dir(_root, _resolved, _git_dir),
    do: {:error, "Dedicated repository requires a canonical root with its own .git directory"}

  defp rev_parse(%{"error" => error}, _expected), do: {:error, error}

  defp rev_parse(%{"exit" => 0, "stdout" => stdout}, expected) do
    if stdout |> String.replace_suffix("\n", "") |> String.split("\n") == expected,
      do: :ok,
      else: {:error, "Dedicated repository cannot use worktree or external Git metadata"}
  end

  defp rev_parse(%{"stderr" => stderr}, _expected),
    do: {:error, "Git repository inspection failed: " <> go_trim_space(stderr)}

  defp unshared(shared) do
    Enum.find_value(shared, :ok, fn
      %{"error" => error} ->
        {:error, error}

      %{"exists" => true} ->
        {:error, "Dedicated repository cannot share Git metadata or object stores"}

      %{"exists" => false} ->
        nil
    end)
  end

  defp unlinked(nil), do: :ok
  defp unlinked(%{"error" => error}), do: {:error, error}

  defp unlinked(%{"kind" => kind}) when kind in ["symlink", "hardlink"],
    do: {:error, "Dedicated Git metadata cannot contain symlinks or shared hardlinks"}

  # Project, ancestor or system Codex config the root would load is refused; the user's own
  # Codex home config is not a project config, and a config that cannot be checked counts as
  # present.
  defp codex_config(%{"ignored" => %{"error" => error}}, _subject), do: {:error, error}

  defp codex_config(%{"ignored" => %{"path" => ignored}, "candidates" => candidates}, subject) do
    refused = subject <> " cannot load project or system Codex config"

    Enum.find_value(candidates, :ok, fn
      %{"path" => ^ignored} -> nil
      %{"error" => error} -> {:error, refused <> ": " <> error}
      %{"exists" => true} -> {:error, refused}
      %{"exists" => false} -> nil
    end)
  end

  defp absolute(%{"dest_absolute" => true, "home_absolute" => true}), do: :ok

  defp absolute(_facts),
    do: {:error, "Materialized folder and Runtime home must be absolute paths"}

  # Workers cannot inspect a folder inside the home they are denied, nor write one containing it.
  defp outside_home(dest, canonical, home) do
    if within?(home, canonical) or within?(canonical, home),
      do:
        {:error,
         "Materialized folder #{dest} overlaps the Runtime home #{home}; materialize it outside the Runtime home"},
      else: :ok
  end

  defp within?(dir, path),
    do: path == dir or String.starts_with?(path, String.replace_suffix(dir, "/", "") <> "/")

  defp verified(%{"scope" => scope}), do: {:ok, scope}
  defp verified(%{"error" => error}), do: {:error, error}

  defp canonical(root, root), do: :ok
  defp canonical(_root, _clean), do: {:error, "Materialized folder requires its canonical path"}

  # The trusted native CLI runs Git when it finds metadata here or above.
  defp outside_git(nil), do: :ok
  defp outside_git(%{"error" => error}), do: {:error, error}

  defp outside_git(%{"path" => _}),
    do: {:error, "Materialized folder cannot be inside a Git work tree"}

  # A packet tree stays as frozen: only the review-packet profile runs in it.
  defp not_packet(%{"error" => error}, _root), do: {:error, error}
  defp not_packet(%{"id" => ""}, _root), do: :ok

  defp not_packet(%{"id" => id}, root),
    do:
      {:error,
       "Materialized folder #{root} is the tree of review packet #{id}; review it with --permissions review-packet"}

  # A folder that was never prepared keeps its scope; one whose explicit preparation has not
  # succeeded is refused (snapshot.Preparation Ready and NotReady).
  defp ready(nil, _home), do: :ok
  defp ready(%{"error" => error}, _home), do: {:error, error}
  defp ready(%{"record" => %{"state" => "succeeded"}}, _home), do: :ok
  defp ready(%{"record" => record}, home), do: {:error, not_ready(record, home)}

  defp not_ready(record, home) do
    outcome =
      if record["state"] == "running",
        do: "has no recorded outcome: it is still running or was interrupted",
        else: "failed (#{record["reason"]})"

    "Materialized folder #{record["destination"]} is not ready: its #{describe(record)} #{outcome}. " <>
      "The folder and the diagnostics in #{diagnostics(record, home)} are kept; " <>
      "materialize the snapshot into a fresh folder and prepare that one"
  end

  defp describe(%{"kind" => kind, "path" => path} = record) do
    case Map.get(record, "script", "") do
      "" -> "#{kind} preparation of #{path}"
      script -> "#{kind} preparation of #{path} (script #{script})"
    end
  end

  defp diagnostics(%{"destination" => destination} = record, home) do
    digest = :crypto.hash(:sha256, destination) |> Base.encode16(case: :lower)
    private = Path.join([home, "preparations", digest, "private"])
    if record["kind"] == "npm-run", do: Path.join(private, "npm-run"), else: private
  end

  # Go's strings.TrimSpace: unicode.IsSpace at both ends.
  @go_space ~c"\t\n\v\f\r \u0085                 　"

  defp go_trim_space(text) do
    text
    |> String.to_charlist()
    |> Enum.drop_while(&(&1 in @go_space))
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 in @go_space))
    |> Enum.reverse()
    |> List.to_string()
  end
end

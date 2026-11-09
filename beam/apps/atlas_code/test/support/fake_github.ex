defmodule AtlasCode.FakeGitHub do
  @moduledoc """
  GitHub as `AtlasCode.Effects` sees it (`AtlasCode.Effects.GitHub`), in memory: commits
  with their parents, branches, pulls, CI per commit, and every write asked of it.
  `config` is `%{"fake" => pid}`.

  As on GitHub, an update of a pull's branch is not applied when asked: `apply_updates/1`
  applies those asked for, and one asked at another head than the pull's is refused as
  unprocessable. Faults, each for the next call it names only:
  `fail(pid, call, :unavailable)` answers that call `{:error, :unavailable}`;
  `fail(pid, call, {:refused, reason})` answers it `{:error, {:refused, reason}}`, access
  refused, doing nothing; `fail(pid, :update_branch, {:unprocessable, why})` refuses the
  update for another reason; `fail(pid, :merge, :crash)` merges and then raises, as a
  receiver that stops between GitHub's merge and its own outcome; `fail(pid, :merge,
  :lost)` merges and answers `{:error, :unavailable}`, as a response lost on the way;
  `:delayed` holds the merge until `complete_merges/1`, returning unavailable meanwhile.
  """
  use Agent
  @behaviour AtlasCode.Effects.GitHub

  def start_link(_ \\ []),
    do:
      Agent.start_link(fn ->
        %{
          commits: %{},
          branches: %{},
          pulls: %{},
          checks: %{},
          writes: [],
          updates: [],
          pending_merges: [],
          merge_attempts: [],
          faults: %{}
        }
      end)

  def config(pid), do: %{"fake" => pid}

  @doc "A commit with its parents; its SHA."
  def commit(pid, name, parents \\ []) do
    sha = sha(name)
    Agent.update(pid, &put_in(&1, [:commits, sha], Enum.map(parents, fn p -> sha(p) end)))
    sha
  end

  def sha(name) when byte_size(name) == 40, do: name
  def sha(name), do: :crypto.hash(:sha, name) |> Base.encode16(case: :lower)

  def branch(pid, name, commit),
    do: Agent.update(pid, &put_in(&1, [:branches, name], sha(commit)))

  def put_pull(pid, number, values) do
    defaults = %{
      "state" => "open",
      "merged" => false,
      "base" => "main",
      "mergeable" => true,
      "merge_commit" => nil
    }

    Agent.update(pid, &put_in(&1, [:pulls, number], Map.merge(defaults, values)))
  end

  def get_pull(pid, number), do: Agent.get(pid, & &1.pulls[number])

  def set_pull(pid, number, values),
    do: Agent.update(pid, &update_in(&1, [:pulls, number], fn p -> Map.merge(p, values) end))

  def ci(pid, commit, result), do: Agent.update(pid, &put_in(&1, [:checks, sha(commit)], result))

  @doc "Every write asked of it, oldest first: `{:update_branch | :merge, number, head}`."
  def writes(pid), do: Agent.get(pid, &Enum.reverse(&1.writes))

  def merge_attempts(pid), do: Agent.get(pid, &Enum.reverse(&1.merge_attempts))

  def complete_merges(pid) do
    pending =
      Agent.get_and_update(pid, &{Enum.reverse(&1.pending_merges), %{&1 | pending_merges: []}})

    for {slug, number, head, method} <- pending,
        do: merge(config(pid), slug, number, head, method)
  end

  def fail(pid, call, fault), do: Agent.update(pid, &put_in(&1, [:faults, call], fault))

  @doc "Apply the asked-for updates: each pull still at the head asked about gets a merge of its base."
  def apply_updates(pid) do
    Agent.update(pid, fn s ->
      Enum.reduce(Enum.reverse(s.updates), %{s | updates: []}, fn {number, head}, s ->
        p = s.pulls[number]
        base = s.branches[p["base"]]

        if p["head"] == head do
          merge = sha("update #{head} #{base}")

          s
          |> put_in([:commits, merge], [head, base])
          |> put_in([:pulls, number, "head"], merge)
        else
          s
        end
      end)
    end)
  end

  # -- AtlasCode.Effects.GitHub --

  @impl true
  def pull(%{"fake" => pid}, _slug, number) do
    fault(pid, :pull) ||
      case Agent.get(pid, & &1.pulls[number]) do
        nil -> {:error, {:refused, "not_found"}}
        p -> {:ok, p}
      end
  end

  @impl true
  def compare(%{"fake" => pid}, _slug, base, head) do
    fault(pid, :compare) ||
      Agent.get(pid, fn s ->
        base = s.branches[base] || base
        a = ancestors(s.commits, head)
        b = ancestors(s.commits, base)

        {:ok,
         %{
           "ahead_by" => MapSet.size(MapSet.difference(a, b)),
           "behind_by" => MapSet.size(MapSet.difference(b, a))
         }}
      end)
  end

  @impl true
  def parents(%{"fake" => pid}, _slug, commit),
    do: fault(pid, :parents) || {:ok, Agent.get(pid, &Map.get(&1.commits, commit, []))}

  @impl true
  def checks(%{"fake" => pid}, _slug, commit) do
    fault(pid, :checks) ||
      case Agent.get(pid, &Map.get(&1.checks, commit, :pending)) do
        {:evidence, runs, status} -> {:ok, AtlasCode.Effects.GitHub.conclusion(runs, status)}
        result -> {:ok, result}
      end
  end

  @impl true
  def update_branch(%{"fake" => pid}, _slug, number, head) do
    fault(pid, :update_branch, [:unavailable, :unprocessable]) ||
      Agent.get_and_update(pid, fn s ->
        p = s.pulls[number]
        s = %{s | writes: [{:update_branch, number, head} | s.writes]}

        cond do
          p["head"] != head -> {{:error, {:unprocessable, "expected head sha didn't match"}}, s}
          p["mergeable"] == false -> {{:error, :conflict}, s}
          true -> {:ok, %{s | updates: [{number, head} | s.updates]}}
        end
      end)
  end

  @impl true
  def merge(%{"fake" => pid}, slug, number, head, method) do
    Agent.update(pid, &%{&1 | merge_attempts: [{number, head} | &1.merge_attempts]})
    fault = Agent.get(pid, & &1.faults[:merge])

    case fault(pid, :merge, [:unavailable, :delayed, :not_mergeable]) do
      {:error, :delayed} ->
        Agent.update(
          pid,
          &%{&1 | pending_merges: [{slug, number, head, method} | &1.pending_merges]}
        )

        {:error, :unavailable}

      nil ->
        result =
          Agent.get_and_update(pid, fn s ->
            p = s.pulls[number]
            s = %{s | writes: [{:merge, number, head} | s.writes]}

            cond do
              p["merged"] or p["state"] != "open" ->
                {{:error, {:not_mergeable, "not open"}}, s}

              p["head"] != head ->
                {{:error, :head_moved}, s}

              p["mergeable"] == false ->
                {{:error, {:not_mergeable, "conflict"}}, s}

              true ->
                sha = sha("#{method} #{head}")

                {{:ok, sha},
                 update_in(
                   s,
                   [:pulls, number],
                   &Map.merge(&1, %{"merged" => true, "state" => "closed", "merge_commit" => sha})
                 )}
            end
          end)

        if fault in [:crash, :lost],
          do: Agent.update(pid, &update_in(&1, [:faults], fn f -> Map.delete(f, :merge) end))

        case fault do
          :crash -> raise "stopped after the merge"
          :lost -> {:error, :unavailable}
          _ -> result
        end

      error ->
        error
    end
  end

  # The call's fault, taken once: `{:error, fault}` for one of `only` (by its tag, for a
  # tagged one) or an access refusal; nil for none, or one the caller handles itself.
  defp fault(pid, call, only \\ [:unavailable]) do
    Agent.get_and_update(pid, fn s ->
      fault = s.faults[call]
      tag = if is_tuple(fault), do: elem(fault, 0), else: fault

      if tag in only or tag == :refused,
        do: {{:error, fault}, %{s | faults: Map.delete(s.faults, call)}},
        else: {nil, s}
    end)
  end

  defp ancestors(commits, sha, seen \\ MapSet.new()) do
    if MapSet.member?(seen, sha),
      do: seen,
      else:
        Enum.reduce(Map.get(commits, sha, []), MapSet.put(seen, sha), &ancestors(commits, &1, &2))
  end
end

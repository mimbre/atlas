defmodule AtlasLearn.Patterns do
  @moduledoc """
  Deterministic patterns over one window's observations: the same records always give the
  same patterns, in the same order. Every finding cites the records it rests on (`evidence`:
  record ids as the observation gives them). A pattern whose observation was not read has
  `status` other than `:read` and no findings.

  v1 knows four:

    * passes that needed follow-up turns: chains of turns linked by the turn each continued,
      with their depth and worker;
    * failed turns, grouped by their reason;
    * changes that needed more than one review, or that Code refused or could not land;
    * decisions decided in the window, what they replaced, and what is still open.
  """
  @failed_states ~w(failed killed stopped unknown)
  @landing_refusals %{
    "target_moved" => "integration refused: the target moved",
    "conflicted" => "integration refused: the change conflicts with the target",
    "refused" => "integration refused by the remote",
    "failed" => "review refused: its location was already taken"
  }

  def find(observations, _window) do
    by_name = Map.new(observations, &{&1.name, &1})

    [
      pattern("Passes that needed follow-up turns", by_name["Worker passes"], &follow_ups/1),
      pattern("Failed turns and their reasons", by_name["Worker passes"], &failed_turns/1),
      pattern(
        "Changes that needed more than one review, or were refused",
        by_name["Changes through Code"],
        &repeated_changes/1
      ),
      pattern("Decisions in the window", by_name["Decisions"], &decisions/1)
    ]
  end

  defp pattern(title, nil, _find), do: %{title: title, status: :not_asked, findings: []}

  defp pattern(title, %{status: :read} = observation, find),
    do: %{title: title, status: :read, findings: find.(observation)}

  defp pattern(title, observation, _find),
    do: %{title: title, status: observation.status, findings: []}

  defp finding(text, evidence), do: %{text: text, evidence: evidence}

  # Follow-ups: a turn that continued another is one step deeper than it. Chains are grouped
  # by the earliest turn reachable through `source`; a source Runtime no longer lists ends
  # the walk and is cited as the chain's start.
  defp follow_ups(%{records: inside, context: outside}) do
    turns = Map.new(inside ++ outside, &{&1.id, &1})
    in_window = MapSet.new(inside, & &1.id)

    (inside ++ outside)
    |> Enum.group_by(&root(&1, turns, MapSet.new()))
    |> Enum.map(fn {start, members} -> {start, sort_turns(members)} end)
    |> Enum.filter(fn {start, members} ->
      (length(members) > 1 or not Map.has_key?(turns, start)) and
        Enum.any?(members, &MapSet.member?(in_window, &1.id))
    end)
    |> Enum.sort_by(fn {start, members} -> {-depth(List.last(members), turns), start} end)
    |> Enum.map(fn {start, members} ->
      deepest = Enum.max_by(members, &depth(&1, turns))
      workers = members |> Enum.map(& &1.worker) |> Enum.uniq() |> Enum.join(", ")
      last = List.last(members)
      missing = if Map.has_key?(turns, start), do: [], else: [start]

      finding(
        "depth #{depth(deepest, turns)} (#{turns_text(length(members))}) on worker #{workers}, " <>
          "#{backends(members)}; last turn #{last.state}" <>
          if(missing == [],
            do: "",
            else: "; started from #{start}, which Runtime no longer lists"
          ),
        missing ++ Enum.map(members, & &1.id)
      )
    end)
  end

  defp turns_text(1), do: "1 turn"
  defp turns_text(n), do: "#{n} turns"

  defp root(turn, turns, seen) do
    cond do
      is_nil(turn.source) or MapSet.member?(seen, turn.id) -> turn.id
      source = turns[turn.source] -> root(source, turns, MapSet.put(seen, turn.id))
      true -> turn.source
    end
  end

  defp depth(turn, turns, seen \\ MapSet.new()) do
    cond do
      is_nil(turn.source) or MapSet.member?(seen, turn.id) -> 0
      source = turns[turn.source] -> 1 + depth(source, turns, MapSet.put(seen, turn.id))
      true -> 1
    end
  end

  defp sort_turns(turns), do: Enum.sort_by(turns, &{&1.started_at || "", &1.id})

  defp backends(turns) do
    turns
    |> Enum.map(fn turn ->
      [turn.backend, turn.model] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
    end)
    |> Enum.uniq()
    |> Enum.join(", ")
  end

  defp failed_turns(%{records: turns}) do
    turns
    |> Enum.filter(&(&1.state in @failed_states or &1.error != nil))
    |> Enum.group_by(&reason/1)
    |> Enum.sort_by(fn {reason, members} -> {-length(members), reason} end)
    |> Enum.map(fn {reason, members} ->
      members = sort_turns(members)
      workers = members |> Enum.map(& &1.worker) |> Enum.uniq() |> Enum.join(", ")
      finding("#{length(members)} × #{reason} (worker #{workers})", Enum.map(members, & &1.id))
    end)
  end

  defp reason(%{error: error, state: state}) when is_binary(error), do: "#{state}: #{error}"

  defp reason(%{state: "unknown", recorded_state: recorded}) when is_binary(recorded),
    do: "unknown: the service ended while the turn was #{recorded}"

  defp reason(%{state: state}), do: state

  defp repeated_changes(%{records: inside, context: outside}) do
    all = inside ++ outside
    in_window = MapSet.new(inside, & &1.id)
    touched? = fn members -> Enum.any?(members, &MapSet.member?(in_window, &1.id)) end

    reviews = Enum.filter(all, &(&1.type == :review))
    integrations = Enum.filter(all, &(&1.type == :integration))

    repeated_reviews =
      reviews
      |> Enum.group_by(&{&1.repository, &1.target, &1.title})
      |> Enum.filter(fn {_work, members} -> length(members) > 1 and touched?.(members) end)
      |> Enum.sort()
      |> Enum.map(fn {{repository, target, title}, members} ->
        members = Enum.sort_by(members, &{DateTime.to_unix(&1.at), &1.id})
        changes = members |> Enum.map(&("change " <> to_string(&1.change_id))) |> Enum.uniq()

        finding(
          "reviewed #{length(members)} times (#{length(changes)} changes): \"#{title}\" " <>
            "in #{repository} towards #{target}",
          Enum.map(members, & &1.id) ++ changes
        )
      end)

    retried_integrations =
      integrations
      |> Enum.group_by(& &1.review_id)
      |> Enum.filter(fn {_review, members} -> length(members) > 1 and touched?.(members) end)
      |> Enum.sort()
      |> Enum.map(fn {review, members} ->
        phases = members |> Enum.map(& &1.phase) |> Enum.join(", ")

        finding(
          "integrated #{length(members)} times (#{phases})",
          ["review #{review}" | Enum.map(members, & &1.id)]
        )
      end)

    refusals =
      inside
      |> Enum.filter(
        &(&1.type in [:review, :integration] and is_map_key(@landing_refusals, &1.phase))
      )
      |> Enum.group_by(&@landing_refusals[&1.phase])
      |> Enum.sort()
      |> Enum.map(fn {text, members} ->
        finding("#{length(members)} × #{text}", members |> Enum.map(& &1.id) |> Enum.sort())
      end)

    repeated_reviews ++ retried_integrations ++ refusals
  end

  defp decisions(%{records: inside, context: outside}) do
    decided =
      inside
      |> Enum.group_by(&(&1.status || "no status"))
      |> Enum.sort()
      |> Enum.map(fn {status, members} ->
        finding("#{status}: #{length(members)}", members |> Enum.map(& &1.id) |> Enum.sort())
      end)

    replaced =
      for fact <- Enum.sort_by(inside, & &1.id), fact.links != [] do
        links = Enum.map_join(fact.links, ", ", &"#{&1.list || "linked"} #{&1.key}")

        finding("#{fact.id} (#{fact.status || "no status"}): #{links}", [
          fact.id | Enum.map(fact.links, & &1.key)
        ])
      end

    open =
      outside
      |> Enum.filter(&is_nil(&1.at))
      |> Enum.group_by(&(&1.status || "no status"))
      |> Enum.sort()
      |> Enum.map(fn {status, members} ->
        finding(
          "not decided yet, #{status}: #{length(members)} (date unknown)",
          members |> Enum.map(& &1.id) |> Enum.sort()
        )
      end)

    decided ++ replaced ++ open
  end
end

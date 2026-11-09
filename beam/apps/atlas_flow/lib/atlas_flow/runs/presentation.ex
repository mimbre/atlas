defmodule AtlasFlow.Runs.Presentation do
  @moduledoc """
  What a run presents, derived from the run alone: the state its owner is in, what is
  expected of them, why, the todo, the owner the state names and the deadline it shows;
  and how what Flow wrote on the fact reads back: the owner set by hand, the deferred
  handover. Pure: `AtlasFlow.Item` writes what it derives on the fact (or on the fact its
  projection is `on`), and Facts serves it back to every reader as the fact's
  presentation. No IO.
  """

  alias AtlasFlow.Runs.Run

  @doc """
  What `run` of `subflow` presents on `fact` (its subject) under `selection`:

    * `:follow_through`: completed in its selection's `follow_through` state while the
      subject still holds its `when`: what the legacy flow presents goes on (temporary,
      until the old flows go);
    * `%{"name", "done" => true}`: completed; nothing is expected and nobody owns it;
    * for an active run, `%{"name", "expected", "why", "todo", "owner", "preserve_kind",
      "deadline", …}`: what the state presents (`subflow.present/2`), its owner as
      `owner` resolves the state's default (`AtlasFlow.Model.owner/2`) and the due time
      of the timer it presents;
    * nil: nothing (blocked, or idle).
  """
  def of_run(run, subflow, selection, fact, owner) do
    values = fact["values"] || %{}
    follow = selection["follow_through"]

    cond do
      run["status"] == "completed" and follow != nil and run["state"] == follow["state"] and
          Run.holds?(follow["when"], values) ->
        :follow_through

      run["status"] == "completed" ->
        %{"name" => run["state"], "done" => true}

      run["status"] == "active" ->
        present = subflow.present(run["state"], values) || %{}
        binding = subflow.owner(run["state"])

        deadline =
          Enum.find_value(run["deadlines"]["timers"] || [], fn timer ->
            if timer["name"] == present["deadline"], do: timer["due"]
          end)

        Map.merge(present, %{
          "name" => run["state"],
          "expected" => present["expected"] || "",
          "owner" => owner.(binding["default"]),
          "preserve_kind" => binding["preserve_kind"],
          "deadline" => deadline
        })

      true ->
        nil
    end
  end

  @doc """
  Whether a user or an agent set the owner of `fact` through `relation` by hand: the
  origin of its link is by someone other than Flow, a migration or nobody. Such an owner
  stays while the state does not change.
  """
  def manual?(_fact, nil), do: false

  def manual?(fact, relation) do
    case get_in(fact, ["origins", relation]) do
      %{"by" => by} when by not in [nil, "flow", "migration"] -> true
      _ -> false
    end
  end

  @doc """
  The handover Flow deferred on `fact` in `field`: `%{"from", "position"}`, the owners it
  is to move from and the position of their link; `%{}` when none waits.
  """
  def handover(_fact, nil), do: %{}

  def handover(fact, field) do
    case JSON.decode(fact["values"][field] || "") do
      {:ok, %{} = value} -> value
      _ -> %{}
    end
  end

  @doc """
  Whether the deferred `handover` is still the one Flow held: the owners and their link
  are those it was deferred from. A later manual assignment cancels it.
  """
  def deferred?(handover, owners, origin),
    do: handover != %{} and handover["from"] == owners and handover["position"] == origin
end

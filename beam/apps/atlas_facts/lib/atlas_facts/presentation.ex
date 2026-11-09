defmodule AtlasFacts.Presentation do
  @moduledoc """
  The presentation of the work on a fact, derived from its runs: what Facts answers as a
  fact's `"presentation"` when a read asks for it (`"presentation" => true`), so that no
  reader works out from a fact's fields whether work on it is open, whose it is and
  whether a handover waits. Pure: the server reads the facts it needs.

  A presenter (the model's `presentation/0`) says where one subject kind's work is
  written (`kind`, through `on`, in `field`, `state_field`, `handover_field`,
  `deadline_field` and `owner_relation`) and by which selected subflows' runs (`flows`),
  or by a legacy flow (`legacy`) while no selected subflow presents it.

  The presentation, for a fact `target` the work is written on:

    * `subject` (`%{"kind", "key"}`), `flow` and `legacy` (who presents it), and the run
      that does: `run`, `generation`, `status`;
    * `state`: the state presented: the active (or blocked) run's own, or, for a
      completed run that still follows through (its selection's `follow_through`), the
      state Flow wrote; nil when no run presents anything;
    * `expected`, `why`, `todo` (the state's `instructions`, `section`, `answers`) and
      `deadline`;
    * `owner` (the keys the owner relation links), `manual` (a user or an agent set it,
      not Flow, a migration or nobody), `handover` (the deferred handover Flow holds,
      `%{"from", "position"}`, or nil);
    * `follow_through`, and `reopened`: its runs ended, a selection that declares reopened
      work runs again only on an explicit restart (`reopen: "explicit"`) still admits the
      subject, and the subject is not completed: reopened work, nobody's until then;
    * `actionable`: there is something to do: a state is presented and what Flow wrote
      agrees with it. A completed run is never actionable, whatever is still written.
  """

  @doc "The presenters whose work is written on facts of `kind`."
  def of_kind(presenters, kind), do: for(p <- presenters || [], p["kind"] == kind, do: p)

  @doc """
  The presentation of `target` by `presenter`, for `subject` (`%{"key", "values"}`, the
  fact the work is on; `target` itself when the presenter writes on the subject) with
  `runs` (decoded, of its subject: `flow`, `generation`, `status`, `state`, `key`).
  `completed?` says whether the subject is completed (asked only for reopened work).
  """
  def view(presenter, target, subject, runs, completed?) do
    values = target["values"] || %{}
    subject_values = subject["values"] || %{}
    stored = blank(field(values, presenter["state_field"]))

    base = %{
      "subject" => %{"kind" => presenter["subject"], "key" => subject["key"]},
      "flow" => nil,
      "legacy" => presenter["legacy"],
      "run" => nil,
      "generation" => nil,
      "status" => nil,
      "state" => nil,
      "follow_through" => false,
      "reopened" => false,
      "owner" => owners(target, presenter),
      "manual" => manual?(target, presenter["owner_relation"]),
      "handover" => handover(values, presenter["handover_field"]),
      "deadline" => blank(field(values, presenter["deadline_field"]))
    }

    presented =
      if presenter["legacy"] do
        legacy(presenter, stored)
      else
        by_run(presenter, latest(presenter, runs), subject_values, stored, completed?)
      end

    view = Map.merge(base, presented)
    state = view["state"]
    shown = (state && presenter["states"][state]) || %{}

    Map.merge(view, %{
      "expected" => if(view["actionable"], do: blank(field(values, presenter["field"]))),
      "why" => shown["why"],
      "todo" => if(view["actionable"], do: shown["todo"])
    })
  end

  # A legacy flow writes the state it finds on the fact; without a state field the work is
  # open while it is written.
  defp legacy(presenter, stored) do
    %{
      "state" => stored,
      "actionable" => presenter["state_field"] == nil or stored != nil
    }
  end

  defp by_run(presenter, latest, values, stored, completed?) do
    follow =
      Enum.find(latest, fn {cfg, run} ->
        ft = cfg["follow_through"]

        run["status"] == "completed" and is_map(ft) and run["state"] == ft["state"] and
          holds?(ft["when"] || %{}, values) and stored != nil
      end)

    case {Enum.find(latest, fn {_, run} -> run["status"] in ["active", "blocked"] end), follow} do
      {{cfg, run}, _} ->
        Map.merge(of_run(cfg, run), %{
          "state" => run["state"],
          "actionable" => presenter["state_field"] == nil or stored == run["state"]
        })

      {nil, {cfg, run}} ->
        Map.merge(of_run(cfg, run), %{
          "state" => stored,
          "follow_through" => true,
          "actionable" => true
        })

      {nil, nil} ->
        ended =
          Enum.find(latest, fn {cfg, run} ->
            run["status"] == "completed" and holds?(cfg["admission"] || %{}, values)
          end)

        case ended do
          {cfg, run} ->
            Map.merge(of_run(cfg, run), %{
              "actionable" => false,
              "reopened" => cfg["reopen"] == "explicit" and not completed?.()
            })

          nil ->
            %{"actionable" => false}
        end
    end
  end

  defp of_run(cfg, run),
    do: %{
      "flow" => cfg["name"],
      "run" => run["key"],
      "generation" => run["generation"],
      "status" => run["status"]
    }

  # The latest generation of each of its subflows' runs, in the presenter's order.
  defp latest(presenter, runs) do
    for cfg <- presenter["flows"] || [],
        mine = Enum.filter(runs, &(&1["flow"] == cfg["name"])),
        mine != [],
        do: {cfg, Enum.max_by(mine, &(&1["generation"] || 0))}
  end

  @doc "The keys the presenter's owner relation links on `target`."
  def owners(target, presenter) do
    case presenter["owner_relation"] do
      nil -> []
      relation -> get_in(target, ["links", relation]) || []
    end
  end

  @doc """
  Whether a user or an agent set the owner by hand: its link's origin is by someone
  other than Flow, a migration or nobody. Flow leaves such an owner within a state.
  """
  def manual?(_target, nil), do: false

  def manual?(target, relation) do
    case get_in(target, ["origins", relation]) do
      %{"by" => by} when by not in [nil, "flow", "migration"] -> true
      _ -> false
    end
  end

  @doc "The deferred handover Flow holds in `field`: `%{\"from\", \"position\"}`, or nil."
  def handover(_values, nil), do: nil

  def handover(values, field) do
    case blank(values[field]) do
      nil ->
        nil

      text when is_binary(text) ->
        case JSON.decode(text) do
          {:ok, %{} = held} -> Map.take(held, ["from", "position"])
          # Held, in a form Facts does not read: still a barrier.
          _ -> %{"from" => nil, "position" => nil}
        end

      _ ->
        %{"from" => nil, "position" => nil}
    end
  end

  @doc "Whether `values` hold `condition` (`%{field => allowed}`; nil allows no value)."
  def holds?(condition, values),
    do:
      Enum.all?(condition, fn {field, allowed} ->
        case values[field] do
          blank when blank in [nil, ""] -> nil in List.wrap(allowed)
          value -> value in List.wrap(allowed)
        end
      end)

  defp field(_values, nil), do: nil
  defp field(values, name), do: values[name]

  defp blank(value) when value in [nil, ""], do: nil
  defp blank(value), do: value
end

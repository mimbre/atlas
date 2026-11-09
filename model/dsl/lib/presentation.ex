defmodule RelaDSL.Presentation do
  @moduledoc """
  Who presents the work on a fact, as the model compiles it for every layer that reads
  it: the presenters. A presenter is where one subject kind's work is projected, and by
  which runs:

    * `subject`: the kind of fact the work is on; `kind`: the kind it is written on (the
      one `on`, a component relation of the subject, points at; else the subject's own);
    * the fields it is written in: `field` (what is expected), `state_field`,
      `handover_field` (a deferred handover), `deadline_field`, and `owner_relation`;
    * `flows`: the selected subflows whose runs present it, in name order, each with its
      `reopen` and `admission`;
    * `states`: what each state of those subflows shows its owner (`expected`, `why`,
      `todo`).

  Only selected subflows present work: a subject kind no selected subflow projects has
  no presenter.
  """

  @doc """
  The presenters of `d` (the description, Atlas's additions merged in), `flow_runtime`
  (the run mapping, plain, or nil) and `presentations` (by subflow: `%{"states" => %{state
  => %{"present" => …}}}`), in a stable order.
  """
  def presenters(d, flow_runtime, presentations \\ %{}) do
    relations = d["relations"] || %{}
    selection = (flow_runtime && get_in(flow_runtime, ["flow_runtime", "selection"])) || %{}

    for({name, s} <- Enum.sort(selection), is_map(s["projection"]), do: {name, s})
    |> Enum.group_by(fn {_, s} -> {s["subject"], s["projection"]} end)
    |> Enum.sort()
    |> Enum.map(fn {{subject, projection}, group} ->
      states =
        Map.new(
          for {name, _} <- group,
              {state, %{"present" => %{} = present}} <-
                get_in(presentations, [name, "states"]) || %{},
              do: {state, shown(present)}
        )

      presenter(relations, subject, projection, states)
      |> Map.put(
        "flows",
        for(
          {name, s} <- group,
          do: %{"name" => name, "reopen" => s["reopen"], "admission" => s["admission"] || %{}}
        )
      )
    end)
  end

  @doc "The kinds work is owned on, each with its owner relation, once each: `[%{kind, owner_relation}]`."
  def owned(presenters) do
    for p <- presenters,
        is_binary(p["owner_relation"]),
        uniq: true,
        do: %{"kind" => p["kind"], "owner_relation" => p["owner_relation"]}
  end

  defp presenter(relations, subject, projection, states) do
    on = projection["on"]

    kind =
      case is_binary(on) && get_in(relations, [on, "to"]) do
        [to] -> to
        _ -> subject
      end

    %{
      "subject" => subject,
      "kind" => kind,
      "on" => if(kind == subject and not is_binary(on), do: nil, else: on),
      "field" => projection["field"],
      "state_field" => projection["state_field"],
      "handover_field" => projection["handover_field"],
      "deadline_field" => projection["deadline_field"],
      "owner_relation" => projection["owner_relation"],
      "states" => states
    }
  end

  defp shown(s) do
    %{"expected" => s["expected"], "why" => s["why"], "todo" => s["todo"]}
  end
end

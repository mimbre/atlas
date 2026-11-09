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
      `follow_through` (`%{"state", "when"}` or nil), `reopen` and `admission`;
    * `legacy`: the legacy flow that presents it when no selected subflow does (nil
      otherwise; it goes with the legacy flows);
    * `states`: what each state shows its owner (`expected`, `why`, `todo`): the
      subflows' presentations, over the legacy flow's open states, which a completed
      run's follow-through still presents.

  A selected subflow presents a subject kind instead of the legacy flow it takes over
  (`legacy` of its selection): never both.
  """

  @doc """
  The presenters of `d` (the description, Atlas's additions merged in), `flow_runtime`
  (the run mapping, plain, or nil) and `presentations` (by subflow: `%{"states" => %{state
  => %{"present" => …}}}`), in a stable order.
  """
  def presenters(d, flow_runtime, presentations \\ %{}) do
    relations = d["relations"] || %{}
    legacy = d["flows"] || %{}
    selection = (flow_runtime && get_in(flow_runtime, ["flow_runtime", "selection"])) || %{}

    selected =
      for {name, s} <- Enum.sort(selection), is_map(s["projection"]), do: {name, s}

    covered = MapSet.new(for {_, s} <- selected, is_binary(s["legacy"]), do: s["legacy"])

    run_presenters =
      selected
      |> Enum.group_by(fn {_, s} -> {s["subject"], s["projection"]} end)
      |> Enum.sort()
      |> Enum.map(fn {{subject, projection}, group} ->
        old =
          for {_, s} <- group,
              flow = legacy[s["legacy"]],
              is_map(flow),
              into: %{},
              do: {s["legacy"], flow}

        states =
          Map.merge(
            Map.new(Enum.flat_map(old, fn {_, flow} -> open_states(flow) end)),
            Map.new(
              for {name, _} <- group,
                  {state, %{"present" => %{} = present}} <-
                    get_in(presentations, [name, "states"]) || %{},
                  do: {state, shown(present)}
            )
          )

        presenter(relations, subject, projection, states)
        |> Map.merge(%{
          "flows" =>
            for(
              {name, s} <- group,
              do: %{
                "name" => name,
                "follow_through" => s["follow_through"],
                "reopen" => s["reopen"],
                "admission" => s["admission"] || %{}
              }
            ),
          "legacy" => nil
        })
      end)

    legacy_presenters =
      for {name, flow} <- Enum.sort(legacy),
          is_map(flow),
          not MapSet.member?(covered, name),
          kind <- flow["kinds"] || [],
          do:
            presenter(relations, kind, flow, Map.new(open_states(flow)))
            |> Map.merge(%{"flows" => [], "legacy" => name})

    run_presenters ++ legacy_presenters
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

  defp open_states(flow) do
    for %{"name" => name} = s <- flow["states"] || [],
        s["done"] != true,
        do: {name, shown(s)}
  end

  defp shown(s) do
    %{"expected" => s["expected"], "why" => s["why"], "todo" => s["todo"]}
  end
end

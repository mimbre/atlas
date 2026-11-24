defmodule AtlasFlow.Runs.Inputs do
  @moduledoc "Typed Facts operation records. Roles in subject snapshots are never authority."

  @doc """
  The state an applied input of this run's entry moves the run to, or nil: it came
  after the cursor, on the subject's current version, and a branch of one of its roles
  takes the fields it changed (the compiled subflow `flow` says which).
  """
  def choice(input, run, subject, flow) do
    if input["status"] == "applied" and input["run"] == run["key"] and
         input["entry"] == run["entry"] and input["position"] > run["input_cursor"] and
         input["subject_version"] == subject["version"] do
      changed = input["changed_fields"]
      values = Map.merge(subject["values"] || %{}, changed)

      case flow.next(run["state"], values, %{roles: input["roles"], changed: changed}) do
        {:to, to} -> to
        :stay -> nil
      end
    end
  end

  @doc """
  What a pickup, hand-over or retry input asks of `run`, checked (work acquisition decision
  2026-11-17 §5.6, S1; the model's `supervision`, M3a):

  - `{:pick_up, holder}`: the input's actor becomes the run's supervisor (the same
    supervisor picking it up again changes nothing); an agent's pickup makes whom it
    assists the supervisor instead (`AtlasBus.Actors.assisted/1`; IS-Atlas-47);
  - `{:hand_over, from, to}`: the supervisor `from` is cleared, and `to` is the holder
    given the run to pick up;
  - `{:retry, holder}`: its supervisor takes the run back to the first state of the span
    it is in, with fresh agent work (IS-Atlas-09); an agent's retry is for whom it assists;
  - `{:refused, tag}`: the input is passed over, and only `tag` records why;
  - `nil`: not a supervision input this run takes (another operation, another run or
    generation, not applied, or at or before the cursor);
  - `:unavailable`: a holder could not be read now; nothing is decided.

  `supervision` is what the model says of the run's subflow: `"inputs"` (the input's
  `operation` and `hand_to` fields and the `operations` they name) and `"spans"` (its
  supervised spans, each with its `states`). `holder?` answers whether a key is a fact
  of the supervisor's kind: `true`, `false` or `:unavailable`. `waiting` answers what the
  run's subject waits for when its subflow takes its subjects in order
  (`AtlasBus.Order`): the key of the one to be picked up first, nil, or `:unavailable`.

  The checks, in order, each with its own tag: the input is of the run's current entry
  (`moved_on`); its actor (for a pickup or retry: whom it acts for) is a holder (`actor`);
  the run's state lies in a span (`outside_span`). A pickup needs the run unsupervised or
  supervised by that holder
  (`supervised`), and its subject first in order (`waiting`). A hand-over is the current supervisor's alone (`not_supervisor`, also
  when there is none), names exactly one target (`target`) that is a holder
  (`target_kind`), and never the supervisor itself (`self`). A retry is the current
  supervisor's alone (`not_supervisor`).
  """
  def supervision(input, run, supervision, holder?, waiting \\ fn -> nil end)

  def supervision(_input, _run, nil, _holder?, _waiting), do: nil

  def supervision(input, run, supervision, holder?, waiting) do
    fields = supervision["inputs"] || %{}
    operation = input[fields["operation"]]

    cond do
      operation not in (fields["operations"] || []) ->
        nil

      not (input["status"] == "applied" and input["run"] == run["key"] and
             input["generation"] in [nil, run["generation"]] and
             is_integer(input["position"]) and input["position"] > run["input_cursor"]) ->
        nil

      input["entry"] != run["entry"] ->
        {:refused, "moved_on"}

      true ->
        checked(operation, input, input[fields["hand_to"]], run, supervision, holder?, waiting)
    end
  end

  defp checked(operation, input, hand_to, run, supervision, holder?, waiting) do
    actor = input["actor"]
    current = run["supervised_by"]

    holder =
      if operation in ~w(pickup retry),
        do: AtlasBus.Actors.assisted(actor) || actor,
        else: actor

    with :ok <- holder(holder?, holder, "actor"),
         :ok <- in_span(supervision["spans"] || [], run["state"]) do
      case operation do
        "pickup" ->
          cond do
            current not in [nil, holder] -> {:refused, "supervised"}
            current == holder -> {:pick_up, holder}
            true -> first(waiting.(), holder)
          end

        "hand_over" ->
          with :ok <- need(current != nil and current == actor, "not_supervisor"),
               {:ok, to} <- target(hand_to),
               :ok <- holder(holder?, to, "target_kind"),
               :ok <- need(to != current, "self"),
               do: {:hand_over, current, to}

        "retry" ->
          if current != nil and current == holder,
            do: {:retry, holder},
            else: {:refused, "not_supervisor"}
      end
    end
  end

  # A pickup of a subject that waits for another is refused.
  defp first(nil, holder), do: {:pick_up, holder}
  defp first(:unavailable, _holder), do: :unavailable
  defp first(_key, _holder), do: {:refused, "waiting"}

  defp holder(holder?, key, tag) when is_binary(key) and key != "" do
    case holder?.(key) do
      true -> :ok
      false -> {:refused, tag}
      _ -> :unavailable
    end
  end

  defp holder(_holder?, _key, tag), do: {:refused, tag}

  defp in_span(spans, state),
    do: need(Enum.any?(spans, &(state in (&1["states"] || []))), "outside_span")

  # Exactly one holder named: the model's `hand_to` is one key.
  defp target(key) when is_binary(key) and key != "", do: {:ok, key}
  defp target([key]) when is_binary(key) and key != "", do: {:ok, key}
  defp target(_), do: {:refused, "target"}

  defp need(true, _tag), do: :ok
  defp need(_, tag), do: {:refused, tag}
end

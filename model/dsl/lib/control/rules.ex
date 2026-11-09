defmodule RelaDSL.Control.Rules do
  @moduledoc """
  What the compiled callbacks of `RelaDSL.Control.Model` call while they run: the rules
  that depend on a fact, its parts or who views it. Each rule is the one the model
  compiled, every name in it resolved; this module knows no kind and no field by name.
  """

  @doc "The shell, with the tabs the environment's settings add; nil without a shell."
  def shell(nil, _settings), do: nil

  def shell(%{} = shell, settings) do
    extra = if is_map(settings), do: List.wrap(settings["tabs"]), else: []
    Map.update(shell, "tabs", extra, &(List.wrap(&1) ++ extra))
  end

  @doc """
  The key of a new fact whose id is made from a field: the rule's `pattern` must match
  the field's value; `template` puts its groups in (`{1}`, `{2}`, …), after `replace` on
  each group, in lower case when `lower` is true. The same value always makes the same
  key. `{:error, text}` when it does not match.
  """
  def key(rule, values) do
    name = rule["from"]
    value = String.trim((is_map(values) && values[name]) || "")

    with pattern when is_binary(pattern) <- rule["pattern"],
         {:ok, regex} <- Regex.compile(pattern),
         [_ | groups] <- Regex.run(regex, value) do
      groups =
        Enum.map(groups, fn group ->
          Enum.reduce(rule["replace"] || %{}, group, fn {from, to}, acc ->
            String.replace(acc, from, to)
          end)
        end)

      key =
        Regex.replace(~r/\{(\d+)\}/, rule["template"] || "", fn _, n ->
          Enum.at(groups, String.to_integer(n) - 1) || ""
        end)

      {:ok, if(rule["lower"] == true, do: String.downcase(key), else: key)}
    else
      _ -> {:error, rule["error"] || "#{name} does not fit the rule for its id"}
    end
  end

  @doc """
  With no fact, the operations the kind offers by hand (`:create`, `:update`, `:delete`).
  With a fact, the actions its page offers: `%{op: :update}` and `%{op: :delete}` as the
  kind allows, then each action the model adds (`%{label, key, to}`) while the fact's
  fields have one of the values its `when` names.
  """
  def actions(rule, nil, _viewer), do: rule.by_hand

  def actions(rule, %{} = fact, _viewer) do
    values = fact["values"] || %{}

    for(
      op <- [:update, :delete],
      op in rule.by_hand,
      op != :update or rule.changeable,
      do: %{op: op}
    ) ++
      for described <- rule.described,
          Enum.all?(described.when, fn {field, allowed} ->
            to_text(values[field]) in allowed
          end),
          do: Map.take(described, [:label, :key, :to])
  end

  @doc """
  What the owner of `fact` is to do, when `viewer` (`%{key: …}`) is its owner: the flow
  on its kind writes its owner, what is expected and the state it is in on the fact or,
  for a flow `on` a component, on that part (`parts`, by kind). Nil for anyone else, or
  when the state says nothing to do.

  `%{title, expected, why, instructions, section, answers, words}`: `why` is `%{text,
  since, by}`; `section` the part of the fact's field the state names (`%{heading,
  text}`) or nil; each answer `%{key, label, note, change, set, remove}`.
  """
  def todo(flow, fact, parts, viewer) do
    with {written, %{"todo" => %{} = todo} = state} <- owner_state(flow, fact, parts, viewer) do
      origin = get_in(written, ["origins", flow.owner_relation]) || %{}

      section =
        with %{"field" => field, "heading" => heading} <- todo["section"],
             text when is_binary(text) <-
               section(to_text(get_in(fact, ["values", field])), heading),
             do: %{heading: heading, text: text},
             else: (_ -> nil)

      %{
        title: flow.words.title,
        expected: to_text(get_in(written, ["values", flow.field])),
        why: %{
          text: origin["cause"] || state["why"] || "—",
          since: origin["since"],
          by: origin["by"]
        },
        instructions: todo["instructions"],
        section: section,
        answers: Enum.map(answers(todo), &answer_view/1),
        words: flow.words
      }
    else
      _ -> nil
    end
  end

  @doc """
  The change the owner's answer `name` writes (`{:write, %{"values", "self", "label",
  "note"}}`: the values, `"$now"` for the moment it is given, the relation that links it
  to the one who answers, and whether a note is required), for an `item` (`%{"fact",
  "parts"}`) whose owner `viewer` is, in a state that offers it. `{:refuse, why}` else.
  """
  def answer(flow, name, item, viewer) do
    found =
      with %{} <- flow,
           %{"fact" => %{} = fact} <- item,
           {_written, %{"todo" => %{} = todo}} <-
             owner_state(flow, fact, item["parts"] || %{}, viewer) do
        Enum.find(answers(todo), &(&1["key"] == name and is_map(&1["change"])))
      else
        _ -> nil
      end

    case found do
      %{"change" => change} = answer ->
        {:write,
         %{
           "values" => change["values"] || %{},
           "self" => change["self"],
           "label" => answer["label"],
           "note" => answer["note"] == true
         }}

      nil ->
        {:refuse, "This answer is only available to the current owner in this state."}
    end
  end

  defp answers(todo), do: for(%{"key" => _, "label" => _} = a <- todo["answers"] || [], do: a)

  defp answer_view(a),
    do: %{
      key: a["key"],
      label: a["label"],
      note: a["note"] == true,
      change: is_map(a["change"]),
      set: if(is_binary(a["set"]), do: a["set"]),
      remove: if(is_binary(a["remove"]), do: a["remove"])
    }

  # The fact the flow writes on and the state it is in, when `viewer` is its owner.
  defp owner_state(flow, fact, parts, viewer) do
    written = if flow.on, do: flow.on_kind && (parts || %{})[flow.on_kind], else: fact

    with %{} <- written,
         by when is_binary(by) <- viewer && viewer[:key],
         true <- by in (get_in(written, ["links", flow.owner_relation]) || []),
         name when name not in [nil, ""] <- get_in(written, ["values", flow.state_field]),
         %{} = state <- flow.states[name] do
      {written, state}
    else
      _ -> nil
    end
  end

  @doc """
  The section of `text` under `heading`: from the line that starts with it ("Ada can
  test: …", or "## Ada can test") to the next heading line ("#" first), without the
  heading itself. Nil when there is none.
  """
  def section(text, heading) do
    lines = String.split(text || "", "\n")
    starts? = &String.starts_with?(String.downcase(&1), String.downcase(heading))

    unheaded = fn line ->
      line |> String.trim_leading() |> String.trim_leading("#") |> String.trim_leading()
    end

    case Enum.split_while(lines, &(not starts?.(unheaded.(&1)))) do
      {_, []} ->
        nil

      {_, [first | rest]} ->
        first = first |> unheaded.() |> String.slice(String.length(heading)..-1//1)
        first = first |> String.trim_leading(":") |> String.trim()
        body = Enum.take_while(rest, &(not String.match?(&1, ~r/^\s*#/)))

        case [first | body] |> Enum.join("\n") |> String.trim() do
          "" -> nil
          text -> text
        end
    end
  end

  defp to_text(nil), do: ""
  defp to_text(value) when is_binary(value), do: value
  defp to_text(value), do: to_string(value)
end

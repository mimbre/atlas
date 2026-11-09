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
  What the owner of `fact` is to do, when `viewer` (`%{key: …}`) is its owner, as Facts'
  presentation of its work says (`"presentation"` on the fact or, for work presented `on`
  a component, on that part, `parts` by kind): what is expected, why, and the state's
  todo. Nil for anyone else, or when the presentation offers nothing to do (no state, or
  one whose projection Flow has not written yet). While its run ended and the work was
  reopened, it says so to anyone (`reopened`, when the model words it), with no answers.

  `%{title, expected, why, instructions, section, answers, words}`: `why` is `%{text,
  since, by}`; `section` what the state shows of a fact's field (`%{heading, text}`):
  the part under its `heading`, or the whole field under its `label`; nil when that is
  empty. Each answer is `%{key, label, note, change, set, remove}`.
  """
  def todo(flow, fact, parts, viewer) do
    case owner_view(flow, fact, parts, viewer) do
      {written, %{"todo" => %{} = todo} = view} ->
        origin = get_in(written, ["origins", flow.owner_relation]) || %{}

        section = shown_section(todo["section"], fact)

        %{
          title: flow.words.title,
          expected: to_text(view["expected"]),
          why: %{
            text: origin["cause"] || view["why"] || "—",
            since: origin["since"],
            by: origin["by"]
          },
          instructions: todo["instructions"],
          section: section,
          answers: Enum.map(answers(todo), &answer_view/1),
          words: flow.words
        }

      _ ->
        reopened(flow, fact, parts)
    end
  end

  # What a state shows of a fact's field: the part under a heading, or all of it under a
  # label; nil when there is nothing to show.
  defp shown_section(%{"field" => field} = spec, fact) do
    value = to_text(get_in(fact, ["values", field]))

    text =
      case spec do
        %{"heading" => heading} -> section(value, heading)
        %{"label" => _} -> String.trim(value)
        _ -> nil
      end

    if is_binary(text) and text != "",
      do: %{heading: spec["heading"] || spec["label"], text: text}
  end

  defp shown_section(_spec, _fact), do: nil

  # Reopened work whose run ended: nothing is expected until its run is restarted
  # explicitly, and nobody owns it; said to anyone, in the model's words.
  defp reopened(flow, fact, parts) do
    with %{"reopened" => true} = view <- view(flow, fact, parts),
         text when text != "" <- flow.words[:reopened] || "" do
      %{
        title: flow.words.title,
        expected: text,
        why: %{text: view["why"] || "—", since: nil, by: nil},
        instructions: nil,
        section: nil,
        answers: [],
        words: flow.words
      }
    else
      _ -> nil
    end
  end

  @doc """
  The change the owner's answer `name` writes (`{:write, %{"values", "self", "label",
  "note"}}`: the values, `"$now"` for the moment it is given and `"$note"` for the note
  it is given with (trimmed), the relation that links it to the one who answers, and
  whether a note is required), for an `item` (`%{"fact",
  "parts"}`) whose owner `viewer` is, in a state that offers it. `{:refuse, why}` else.
  """
  def answer(flow, name, item, viewer) do
    found =
      with %{} <- flow,
           %{"fact" => %{} = fact} <- item,
           {_written, %{"todo" => %{} = todo}} <-
             owner_view(flow, fact, item["parts"] || %{}, viewer) do
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

  # The fact the work is presented on and its presentation, when `viewer` owns the work
  # and the presentation offers something to do.
  defp owner_view(flow, fact, parts, viewer) do
    with {written, view} <- written_view(flow, fact, parts),
         by when is_binary(by) <- viewer && viewer[:key],
         true <- by in (view["owner"] || []),
         true <- view["actionable"] == true do
      {written, view}
    else
      _ -> nil
    end
  end

  defp view(flow, fact, parts) do
    case written_view(flow, fact, parts) do
      {_written, view} -> view
      nil -> nil
    end
  end

  defp written_view(flow, fact, parts) do
    written = if flow.on, do: flow.on_kind && (parts || %{})[flow.on_kind], else: fact

    case written do
      %{"presentation" => %{} = view} -> {written, view}
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

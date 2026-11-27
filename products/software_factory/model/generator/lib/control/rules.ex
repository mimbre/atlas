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
  kind allows, then each action the model adds (`%{label, key, to, help}`) while the fact's
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
          do: Map.take(described, [:label, :key, :to, :help])
  end

  @doc """
  What the owner of `fact` is to do, when `viewer` (`%{key: …}`) is its owner, as Facts'
  presentation of its work says (`"presentation"` on the fact or, for work presented `on`
  a component, on that part, `parts` by kind): what is expected, why, and the state's
  todo. Nil for anyone else, or when the presentation offers nothing to do (no state, or
  one whose projection Flow has not written yet). An agent that assists the owner
  (`viewer.assists`) is offered the owner's answers on their behalf, but never one that
  links the one who answers (`self`: who accepted or decided is a person's own). While
  its run ended and the work was reopened, it says so to anyone (`reopened`, when the
  model words it), with no answers.

  `%{title, expected, why, instructions, section, answers, words, choice, panel}`: `why` is
  `%{text, since, by}`; `section` what the state shows of a fact's field (`%{heading,
  text}`): the part under its `heading`, or the whole field under its `label`; nil when
  that is empty. A section shown as steps (`steps: true`) has `steps: %{from}` too: the
  field the section shows. Each answer is `%{key, label, help, note, change, set,
  remove, weight, hand_over, choices}`, `weight` `"main"` (exactly one), `"decline"` (at most one) or `"other"`:
  as the model declares it, else the first answer main and the first other that asks a
  note decline. `panel` is the panel the kind's `panel` annotation declares for the state the
  work is in, as written (Control fills it); nil when it declares none.
  """
  def todo(flow, fact, parts, viewer) do
    case owner_view(flow, fact, parts, viewer) do
      {written, %{"todo" => %{} = todo} = view, on_behalf} ->
        todo = decision_todo(flow, fact, todo) |> for_whom(on_behalf)
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
          answers: presented_answers(todo),
          words: flow.words,
          choice: todo["single_choice"],
          panel: (flow[:panels] || %{})[view["state"]]
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

    if is_binary(text) and text != "" do
      shown = %{heading: spec["heading"] || spec["label"], text: text}

      if spec["steps"] == true,
        do: Map.put(shown, :steps, %{from: field}),
        else: shown
    end
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
  "note", "prompt", "cause", "on_behalf", "delegated", "append", "current"}}`: the values,
  `"$now"` for the moment it is given and `"$note"` for the note it is given with
  (trimmed), the relation that links it to the one who answers, whether a note is required
  and the question its form asks, how its cause is worded (`{note}`), whom an assisting
  agent answers for (nil when the viewer answers for itself), whether it is given under
  that one's delegation (`delegated`: the fact links whom its kind's
  `decision_options.delegated` relation names, the person who left it to its proposer,
  D-0106), the lines it adds to fields (`append`, `{note}` the note) and those fields as
  they are (`current`)), for an `item` (`%{"fact", "parts"}`) whose owner `viewer` is, or
  assists, in a state that offers it; or an answer the state offers the viewer as whom
  the fact links (`offers/4`). `{:refuse, why}` else.
  """
  def answer(flow, name, item, viewer) do
    found =
      with %{} <- flow,
           %{"fact" => %{} = fact} <- item,
           {_written, %{"todo" => %{} = todo}, on_behalf} <-
             owner_view(flow, fact, item["parts"] || %{}, viewer),
           %{} = answer <-
             Enum.find(
               answers(for_whom(decision_todo(flow, fact, todo), on_behalf)),
               &(&1["key"] == name and is_map(&1["change"]))
             ) do
        case {on_behalf, delegator(flow, fact)} do
          {nil, who} when is_binary(who) and who != viewer.key ->
            answer |> Map.put("on_behalf", who) |> Map.put("delegated", true)

          _ ->
            Map.put(answer, "on_behalf", on_behalf)
        end
      else
        _ -> offered(flow, name, item, viewer)
      end

    case found do
      %{"change" => change} = answer ->
        appended = change["append"] || %{}
        fact = item["fact"]

        {:write,
         %{
           "values" => change["values"] || %{},
           "self" => change["self"],
           "label" => answer["label"],
           "note" => answer["note"] == true,
           "prompt" => answer["prompt"],
           "cause" => answer["cause"],
           "on_behalf" => answer["on_behalf"],
           "delegated" => answer["delegated"] == true,
           "append" => appended,
           "current" =>
             Map.new(appended, fn {field, _} ->
               {field, to_text(get_in(fact, ["values", field]))}
             end)
         }}

      nil ->
        {:refuse, "This answer is only available to the current owner in this state."}
    end
  end

  # The person who left the fact to its proposer (D-0106), when the kind's single choice
  # names the relation (`decision_options.delegated`) and the fact links one; else nil.
  defp delegator(flow, fact) do
    with relation when is_binary(relation) <- get_in(flow, [:decision_options, "delegated"]),
         [who | _] when is_binary(who) <- List.wrap(get_in(fact, ["links", relation])) do
      who
    else
      _ -> nil
    end
  end

  # The answer `name` the state offers the viewer as whom the fact links (`by:`), with
  # whom an assisting agent answers for; nil when it offers none.
  defp offered(flow, name, item, viewer) do
    with %{} <- flow,
         %{"fact" => %{} = fact} <- item,
         %{} = todo <- offering(flow, fact, item["parts"] || %{}, viewer),
         {%{} = answer, on_behalf} <-
           Enum.find(
             by_answers(todo, fact, viewer),
             fn {a, _} -> a["key"] == name and is_map(a["change"]) end
           ) do
      Map.put(answer, "on_behalf", on_behalf)
    else
      _ -> nil
    end
  end

  @doc """
  The answers the state of the work on `fact` offers `viewer`, whoever owns the work:
  those it gives to whom the fact links through their `by:` relation (its producer), or
  to an agent that assists them (on their behalf, never one that links the one who
  answers). Each as `todo/4` gives an answer, the first one `main`; `[]` for anyone else,
  and while the presentation offers nothing to do.
  """
  def offers(flow, fact, parts, viewer) do
    case offering(flow, fact, parts, viewer) do
      %{} = todo ->
        for({a, _on_behalf} <- by_answers(todo, fact, viewer), do: Map.delete(a, "weight"))
        |> weighed()
        |> Enum.map(&answer_view/1)

      nil ->
        []
    end
  end

  defp offering(flow, fact, parts, viewer) do
    with {_written, %{"actionable" => true, "todo" => %{} = todo}} <-
           written_view(flow, fact, parts),
         true <- is_binary(viewer && viewer[:key]) do
      todo
    else
      _ -> nil
    end
  end

  # The state's answers `by:` a relation that links the viewer (`{answer, nil}`), or whom
  # it assists (`{answer, them}`, on their behalf: then none that links the one who
  # answers).
  defp by_answers(todo, fact, viewer) do
    for %{"key" => _, "label" => _, "by" => relation} = a <- todo["answers"] || [],
        on_behalf <- [answering_for(answer_recipients(a, fact, relation, viewer), viewer)],
        on_behalf != false,
        on_behalf == nil or not is_binary(get_in(a, ["change", "self"])),
        do: {a, on_behalf}
  end

  defp answer_recipients(answer, fact, relation, viewer) do
    case List.wrap(get_in(fact, ["links", relation])) do
      [] ->
        case {answer["fallback"], viewer[:decider]} do
          {"decider", key} when is_binary(key) and key != "" -> [key]
          _ -> []
        end

      linked ->
        linked
    end
  end

  defp answering_for(linked, viewer) do
    cond do
      viewer[:key] in linked -> nil
      is_binary(viewer[:assists]) and viewer[:assists] in linked -> viewer[:assists]
      true -> false
    end
  end

  @doc """
  The explicit restart of the run that presents `fact`, when that run is completed (a
  completed or reopened one) and `viewer` is one its selection's `restart_by` names:
  `owner`, one the owner relation links, or a configured actor's role (`actors`, `%{role
  => %{"key"}}`). `%{label, key, help, flow, run, inputs}`: the model's words for it, the
  subflow and run to restart, and the kind a request for it is kept as. Nil otherwise,
  and when the model words no restart. Facts checks the request again; this only offers.
  """
  def restart(flow, fact, parts, viewer, actors) do
    with %{label: label, key: key} = words <- flow.words[:restart],
         inputs when is_binary(inputs) <- flow.inputs,
         {_written, %{"status" => "completed", "run" => run} = view} when is_binary(run) <-
           written_view(flow, fact, parts),
         by when is_binary(by) <- viewer && viewer[:key],
         true <- restarter?(flow.restart_by[view["flow"]] || [], view, by, actors) do
      %{label: label, key: key, help: words[:help], flow: view["flow"], run: run, inputs: inputs}
    else
      _ -> nil
    end
  end

  defp restarter?(names, view, by, actors) do
    Enum.any?(names, fn
      "owner" -> by in (view["owner"] || [])
      role -> get_in(actors || %{}, [role, "key"]) == by
    end)
  end

  # The owner's answers: none the state gives to whom the fact links (`by:`, `offers/4`).
  defp answers(todo),
    do: for(%{"key" => _, "label" => _} = a <- todo["answers"] || [], a["by"] == nil, do: a)

  # A record with a single choice open to an answer: its adopt options are the answers
  # (`option`: one selects it), and after them the state's own answers but its main one
  # (Accept, which the options stand for): Decline with an alternative, Ask, Delegate
  # (D-0106).
  defp decision_todo(flow, fact, todo) do
    rule = flow[:decision_options]
    text = rule && get_in(fact, ["values", rule["definition"]])

    if text not in [nil, ""] and RelaDSL.DecisionOptions.open?(rule, fact) do
      offered =
        for a <- RelaDSL.DecisionOptions.answers(rule, fact), do: Map.put(a, "option", true)

      own = for a <- answers(todo), a["weight"] != "main", do: a

      case RelaDSL.DecisionOptions.decode(rule, text) do
        {:ok, definition} ->
          # The question and recommendation only; how keys select a choice is Control's.
          instructions =
            definition["question"] <>
              "\nRecommended: " <>
              hd(RelaDSL.DecisionOptions.ordered(definition))["text"] <>
              " — " <>
              definition["rationale"]

          todo
          |> Map.put("answers", offered ++ own)
          |> Map.put("instructions", instructions)
          |> Map.put("decision_options", true)
          |> Map.put(
            "single_choice",
            Map.put(definition, "revision", RelaDSL.DecisionOptions.revision(rule, text, fact))
          )

        _ ->
          Map.put(todo, "answers", own)
      end
    else
      todo
    end
  end

  # The options are numbered on their keys (1, 2, …), each keeping its semantic name; the
  # state's own answers keep their keys.
  defp presented_answers(%{"decision_options" => true} = todo) do
    answers(todo)
    |> weighed()
    |> Enum.map_reduce(1, fn
      %{"option" => true} = a, index ->
        {answer_view(a)
         |> Map.put(:name, a["key"])
         |> Map.put(:key, Integer.to_string(index))
         |> Map.put(:details, a["details"]), index + 1}

      a, index ->
        {answer_view(a), index}
    end)
    |> elem(0)
  end

  defp presented_answers(todo), do: todo |> answers() |> weighed() |> Enum.map(&answer_view/1)

  # Each answer's weight: as the model declares it; else the first answer main and the
  # first other that asks a note decline; the rest other.
  defp weighed([]), do: []

  defp weighed(answers) do
    main =
      Enum.find(answers, &(&1["weight"] == "main")) ||
        Enum.find(answers, &(&1["weight"] != "decline"))

    decline =
      Enum.find(answers, &(&1["weight"] == "decline")) ||
        Enum.find(answers, &(&1 != main and &1["note"] == true and &1["weight"] == nil))

    for a <- answers do
      Map.put(
        a,
        "weight",
        cond do
          a == main -> "main"
          a == decline -> "decline"
          true -> "other"
        end
      )
    end
  end

  # `prompt`: the question a note it needs asks; `icon`: what it does, by name; `help`:
  # what it does, in full; `hand_over`: it is the page's own hand-over (to someone else,
  # D-0106), or with a change a delegation, whose form chooses between the two in the
  # words of its `choices` (`%{change: %{label, help}, hand_over: %{label, help}}`).
  defp answer_view(a),
    do: %{
      key: a["key"],
      label: a["label"],
      help: if(is_binary(a["help"]), do: a["help"]),
      note: a["note"] == true,
      prompt: if(is_binary(a["prompt"]), do: a["prompt"]),
      icon: if(is_binary(a["icon"]), do: a["icon"]),
      weight: a["weight"],
      change: is_map(a["change"]),
      set: if(is_binary(a["set"]), do: a["set"]),
      remove: if(is_binary(a["remove"]), do: a["remove"]),
      hand_over: a["hand_over"] == true,
      choices: choices_view(a["choices"])
    }

  defp choices_view(%{"change" => change, "hand_over" => hand_over}),
    do: %{change: words_view(change), hand_over: words_view(hand_over)}

  defp choices_view(_), do: nil

  defp words_view(words),
    do: %{label: words["label"], help: if(is_binary(words["help"]), do: words["help"])}

  # An agent answering on behalf of whom it assists gets no answer that links the one who
  # answers: that answer is the person's own. A delegation keeps its hand-over: whom it
  # assists may have it handed to someone else, never left to the proposer.
  defp for_whom(todo, nil), do: todo

  defp for_whom(todo, _person),
    do:
      Map.update(todo, "answers", [], fn answers ->
        Enum.flat_map(answers, fn a ->
          cond do
            not is_binary(get_in(a, ["change", "self"])) -> [a]
            a["hand_over"] == true -> [Map.drop(a, ["change", "choices"])]
            true -> []
          end
        end)
      end)

  # The fact the work is presented on, its presentation and whom the viewer answers for
  # (nil: itself), when `viewer` owns the work, or assists its owner, and the presentation
  # offers something to do.
  defp owner_view(flow, fact, parts, viewer) do
    with {written, view} <- written_view(flow, fact, parts),
         by when is_binary(by) <- viewer && viewer[:key],
         owner = view["owner"] || [],
         on_behalf = if(by in owner, do: nil, else: viewer[:assists]),
         true <- by in owner or (is_binary(on_behalf) and on_behalf in owner),
         true <- view["actionable"] == true do
      {written, view, on_behalf}
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

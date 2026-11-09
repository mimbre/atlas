defmodule RelaDSL.DecisionOptions do
  @moduledoc """
  A decision's single-choice definition, owned by that decision and stored in Facts.
  The JSON text is an atomic value so order, recommendation and every option payload
  share one revision. Answer identity is a stable option ID plus the definition digest;
  neither positions nor input aliases are part of the recorded answer.
  """

  def decode(text) when is_binary(text) do
    with {:ok, %{} = definition} <- JSON.decode(text),
         true <- Enum.sort(Map.keys(definition)) == ~w(options question rationale recommended),
         true <- text?(definition["question"]) and text?(definition["rationale"]),
         options when is_list(options) and length(options) >= 2 <- definition["options"],
         true <- Enum.all?(options, &option?/1),
         ids = Enum.map(options, & &1["id"]),
         true <- length(ids) == length(Enum.uniq(ids)),
         true <- definition["recommended"] == hd(ids),
         # The decider can always refuse: an offer without a decline would take that away.
         true <- Enum.any?(options, &(&1["effect"] == "decline")) do
      {:ok, definition}
    else
      _ ->
        {:error,
         "a decision needs a question, rationale, distinct complete options with at least one decline, and the recommended option first"}
    end
  end

  def decode(_), do: {:error, "decision options must be a JSON definition"}

  defp text?(value), do: is_binary(value) and String.trim(value) != ""

  defp option?(%{} = option) do
    Enum.sort(Map.keys(option)) == ~w(consequences details effect id rule text) and
      is_binary(option["id"]) and Regex.match?(~r/^[a-z][a-z0-9_-]{0,63}$/, option["id"]) and
      Enum.all?(~w(text details), &text?(option[&1])) and
      case option["effect"] do
        "adopt" -> text?(option["rule"]) and text?(option["consequences"])
        "decline" -> option["rule"] == "" and option["consequences"] == ""
        _ -> false
      end
  end

  defp option?(_), do: false

  def revision(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  def revision(text, fact) do
    text |> revision_content(fact) |> :erlang.term_to_binary([:deterministic]) |> revision()
  end

  defp revision_content(text, fact) do
    %{
      "definition" => text,
      "values" =>
        Map.take(
          fact["values"] || %{},
          ~w(title decision consequences category scope reversibility force enforced_by context no_work)
        )
        |> Map.reject(fn {_, value} -> value in [nil, ""] end),
      "links" =>
        Map.new(~w(supersedes follows_from delegated_by), fn relation ->
          {relation, Enum.sort(get_in(fact, ["links", relation]) || [])}
        end)
    }
  end

  def with_change(nil, change, _lookup), do: change

  def with_change(rule, %{"op" => "change"} = change, lookup) do
    current = lookup["current"].() || %{}
    text = get_in(current, ["values", rule["definition"]])

    # A malformed stored history is left as it is; `check/5` refuses the write.
    with true <- records_offer?(rule, current, change["values"] || %{}, change["links"] || %{}),
         {:ok, history} <- history(get_in(current, ["values", rule["history"]])) do
      entry = revision_content(text, current) |> Map.put("revision", revision(text, current))
      put_in(change, ["values", rule["history"]], JSON.encode!(history ++ [entry]))
    else
      _ -> change
    end
  end

  def with_change(_rule, change, _lookup), do: change

  # Whether this change answers or edits an unanswered offer, so the offer it replaces
  # is kept in the history.
  defp records_offer?(rule, current, values, links) do
    old = current["values"] || %{}
    text = old[rule["definition"]]

    candidate = %{
      "values" => Map.merge(old, values),
      "links" => Map.merge(current["links"] || %{}, links)
    }

    text not in [nil, ""] and old["status"] == "proposed" and
      old[rule["selected"]] in [nil, ""] and
      (candidate["values"][rule["selected"]] not in [nil, ""] or
         revision(text, current) != revision(candidate["values"][rule["definition"]], candidate))
  end

  defp history(nil), do: {:ok, []}

  defp history(value) when is_binary(value) do
    case JSON.decode(value) do
      {:ok, entries} when is_list(entries) -> {:ok, entries}
      _ -> :error
    end
  end

  defp history(_value), do: :error

  def ordered(definition), do: definition["options"]

  def name(text, id, fact), do: "option-" <> revision(text, fact) <> "-" <> id

  def values(rule, text, option, fact) do
    %{
      rule["selected"] => option["id"],
      rule["snapshot"] => text,
      rule["revision"] => revision(text, fact),
      "status" => if(option["effect"] == "adopt", do: "accepted", else: "rejected"),
      "decided_at" => "$now"
    }
    |> Map.merge(
      if option["effect"] == "adopt",
        do: %{"decision" => option["rule"], "consequences" => option["consequences"]},
        else: %{}
    )
  end

  # Return semantic answers only. Numbered keys are a separate presentation adapter.
  def answers(rule, fact) do
    text = get_in(fact, ["values", rule["definition"]])

    with true <- get_in(fact, ["values", "status"]) == "proposed",
         {:ok, definition} <- decode(text) do
      for option <- ordered(definition) do
        %{
          "key" => name(text, option["id"], fact),
          "label" => option["text"],
          "details" => option["details"],
          "recommended" => option["id"] == definition["recommended"],
          # As with the a/f Reject: declining is given with a note saying why.
          "note" => option["effect"] == "decline",
          "change" => %{"self" => "decided_by", "values" => values(rule, text, option, fact)}
        }
      end
    else
      _ -> []
    end
  end

  def check(nil, _op, _current, _values, _links), do: []

  def check(rule, op, current, values, links) do
    old = (current || %{})["values"] || %{}
    after_values = Map.merge(old, values)
    text = after_values[rule["definition"]]
    selected = after_values[rule["selected"]]
    snapshot = after_values[rule["snapshot"]]

    cond do
      op == "delete" ->
        []

      Map.has_key?(values, rule["history"]) and values[rule["history"]] != old[rule["history"]] ->
        ["offered option history is maintained by Facts and never rewritten"]

      current != nil and records_offer?(rule, current, values, links) and
          history(old[rule["history"]]) == :error ->
        [
          "the stored offered option history is malformed; it must be repaired before this offer is changed or answered"
        ]

      old[rule["selected"]] not in [nil, ""] ->
        protected = [
          rule["definition"],
          rule["selected"],
          rule["snapshot"],
          rule["revision"],
          "decision",
          "consequences",
          "decided_at"
        ]

        if Enum.any?(protected, &(Map.get(after_values, &1) != old[&1])) or
             (Map.has_key?(values, "status") and values["status"] != old["status"] and
                not (old["status"] in ["accepted", "superseded"] and
                       values["status"] == "superseded")) or
             (Map.has_key?(links, "decided_by") and
                links["decided_by"] != get_in(current, ["links", "decided_by"])),
           do: ["the recorded option and offered definition are never edited"],
           else: []

      text in [nil, ""] ->
        if old[rule["definition"]] not in [nil, ""] or selected not in [nil, ""] or
             snapshot not in [nil, ""] or after_values[rule["revision"]] not in [nil, ""],
           do: ["decision options cannot be removed or answered without their definition"],
           else: []

      true ->
        with {:ok, definition} <- decode(text) do
          cond do
            selected in [nil, ""] ->
              if snapshot not in [nil, ""] or after_values[rule["revision"]] not in [nil, ""] or
                   after_values["status"] != "proposed",
                 do: ["select an offered option to decide this decision"],
                 else: []

            current == nil or old[rule["definition"]] != text or snapshot != text ->
              ["the offered decision options changed; open the decision again"]

            true ->
              option = Enum.find(definition["options"], &(&1["id"] == selected))
              expected = if option, do: values(rule, text, option, current)

              valid =
                option != nil and
                  Enum.all?(Map.delete(expected || %{}, "decided_at"), fn {k, v} ->
                    after_values[k] == v
                  end) and
                  text?(after_values["decided_at"]) and
                  after_values["decided_at"] != old["decided_at"] and
                  old["status"] == "proposed" and
                  revision(text, current) ==
                    revision(
                      text,
                      authority_subject(rule, current, %{
                        "values" => after_values,
                        "links" => Map.merge(current["links"] || %{}, links)
                      })
                    ) and
                  (option["effect"] != "decline" or
                     Enum.all?(~w(decision consequences), &(after_values[&1] == old[&1])))

              if valid,
                do: [],
                else: ["selection must apply exactly one offered option with its decision time"]
          end
        else
          {:error, why} -> [why]
        end
    end
  end

  # The gate authorized this exact set of options. Only the rule/consequences derived
  # from the validated selection may differ from its proposal fingerprint.
  def authority_subject(nil, _current, candidate), do: candidate

  def authority_subject(rule, %{} = current, candidate) do
    if get_in(current, ["values", rule["definition"]]) not in [nil, ""] and
         get_in(candidate, ["values", rule["selected"]]) not in [nil, ""] do
      Enum.reduce(~w(decision consequences), candidate, fn field, fact ->
        put_in(fact, ["values", field], get_in(current, ["values", field]))
      end)
    else
      candidate
    end
  end

  def authority_subject(_rule, _current, candidate), do: candidate

  # Pending records had this exact fingerprint scope before options existed; a decision
  # without options (historical or created without them) still matches it. No offered
  # decision may use it.
  def fingerprint_specs(rule, %{} = current, candidate, spec) when is_map(rule) do
    if get_in(current, ["values", rule["definition"]]) in [nil, ""] and
         get_in(candidate, ["values", rule["definition"]]) in [nil, ""] do
      [
        spec,
        %{
          "fields" => ~w(title decision category scope reversibility force),
          "relations" => ["supersedes"]
        }
      ]
    else
      [spec]
    end
  end

  def fingerprint_specs(_rule, _current, _candidate, spec), do: [spec]
end

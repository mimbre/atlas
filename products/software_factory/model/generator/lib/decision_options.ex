defmodule RelaDSL.DecisionOptions do
  @moduledoc """
  A record's single-choice definition, owned by that record and stored in Facts.
  The JSON text is an atomic value so order, recommendation and every option payload
  share one revision. Answer identity is a stable option ID plus the definition digest;
  neither positions nor input aliases are part of the recorded answer.

  The kind's `decision_options` annotation names everything kind-specific (`rule` below):
  the fields holding the definition, selection, snapshot, revision and history; the
  answer time field and answering relation; the status field and its values (`open`,
  `adopt`, `decline`, `superseded` and the statuses it supersedes, `replaceable`); the
  fields an adopted option sets from its payload (`adopt`); the content and links that
  make up an offer revision (`content`, `content_links`); the fingerprint of records
  without options (`legacy_fingerprint`); and the wording of the refusals (`errors`).
  """

  def decode(rule, text) when is_binary(text) do
    with {:ok, %{} = definition} <- JSON.decode(text),
         true <- Enum.sort(Map.keys(definition)) == ~w(options question rationale recommended),
         true <- text?(definition["question"]) and text?(definition["rationale"]),
         options when is_list(options) and length(options) >= 2 <- definition["options"],
         true <- Enum.all?(options, &option?/1),
         ids = Enum.map(options, & &1["id"]),
         true <- length(ids) == length(Enum.uniq(ids)),
         true <- definition["recommended"] == hd(ids),
         # Something to adopt: two alternatives, or one beside a decline (D-0103: a decline
         # is offered when there is one, never demanded).
         true <- Enum.any?(options, &(&1["effect"] == "adopt")) do
      {:ok, definition}
    else
      _ -> {:error, error(rule, "invalid")}
    end
  end

  def decode(rule, _), do: {:error, error(rule, "not_json")}

  # The annotation words its refusals; these neutral ones stand in for any it leaves out.
  @errors %{
    "invalid" =>
      "a choice needs a question, rationale, distinct complete options (two to adopt, or one to adopt and a decline), and the recommended option first",
    "not_json" => "the options must be a JSON definition",
    "removed" => "options cannot be removed or answered without their definition",
    "unselected" => "select an offered option to answer",
    "changed" => "the offered options changed; open the record again",
    "selection" => "selection must apply exactly one offered option with its answer time"
  }

  defp error(rule, key), do: get_in(rule, ["errors", key]) || @errors[key]

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

  # The record fields an adopted option sets from its payload.
  defp adopted(rule), do: Map.values(rule["adopt"] || %{})

  defp status(rule, key), do: get_in(rule, ["status", key])

  defp status_field(rule), do: status(rule, "field")

  @doc "Whether the record's offer is still open to an answer."
  def open?(rule, fact),
    do: get_in(fact, ["values", status_field(rule)]) == status(rule, "open")

  def revision(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  def revision(rule, text, fact) do
    rule
    |> revision_content(text, fact)
    |> :erlang.term_to_binary([:deterministic])
    |> revision()
  end

  defp revision_content(rule, text, fact) do
    %{
      "definition" => text,
      "values" =>
        Map.take(fact["values"] || %{}, rule["content"] || [])
        |> Map.reject(fn {_, value} -> value in [nil, ""] end),
      "links" =>
        Map.new(rule["content_links"] || [], fn relation ->
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
      entry =
        revision_content(rule, text, current)
        |> Map.put("revision", revision(rule, text, current))

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

    text not in [nil, ""] and open?(rule, current) and
      old[rule["selected"]] in [nil, ""] and
      (candidate["values"][rule["selected"]] not in [nil, ""] or
         revision(rule, text, current) !=
           revision(rule, candidate["values"][rule["definition"]], candidate))
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

  def name(rule, text, id, fact), do: "option-" <> revision(rule, text, fact) <> "-" <> id

  def values(rule, text, option, fact) do
    %{
      rule["selected"] => option["id"],
      rule["snapshot"] => text,
      rule["revision"] => revision(rule, text, fact),
      status_field(rule) =>
        if(option["effect"] == "adopt",
          do: status(rule, "adopt"),
          else: status(rule, "decline")
        ),
      rule["answered_at"] => "$now"
    }
    |> Map.merge(
      if option["effect"] == "adopt",
        do: Map.new(rule["adopt"] || %{}, fn {payload, field} -> {field, option[payload]} end),
        else: %{}
    )
  end

  # Return semantic answers only. Numbered keys are a separate presentation adapter.
  def answers(rule, fact) do
    text = get_in(fact, ["values", rule["definition"]])

    with true <- open?(rule, fact),
         {:ok, definition} <- decode(rule, text) do
      for option <- ordered(definition) do
        %{
          "key" => name(rule, text, option["id"], fact),
          "label" => option["text"],
          "details" => option["details"],
          "recommended" => option["id"] == definition["recommended"],
          # As with the a/f Reject: declining is given with a note saying why.
          "note" => option["effect"] == "decline",
          "change" => %{
            "self" => rule["answered_by"],
            "values" => values(rule, text, option, fact)
          }
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
    field = status_field(rule)
    answered_at = rule["answered_at"]
    answered_by = rule["answered_by"]

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
        protected =
          [rule["definition"], rule["selected"], rule["snapshot"], rule["revision"]] ++
            adopted(rule) ++ [answered_at]

        if Enum.any?(protected, &(Map.get(after_values, &1) != old[&1])) or
             (Map.has_key?(values, field) and values[field] != old[field] and
                not (old[field] in (status(rule, "replaceable") || []) and
                       values[field] == status(rule, "superseded"))) or
             (Map.has_key?(links, answered_by) and
                links[answered_by] != get_in(current, ["links", answered_by])),
           do: ["the recorded option and offered definition are never edited"],
           else: []

      text in [nil, ""] ->
        if old[rule["definition"]] not in [nil, ""] or selected not in [nil, ""] or
             snapshot not in [nil, ""] or after_values[rule["revision"]] not in [nil, ""],
           do: [error(rule, "removed")],
           else: []

      true ->
        with {:ok, definition} <- decode(rule, text) do
          cond do
            selected in [nil, ""] ->
              if snapshot not in [nil, ""] or after_values[rule["revision"]] not in [nil, ""] or
                   after_values[field] != status(rule, "open"),
                 do: [error(rule, "unselected")],
                 else: []

            current == nil or old[rule["definition"]] != text or snapshot != text ->
              [error(rule, "changed")]

            true ->
              option = Enum.find(definition["options"], &(&1["id"] == selected))
              expected = if option, do: values(rule, text, option, current)

              valid =
                option != nil and
                  Enum.all?(Map.delete(expected || %{}, answered_at), fn {k, v} ->
                    after_values[k] == v
                  end) and
                  text?(after_values[answered_at]) and
                  after_values[answered_at] != old[answered_at] and
                  open?(rule, current) and
                  revision(rule, text, current) ==
                    revision(
                      rule,
                      text,
                      authority_subject(rule, current, %{
                        "values" => after_values,
                        "links" => Map.merge(current["links"] || %{}, links)
                      })
                    ) and
                  (option["effect"] != "decline" or
                     Enum.all?(adopted(rule), &(after_values[&1] == old[&1])))

              if valid,
                do: [],
                else: [error(rule, "selection")]
          end
        else
          {:error, why} -> [why]
        end
    end
  end

  # The gate authorized this exact set of options. Only the fields derived from the
  # validated selection (`adopt`) may differ from its proposal fingerprint.
  def authority_subject(nil, _current, candidate), do: candidate

  def authority_subject(rule, %{} = current, candidate) do
    if get_in(current, ["values", rule["definition"]]) not in [nil, ""] and
         get_in(candidate, ["values", rule["selected"]]) not in [nil, ""] do
      Enum.reduce(adopted(rule), candidate, fn field, fact ->
        put_in(fact, ["values", field], get_in(current, ["values", field]))
      end)
    else
      candidate
    end
  end

  def authority_subject(_rule, _current, candidate), do: candidate

  # Records pending before options existed had the annotation's `legacy_fingerprint`; a
  # record without options (historical or created without them) still matches it. No
  # offered record may use it.
  def fingerprint_specs(rule, %{} = current, candidate, spec) when is_map(rule) do
    if is_map(rule["legacy_fingerprint"]) and
         get_in(current, ["values", rule["definition"]]) in [nil, ""] and
         get_in(candidate, ["values", rule["definition"]]) in [nil, ""] do
      [spec, rule["legacy_fingerprint"]]
    else
      [spec]
    end
  end

  def fingerprint_specs(_rule, _current, _candidate, spec), do: [spec]
end

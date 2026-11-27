defmodule RelaDSL.DecisionOptions do
  @moduledoc """
  A record's single-choice definition, owned by that record and stored in Facts.
  The JSON text is an atomic value so order, recommendation and every option payload
  share one revision. Answer identity is a stable option ID plus the definition digest;
  neither positions nor input aliases are part of the recorded answer.

  The kind's `decision_options` annotation names everything kind-specific (`rule` below):
  the fields holding the definition, selection, snapshot, revision and history; the
  answer time field and answering relation; the status field and its values (`open`,
  `adopt`, `superseded` and the statuses it supersedes, `replaceable`, and the
  statuses an unanswered offer goes back to its proposer in, `returned`); the fields an
  adopted option sets from its payload (`adopt`); the field whose text, written with the
  status that sends the offer back to be revised, becomes a new adopt option
  (`alternative`: `%{"field", "status"}`, D-0106); the relation to the person who left the
  choice to its proposer (`delegated`); the content and links that make up an offer
  revision (`content`, `content_links`); the fingerprint of records without options
  (`legacy_fingerprint`); and the wording of the refusals (`errors`).

  New definitions hold alternatives to adopt only. Stored definitions may also contain
  legacy decline options, which remain in snapshots and history but are never offered.
  Declining sends an alternative back to the proposer (D-0106).
  """

  def decode(rule, text), do: decode(rule, text, false)

  def decode_stored(rule, text), do: decode(rule, text, true)

  defp decode(rule, text, legacy?) when is_binary(text) do
    with {:ok, %{} = definition} <- JSON.decode(text),
         true <- Enum.sort(Map.keys(definition)) == ~w(options question rationale recommended),
         true <- text?(definition["question"]) and text?(definition["rationale"]),
         [_ | _] = options <- definition["options"],
         :ok <- if(legacy?, do: :ok, else: no_decline(rule, options)),
         true <- Enum.all?(options, &option?(&1, legacy?)),
         ids = Enum.map(options, & &1["id"]),
         true <- length(ids) == length(Enum.uniq(ids)),
         true <- definition["recommended"] == hd(ids),
         true <- hd(options)["effect"] == "adopt" do
      {:ok, definition}
    else
      {:error, _} = refused -> refused
      _ -> {:error, error(rule, "invalid")}
    end
  end

  defp decode(rule, _, _legacy?), do: {:error, error(rule, "not_json")}

  defp no_decline(rule, options) do
    if Enum.any?(options, &match?(%{"effect" => "decline"}, &1)),
      do: {:error, error(rule, "no_option")},
      else: :ok
  end

  # The annotation words its refusals; these neutral ones stand in for any it leaves out.
  @errors %{
    "invalid" =>
      "a choice needs a question, rationale, distinct complete alternatives (at least one), and the recommended alternative first",
    "no_option" => "a choice has no 'no' option; declining is always available",
    "not_json" => "the options must be a JSON definition",
    "removed" => "options cannot be removed or answered without their definition",
    "unselected" => "select an offered option to answer",
    "changed" => "the offered options changed; open the record again",
    "selection" => "selection must apply exactly one offered option with its answer time",
    "unworded" => "work out each alternative's rule and consequences before offering it again"
  }

  defp error(rule, key), do: get_in(rule, ["errors", key]) || @errors[key]

  defp text?(value), do: is_binary(value) and String.trim(value) != ""

  # An option: its id, text, details, effect (adopt) and payload; one added from whoever
  # declined says whose it is (`by`), and has no rule or consequences until its proposer
  # works it out (`unworded?/1`).
  defp option?(%{} = option, legacy?) do
    Enum.sort(Map.keys(Map.delete(option, "by"))) == ~w(consequences details effect id rule text) and
      (not Map.has_key?(option, "by") or text?(option["by"])) and
      is_binary(option["id"]) and Regex.match?(~r/^[a-z][a-z0-9_-]{0,63}$/, option["id"]) and
      Enum.all?(~w(text details), &text?(option[&1])) and
      ((option["effect"] == "adopt" and
          ((text?(option["rule"]) and text?(option["consequences"])) or
             (Map.has_key?(option, "by") and unworded?(option)))) or
         (legacy? and option["effect"] == "decline" and option["rule"] == "" and
            option["consequences"] == ""))
  end

  defp option?(_, _), do: false

  # An alternative to adopt that its proposer has not worked out yet: no rule, no
  # consequences. It is never offered so.
  defp unworded?(option),
    do: option["effect"] == "adopt" and option["rule"] == "" and option["consequences"] == ""

  # The record fields an adopted option sets from its payload.
  defp adopted(rule), do: Map.values(rule["adopt"] || %{})

  defp status(rule, key), do: get_in(rule, ["status", key])

  defp status_field(rule), do: status(rule, "field")

  @doc "Whether the record's offer is still open to an answer."
  def open?(rule, fact),
    do: get_in(fact, ["values", status_field(rule)]) == status(rule, "open")

  # The statuses an unanswered offer may hold: open, or gone back to its proposer.
  defp unanswered(rule), do: [status(rule, "open") | List.wrap(status(rule, "returned"))]

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
    change = with_alternative(rule, change, current)

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

  # A decline sends the open offer back to its proposer with the alternative of whoever
  # declined (D-0106): the change that sets the revise status with a text in the
  # alternative field adds that text to the definition as a new adopt option, theirs
  # (`by`): its title only, with a note whose it is, its rule and consequences empty until
  # the proposer works them out (it is not offered again before). The recommendation
  # stays; the proposer sets it. A record without a definition keeps the alternative in
  # its field only.
  defp with_alternative(rule, change, current) do
    values = change["values"] || %{}
    field = get_in(rule, ["alternative", "field"])
    alternative = String.trim(to_string(field && values[field]))
    text = get_in(current, ["values", rule["definition"]])

    with true <- alternative != "",
         true <- values[status_field(rule)] == get_in(rule, ["alternative", "status"]),
         true <- open?(rule, current),
         false <- Map.has_key?(values, rule["definition"]),
         {:ok, definition} <- decode_stored(rule, text) do
      by = change["by"]
      by = if is_binary(by) and by != "", do: by, else: nil

      option =
        %{
          "id" => alternative_id(definition["options"]),
          "text" => alternative,
          "details" =>
            "#{if(by, do: "#{by}'s", else: "The decider's")} alternative, to be worked out by the proposer",
          "effect" => "adopt",
          "rule" => "",
          "consequences" => ""
        }
        |> then(&if(by, do: Map.put(&1, "by", by), else: &1))

      definition = Map.update!(definition, "options", &(&1 ++ [option]))
      put_in(change, ["values", rule["definition"]], JSON.encode!(definition))
    else
      _ -> change
    end
  end

  defp alternative_id(options) do
    ids = MapSet.new(options, & &1["id"])

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(&if(&1 == 1, do: "alternative", else: "alternative-#{&1}"))
    |> Enum.find(&(not MapSet.member?(ids, &1)))
  end

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

  def ordered(definition), do: Enum.filter(definition["options"], &(&1["effect"] == "adopt"))

  def name(rule, text, id, fact), do: "option-" <> revision(rule, text, fact) <> "-" <> id

  def values(rule, text, option, fact) do
    %{
      rule["selected"] => option["id"],
      rule["snapshot"] => text,
      rule["revision"] => revision(rule, text, fact),
      status_field(rule) => status(rule, "adopt"),
      rule["answered_at"] => "$now"
    }
    |> Map.merge(
      Map.new(rule["adopt"] || %{}, fn {payload, field} -> {field, option[payload]} end)
    )
  end

  # Return semantic answers only. Numbered keys are a separate presentation adapter. An
  # alternative is answered by selecting it; declining is the state's own answer, with an
  # alternative (D-0106).
  def answers(rule, fact) do
    text = get_in(fact, ["values", rule["definition"]])

    with true <- open?(rule, fact),
         {:ok, definition} <- decode_stored(rule, text) do
      for option <- ordered(definition) do
        %{
          "key" => name(rule, text, option["id"], fact),
          "label" => option["text"],
          "details" => option["details"],
          "recommended" => option["id"] == definition["recommended"],
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
        decoder =
          if Map.has_key?(values, rule["definition"]), do: &decode/2, else: &decode_stored/2

        with {:ok, definition} <- decoder.(rule, text) do
          cond do
            after_values[field] == status(rule, "open") and
                Enum.any?(definition["options"], &unworded?/1) ->
              [error(rule, "unworded")]

            selected in [nil, ""] ->
              if snapshot not in [nil, ""] or after_values[rule["revision"]] not in [nil, ""] or
                   after_values[field] not in unanswered(rule),
                 do: [error(rule, "unselected")],
                 else: []

            current == nil or old[rule["definition"]] != text or snapshot != text ->
              [error(rule, "changed")]

            true ->
              option = Enum.find(ordered(definition), &(&1["id"] == selected))
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
                    )

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

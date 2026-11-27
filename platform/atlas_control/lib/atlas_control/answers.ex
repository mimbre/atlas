defmodule AtlasControl.Answers do
  @moduledoc """
  Build one declared answer as one Facts change: the change the model's `answer/4`
  gives (`%{"values", "self", "label", "note", "prompt", "cause", "on_behalf",
  "delegated", "append", "current"}`), by `by`, at `now`; `self` nil links nobody. A value
  `"$now"` is the moment it is given, and `"$note"` the note it is given with (as it is
  given, so a field can keep it as well as the change's cause). A field it adds a line to
  (`append`, its line with `{note}` filled in) keeps what it holds (`current`), the line
  on a line of its own after it. A submitted append requires the fact's read version and
  asks Facts to refuse every version mismatch, even an identical independent append.
  A note it needs and is given without is asked again, with its `prompt` when it has one.
  Its cause is the note, or its `cause` with `{note}` filled in when it words one
  (`asked: {note}`).
  An answer an agent gives for whom it assists (`on_behalf`) stays the agent's; its cause
  says on whose behalf. One given under a delegation (`delegated`, D-0106: its decider
  left it to its proposer) says it is decided by `by` on their behalf, delegated.
  """

  def change(answer, key, by, note, now, version) do
    with {:ok, content, cause} <- change(answer, key, by, note, now) do
      if map_size(answer["append"] || %{}) == 0 do
        {:ok, content, cause}
      else
        if is_nil(version) do
          {:error, "This item has no current version; open it again before adding your answer."}
        else
          {:ok, content |> Map.put("version", version) |> Map.put("strict_version", true), cause}
        end
      end
    end
  end

  def change(answer, key, by, note, now) do
    note = String.trim(note || "")

    if answer["note"] == true and note == "" do
      {:error, answer["prompt"] || "a note is required: why"}
    else
      values =
        Map.new(answer["values"] || %{}, fn {field, value} ->
          {field,
           case value do
             "$now" -> DateTime.to_iso8601(now)
             "$note" -> note
             value -> value
           end}
        end)

      values =
        Enum.reduce(answer["append"] || %{}, values, fn {field, line}, values ->
          line = String.replace(line, "{note}", note)

          Map.put(
            values,
            field,
            case String.trim_trailing((answer["current"] || %{})[field] || "") do
              "" -> line
              held -> held <> "\n" <> line
            end
          )
        end)

      # The relation that links the fact to the one who answers, when the answer names one.
      links = if answer["self"], do: %{answer["self"] => [by]}, else: %{}

      content = %{
        "op" => "change",
        "key" => key,
        "values" => values,
        "links" => links,
        "version" => nil
      }

      note =
        if is_binary(answer["cause"]) and note != "",
          do: String.replace(answer["cause"], "{note}", note),
          else: note

      cause =
        case {note, answer["on_behalf"], answer["delegated"] == true} do
          {"", who, true} when is_binary(who) ->
            "#{answer["label"]}: decided by #{by} on behalf of #{who}, delegated"

          {note, who, true} when is_binary(who) ->
            "#{note} (decided by #{by} on behalf of #{who}, delegated)"

          {"", nil, _} ->
            "#{answer["label"]} by #{by}"

          {"", who, _} ->
            "#{answer["label"]} by #{by} on behalf of #{who}"

          {note, nil, _} ->
            note

          {note, who, _} ->
            "#{note} (#{by} on behalf of #{who})"
        end

      {:ok, content, cause}
    end
  end
end

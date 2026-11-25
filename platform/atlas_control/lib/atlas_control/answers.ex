defmodule AtlasControl.Answers do
  @moduledoc """
  Build one declared owner answer as one Facts change: the change the model's `answer/4`
  gives (`%{"values", "self", "label", "note", "on_behalf"}`), by `by`, at `now`; `self`
  nil links nobody. A value `"$now"` is the moment it is given, and `"$note"` the note it
  is given with (as it is given, so a field can keep it as well as the change's cause).
  An answer an agent gives for whom it assists (`on_behalf`) stays the agent's; its cause
  says on whose behalf.
  """

  def change(answer, key, by, note, now) do
    note = String.trim(note || "")

    if answer["note"] == true and note == "" do
      {:error, "a note is required: why"}
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

      # The relation that links the fact to the one who answers, when the answer names one.
      links = if answer["self"], do: %{answer["self"] => [by]}, else: %{}

      content = %{
        "op" => "change",
        "key" => key,
        "values" => values,
        "links" => links,
        "version" => nil
      }

      cause =
        case {note, answer["on_behalf"]} do
          {"", nil} -> "#{answer["label"]} by #{by}"
          {"", who} -> "#{answer["label"]} by #{by} on behalf of #{who}"
          {note, nil} -> note
          {note, who} -> "#{note} (#{by} on behalf of #{who})"
        end

      {:ok, content, cause}
    end
  end
end

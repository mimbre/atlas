defmodule AtlasControl.Answers do
  @moduledoc """
  Build one declared owner answer as one Facts change: the change the model's `answer/4`
  gives (`%{"values", "self", "label", "note"}`), by `by`, at `now`; `self` nil links
  nobody.
  """

  def change(answer, key, by, note, now) do
    note = String.trim(note || "")

    if answer["note"] == true and note == "" do
      {:error, "a note is required: why"}
    else
      values =
        Map.new(answer["values"] || %{}, fn {field, value} ->
          {field, if(value == "$now", do: DateTime.to_iso8601(now), else: value)}
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

      cause = if note == "", do: "#{answer["label"]} by #{by}", else: note
      {:ok, content, cause}
    end
  end
end

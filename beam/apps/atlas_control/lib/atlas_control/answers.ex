defmodule AtlasControl.Answers do
  @moduledoc "Build one declared owner answer as one Facts change."

  def change(answer, key, by, note, now) do
    note = String.trim(note || "")

    if answer["note"] == true and note == "" do
      {:error, "a note is required: why"}
    else
      change = answer["change"]

      values =
        Map.new(change["values"], fn {field, value} ->
          {field, if(value == "$now", do: DateTime.to_iso8601(now), else: value)}
        end)

      content = %{
        "op" => "change",
        "key" => key,
        "values" => values,
        "links" => %{change["self"] => [by]},
        "version" => nil
      }

      cause = if note == "", do: "#{answer["label"]} by #{by}", else: note
      {:ok, content, cause}
    end
  end
end

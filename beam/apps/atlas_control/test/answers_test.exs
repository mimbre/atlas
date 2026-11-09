defmodule AtlasControl.AnswersTest do
  use ExUnit.Case, async: true
  alias AtlasControl.Answers
  @now ~U[2026-11-12 00:00:00Z]

  test "answers write the self link and declared values together; a required note is the cause" do
    for {label, value, note?} <- [{"Accept", "final", false}, {"Reject", "dropped", true}] do
      answer = %{
        "label" => label,
        "note" => note?,
        "change" => %{
          "self" => "signed_by",
          "values" => %{"phase" => value, "signed_at" => "$now"}
        }
      }

      if note?, do: assert({:error, _} = Answers.change(answer, "B-1", "ada", " \n", @now))
      assert {:ok, content, cause} = Answers.change(answer, "B-1", "ada", "My reason", @now)
      assert content["values"] == %{"phase" => value, "signed_at" => "2026-11-12T00:00:00Z"}
      assert content["links"] == %{"signed_by" => ["ada"]}
      assert cause == "My reason"
    end
  end
end

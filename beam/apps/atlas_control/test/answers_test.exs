defmodule AtlasControl.AnswersTest do
  use ExUnit.Case, async: true
  alias AtlasControl.Answers
  @now ~U[2026-11-12 00:00:00Z]

  test "answers write the self link and declared values together; a required note is the cause" do
    for {label, value, note?} <- [{"Accept", "final", false}, {"Reject", "dropped", true}] do
      # As the model's answer/4 gives it.
      answer = %{
        "label" => label,
        "note" => note?,
        "self" => "signed_by",
        "values" => %{"phase" => value, "signed_at" => "$now"}
      }

      if note?, do: assert({:error, _} = Answers.change(answer, "B-1", "ada", " \n", @now))
      assert {:ok, content, cause} = Answers.change(answer, "B-1", "ada", "My reason", @now)
      assert content["values"] == %{"phase" => value, "signed_at" => "2026-11-12T00:00:00Z"}
      assert content["links"] == %{"signed_by" => ["ada"]}
      assert cause == "My reason"
    end
  end

  test "an answer may keep its note in a field as well as giving it as the cause" do
    answer = %{
      "label" => "Close",
      "note" => true,
      "values" => %{"phase" => "closed", "how" => "$note"}
    }

    assert {:error, _} = Answers.change(answer, "B-1", "ada", "", @now)
    assert {:ok, content, cause} = Answers.change(answer, "B-1", "ada", " Filed it \n", @now)
    assert content["values"] == %{"phase" => "closed", "how" => "Filed it"}
    assert content["links"] == %{}
    assert cause == "Filed it"
  end
end

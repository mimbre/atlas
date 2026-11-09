defmodule AtlasFlow.Runs.ConditionsTest do
  use ExUnit.Case, async: true
  alias AtlasFlow.Runs.Conditions

  test "closed grammar table and pinned comparison, conjunction, disjunction precedence" do
    values = %{"x" => 3, "flag" => true, "choice" => "yes", "text" => "long value"}

    for {expression, expected} <- [
          {"entity.x == 3", true},
          {"entity.x != 3", false},
          {"entity.x > 2", true},
          {"entity.x >= 3", true},
          {"entity.x < 3", false},
          {"entity.x <= 3", true},
          {"entity.x == 3 or entity.x == 0 and entity.flag == false", true},
          {"(entity.x == 3 or entity.x == 0) and entity.flag == false", false},
          {"entity.x > 1 and (entity.choice == 'yes' or entity.x < -1.5)", true},
          {"entity.text == 'long value'", true},
          {"entity.absent != 'yes'", false},
          {"entity.absent == false", false},
          {"entity.absent > 0 or entity.flag == true", true},
          {"entity.text > 1", false}
        ] do
      assert {:ok, _} = Conditions.compile(expression)
      assert Conditions.matches?(expression, values) == expected, expression
    end
  end

  test "unknown syntax and executable text refuse compilation, including suffixes" do
    for text <- [
          "",
          "true",
          "entity.x",
          "entity.x = 3",
          "entity.x == 3 trailing",
          "entity.x == 3 == 3",
          "entity.x == other.x",
          "entity.x in [1]",
          "not entity.flag",
          "entity.x == 3 && entity.flag == true",
          "(entity.x == 3",
          "entity.x == nil",
          "System.cmd('anything')",
          "entity.x == 'unterminated",
          "entity.x == 'a\\b'"
        ] do
      assert {:error, :unsupported_condition} = Conditions.compile(text), text
    end
  end
end

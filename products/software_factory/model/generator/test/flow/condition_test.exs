defmodule RelaDSL.Flow.ConditionTest do
  use ExUnit.Case, async: true
  alias RelaDSL.Flow.Condition

  # The compiled code of a condition, run on `values`.
  defp holds?(text, values) do
    {:ok, tree} = Condition.compile(text)

    {result, _} =
      Code.eval_quoted(Condition.quoted(tree, Macro.var(:values, nil)), values: values)

    result
  end

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
          {"entity.text > 1", false},
          {"not (entity.x == 3)", false},
          {"not (entity.choice == 'no')", true},
          {"not (entity.absent == '')", false},
          {"not (entity.absent == 1) or entity.flag == true", true},
          {"not (entity.absent == 1) and entity.flag == false", false},
          {"not (entity.x == 3 or entity.flag == false) or entity.x == 0", false},
          {"not (not (entity.x == 3))", true},
          {"entity.x == 0 or not (entity.flag == false) and entity.x > 1", true}
        ] do
      assert holds?(expression, values) == expected, expression
    end
  end

  test "the fields a condition reads" do
    {:ok, tree} = Condition.compile("entity.x == 3 or (entity.y == 'a' and entity.x > 1)")
    assert Condition.fields(tree) == ["x", "y"]

    {:ok, tree} = Condition.compile("not (entity.z == '') and entity.x > 1")
    assert Condition.fields(tree) == ["z", "x"]
  end

  # The negation the pinned rela parses (it has no `!`), and its compiled meaning: as `!=`
  # was, an absent field is no match and an empty one neither.
  test "not (… == '') holds on a text that is there and not empty" do
    for {values, expected} <- [
          {%{"text" => "Do it."}, true},
          {%{"text" => ""}, false},
          {%{}, false}
        ] do
      assert holds?("not (entity.text == '')", values) == expected, inspect(values)
      assert holds?("entity.text != ''", values) == expected, inspect(values)
    end
  end

  # Two fields that must agree (the head a CI status was read for and the head pushed):
  # equal only when both are there; an absent one makes it unknown, no match either way.
  test "two fields agree or differ; an absent one is no match" do
    for {values, same, differ} <- [
          {%{"read" => "abc", "pushed" => "abc"}, true, false},
          {%{"read" => "abc", "pushed" => "def"}, false, true},
          {%{"read" => "abc"}, false, false},
          {%{}, false, false}
        ] do
      assert holds?("entity.read == entity.pushed", values) == same, inspect(values)
      assert holds?("entity.read != entity.pushed", values) == differ, inspect(values)
    end

    assert holds?(
             "entity.state == 'failure' and entity.read == entity.pushed",
             %{"state" => "failure", "read" => "abc", "pushed" => "abc"}
           )

    {:ok, tree} = Condition.compile("entity.state == 'x' and entity.read == entity.pushed")
    assert Condition.fields(tree) == ["state", "read", "pushed"]
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
          "entity.x > entity.y",
          "entity.x == entity.y == 3",
          "entity.x in [1]",
          "not entity.flag",
          "not entity.x == 3",
          "not (entity.x == 3",
          "not ()",
          "entity.x == 3 not",
          "!(entity.x == 3)",
          "entity.x == 3 && entity.flag == true",
          "(entity.x == 3",
          "entity.x == nil",
          "System.cmd('anything')",
          "entity.x == 'unterminated",
          "entity.x == 'a\\b'",
          nil
        ] do
      assert {:error, :unsupported_condition} = Condition.compile(text), inspect(text)
    end
  end
end

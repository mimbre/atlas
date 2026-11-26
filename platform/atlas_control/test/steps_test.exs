defmodule AtlasControl.StepsTest do
  @moduledoc """
  A to-do's instructions as steps (`AtlasControl.Steps`): the lead paragraph is why, each
  numbered line starts a step, a `$ ` line in a step is a command; text without numbered
  steps is one step.
  """
  use ExUnit.Case, async: true
  alias AtlasControl.Steps

  test "a lead, numbered steps, and the commands of a step without their $" do
    text = """
    Why: the old key leaked.
    It must go today.

    1. Make a new key
       in the console.
    2. Put it in the vault.
       $ vault put key
    3. Drop the old tags.
       $ git tag -d v12
       $ git tag -d v13
    4. Remove the old key file.
    $ rm ~/.keys/old
    """

    assert Steps.parse(text) == %{
             why: "the old key leaked.\nIt must go today.",
             steps: [
               %{n: 1, text: "Make a new key\nin the console.", commands: []},
               %{n: 2, text: "Put it in the vault.", commands: ["vault put key"]},
               %{
                 n: 3,
                 text: "Drop the old tags.",
                 commands: ["git tag -d v12", "git tag -d v13"]
               },
               %{n: 4, text: "Remove the old key file.", commands: ["rm ~/.keys/old"]}
             ]
           }
  end

  test "steps are numbered by their order; a lead without Why: is why as it is; none is nil" do
    assert %{why: "Before you start.", steps: [%{n: 1, text: "One"}, %{n: 2, text: "Two"}]} =
             Steps.parse("Before you start.\n\n3. One\n7. Two")

    assert %{why: nil, steps: [%{n: 1}, %{n: 2}]} = Steps.parse("1. One\n2. Two")
  end

  test "text without numbered steps is one step, its commands still commands" do
    assert Steps.parse("Open the account.\nKeep the receipt.") == %{
             why: nil,
             steps: [%{n: 1, text: "Open the account.\nKeep the receipt.", commands: []}]
           }

    assert Steps.parse("Why: tidy up.\n$ make clean") == %{
             why: nil,
             steps: [%{n: 1, text: "Why: tidy up.", commands: ["make clean"]}]
           }

    assert Steps.parse(nil) == %{why: nil, steps: [%{n: 1, text: "", commands: []}]}
  end

  test "the current step: none is the first; it stays within the steps, or one past the last" do
    steps = Steps.parse("1. a\n2. b").steps
    assert Steps.current(nil, steps) == 1
    assert Steps.current(2, steps) == 2
    assert Steps.current(0, steps) == 1
    assert Steps.current(9, steps) == 3
  end
end

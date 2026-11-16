defmodule RelaDSL.RunIdentityTest do
  use ExUnit.Case, async: true
  alias RelaDSL.RunIdentity

  @a String.duplicate("a", 64)
  @b String.duplicate("b", 64)
  @c String.duplicate("c", 64)
  @d String.duplicate("d", 64)

  defp current(prod, test \\ nil),
    do: %{prod: %{run: prod}, test: %{run: test || prod}}

  defp m(opts),
    do: %{subflow: :run, opts: Keyword.put_new(opts, :reason, "why"), file: "x.ex", line: 1}

  @now %{digest: @c, states: ["done", "open"]}

  test "the history is every digest from which migrations lead to the current one, with its states" do
    migrations = [
      m(from: @b, to: @c, states: :same),
      m(from: @a, to: @b, states: [start: :open, done: :done]),
      m(from: @d, to: @a, states: [start: :start, done: :done], rekey: true)
    ]

    assert RunIdentity.problems(current(@now), migrations) == []

    assert RunIdentity.history(current(@now), migrations)[{:run, :prod}] == [
             %{digest: @a, states: ["done", "start"]},
             %{digest: @b, states: ["done", "open"]},
             %{digest: @c, states: ["done", "open"]},
             %{digest: @d, states: ["done", "start"]}
           ]
  end

  test "on the model alone: to leads to a current digest, states map known states, rekey keeps them" do
    problems = fn migrations ->
      for {_, p} <- RunIdentity.problems(current(@now), migrations), do: RelaDSL.Problem.key(p)
    end

    assert problems.([m(from: @a, to: @b, states: :same)]) == [{:not_current, ["run"]}]

    assert problems.([m(from: @a, to: @c, states: [open: :gone, done: :done])]) ==
             [{:states_to, ["run"]}]

    assert problems.([m(from: @a, to: @c, states: [open: :done, done: :done], rekey: true)]) ==
             [{:rekey, ["run"]}]

    assert problems.([m(from: @a, to: @c, states: :same, reason: " ")]) == [{:reason, ["run"]}]

    # One digest has one set of states, whichever migration names it.
    assert problems.([
             m(from: @a, to: @c, states: [open: :open]),
             m(from: @a, to: @c, states: [open: :open, done: :done])
           ]) == [{:states_from, ["run"]}]
  end

  test "against the base: nothing removed, a changed digest is migrated, and from is the base's" do
    base = fn digest, history ->
      %{
        "subflows" => %{
          "run" => %{
            "prod" => %{"digest" => digest, "states" => ["done", "open"], "history" => history}
          }
        }
      }
    end

    entry = &%{"digest" => &1, "states" => ["done", "open"]}
    migrations = [m(from: @b, to: @c, states: :same)]
    now = RunIdentity.document(%{prod: %{run: @now}}, migrations)

    assert RunIdentity.base_problems(base.(@b, [entry.(@b)]), now, migrations) == []

    # 1: an entry of the base's history is gone.
    assert [msg] = RunIdentity.base_problems(base.(@b, [entry.(@b), entry.(@d)]), now, migrations)
    assert msg =~ "history entry dddddddd… was removed or changed"

    # 2: the digest changed without a migration from the base's.
    now_unmigrated = RunIdentity.document(%{prod: %{run: @now}}, [])
    # (without the migration, the base's digest also leaves the history)
    assert [removed, msg] = RunIdentity.base_problems(base.(@b, [entry.(@b)]), now_unmigrated, [])
    assert removed =~ "history entry bbbbbbbb… was removed"
    assert msg =~ "without a migrate from"

    # 3: a migration approves its own from, which the base never recorded.
    assert [_removed, _unmigrated, msg] =
             RunIdentity.base_problems(base.(@a, [entry.(@a)]), now, migrations)

    assert msg =~ "from is not in the base's history"

    # 4: it maps states the base did not record for from.
    renamed = [m(from: @b, to: @c, states: [opened: :open, done: :done])]

    # (the base's entry for from is then changed, too)
    assert [_changed, msg] =
             RunIdentity.base_problems(
               base.(@b, [entry.(@b)]),
               RunIdentity.document(%{prod: %{run: @now}}, renamed),
               renamed
             )

    assert msg =~ "states maps states the base did not record"
  end
end

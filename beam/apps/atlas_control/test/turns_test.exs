defmodule AtlasControl.TurnsTest do
  use ExUnit.Case, async: true
  alias AtlasControl.Turns

  defp data do
    n = %{
      "kind" => "run",
      "by" => "worker",
      "on" => "work",
      "state" => "status",
      "running" => "going",
      "outcome" => "result"
    }

    description = %{
      "runtime" => %{"turn" => n},
      "relations" => %{
        "work" => %{"to" => ["card"]},
        "card" => %{"component" => %{}, "from" => ["box"], "to" => ["card"]}
      },
      "flows" => %{"pack" => %{"on" => "card", "owner_relation" => "holder"}}
    }

    turn = %{
      "key" => "R-1",
      "values" => %{"status" => "going"},
      "links" => %{"worker" => ["ada"], "work" => ["C-1"]}
    }

    item = %{"key" => "C-1", "links" => %{"holder" => ["ada"]}}
    {description, turn, item}
  end

  defp read(turn, item) do
    fn
      "run", %{"linked" => %{"worker" => "ada"}} -> %{"facts" => [turn]}
      "run", _ -> %{"facts" => []}
      "card", _ -> %{"fact" => item}
      "box", _ -> %{"facts" => [%{"key" => "B-1"}]}
    end
  end

  test "the agent gets the original fact behind its component" do
    {d, turn, item} = data()
    assert {:ok, %{"key" => "R-1", "on" => "B-1"}} = Turns.current(d, "ada", read(turn, item))
    assert {:error, _} = Turns.current(d, "bob", read(turn, item))

    assert {:error, _} =
             Turns.current(d, "ada", read(turn, put_in(item, ["links", "holder"], ["bob"])))
  end

  test "the turn says what its worker reads first, when the description asks for it" do
    {d, turn, item} = data()

    d =
      d
      |> Map.put("read_first", %{"title" => "First:", "through" => "rests_on", "text" => "rule"})
      |> put_in(["relations", "rests_on"], %{"from" => ["box"], "to" => ["memo"]})

    read = fn
      "box", %{"key" => "B-1"} ->
        %{"fact" => %{"key" => "B-1", "links" => %{"rests_on" => ["M-1"]}}}

      "memo", %{"key" => "M-1"} ->
        %{"fact" => %{"key" => "M-1", "values" => %{"rule" => "Ship safely."}}}

      kind, content ->
        read(turn, item).(kind, content)
    end

    assert {:ok, %{"on" => "B-1", "read_first" => "First:\nRests_on:\n- M-1: Ship safely."}} =
             Turns.current(d, "ada", read)

    refute Map.has_key?(
             elem(Turns.current(data() |> elem(0), "ada", read(turn, item)), 1),
             "read_first"
           )
  end

  test "the outcome is an owner fact, never a lifecycle write" do
    {d, turn, item} = data()
    message = %{"key" => "R-1", "outcome" => "packed two boxes"}
    assert {:ok, "run", fact} = Turns.outcome(d, "ada", message, read(turn, item))
    assert fact["values"] == %{"result" => "packed two boxes"}
    assert fact["was"] == %{"result" => nil}
    assert {:error, _} = Turns.outcome(d, "ada", %{message | "outcome" => "  "}, read(turn, item))

    assert {:error, _} =
             Turns.outcome(d, "ada", %{message | "key" => "R-other"}, read(turn, item))

    assert {:error, _} =
             Turns.outcome(
               d,
               "ada",
               message,
               read(put_in(turn, ["values", "status"], "over"), item)
             )

    assert {:error, _} =
             Turns.outcome(
               d,
               "ada",
               message,
               read(put_in(turn, ["values", "result"], "different"), item)
             )
  end

  test "after a human hands the item on, the old agent has no turn and cannot end it" do
    {d, turn, item} = data()
    item = put_in(item, ["links", "holder"], ["melle"])
    ended = put_in(turn, ["values", "status"], "over")
    message = %{"key" => "R-1", "outcome" => "too late"}

    # Before Runtime ends the turn, and after: no current turn, and its outcome is refused.
    for t <- [turn, ended] do
      assert {:error, _} = Turns.current(d, "ada", read(t, item))
      assert {:error, _} = Turns.outcome(d, "ada", message, read(t, item))
    end
  end
end

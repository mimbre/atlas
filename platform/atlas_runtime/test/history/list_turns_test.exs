Code.require_file("fixtures.exs", __DIR__)

defmodule AtlasRuntime.History.ListTurnsTest do
  # Reads of saved turns and work records through the history facade (§13.1 Q1, Q2).
  use ExUnit.Case, async: false

  alias AtlasRuntime.Boundary.History, as: Facade
  alias AtlasRuntimeBoundary.Generator.InvalidInput
  import AtlasRuntime.HistoryFixtures

  @reader {"local:reader", [:read]}
  @all {"local:admin", [:read, :read_all]}

  setup do
    %{home: home!()}
  end

  defp contract_fields(model) do
    AtlasRuntimeBoundary.History.__schema__().models
    |> Enum.find(&(&1.name == model))
    |> Map.fetch!(:fields)
  end

  defp list!(client, input \\ %{}) do
    assert %Facade.Outcome.Turns{} = page = Facade.list_turns(client, input)
    page
  end

  defp ids(page), do: Enum.map(page.turns, & &1.turn_id)

  # Every page from the first, following the cursor until `more` is false.
  defp all_pages(client, input, cursor \\ nil, pages \\ []) do
    input = if cursor, do: Map.put(input, :cursor, cursor), else: input
    page = list!(client, input)
    pages = pages ++ [page]
    if page.more, do: all_pages(client, input, page.cursor, pages), else: pages
  end

  describe "visibility (Q2)" do
    test "a turn of no work is seen only with read_all", %{home: home} do
      turn!(home, id(1))

      assert ids(list!(@all)) == [id(1)]
      assert list!(@reader).turns == []

      assert %Facade.Outcome.NotFound{} = Facade.get_turn(@reader, %{turn_id: id(1)})

      assert %Facade.Outcome.Found{turn: %Facade.Turn{turn_id: turn}} =
               Facade.get_turn(@all, %{turn_id: id(1)})

      assert turn == id(1)
    end

    test "two clients each see only their own works' turns; read_all sees both", %{home: home} do
      for n <- 1..3, do: turn!(home, id(n), %{"started_at" => "2026-11-16T10:0#{n}:00Z"})
      work!(home, "work-a", "local:a", [{id(1), %{}}])
      work!(home, "work-b", "local:b", [{id(2), %{}}, {id(3), %{}}])
      a = {"local:a", [:read]}
      b = {"local:b", [:read]}

      assert ids(list!(a)) == [id(1)]
      assert ids(list!(b)) == [id(2), id(3)]
      assert ids(list!({"local:a", [:read, :read_all]})) == [id(1), id(2), id(3)]

      assert %Facade.Outcome.NotFound{} = Facade.get_turn(a, %{turn_id: id(2)})
      assert %Facade.Outcome.Found{} = Facade.get_turn(b, %{turn_id: id(2)})
    end

    test "no such turn and a malformed id are not_found", %{home: home} do
      turn!(home, id(1))
      assert %Facade.Outcome.NotFound{} = Facade.get_turn(@all, %{turn_id: id(2)})
      assert %Facade.Outcome.NotFound{} = Facade.get_turn(@all, %{turn_id: "../turns"})
    end

    test "without read, the facade refuses before reading", %{home: home} do
      turn!(home, id(1))

      assert %AtlasRuntimeBoundary.Generator.NotPermitted{capability: :list_turns, right: :read} =
               Facade.list_turns({"local:x", [:read_all]}, %{})
    end
  end

  describe "pages" do
    test "limit 2 over five turns gives each turn once, in (started_at, turn_id) order", %{
      home: home
    } do
      # Two share a start, one has none: the order is still total.
      turn!(home, id(5), %{"started_at" => "2026-11-16T10:00:00Z"})
      turn!(home, id(4), %{"started_at" => "2026-11-16T10:00:00Z"})
      turn!(home, id(3), %{"started_at" => "2026-11-16T09:00:00.5Z"})
      turn!(home, id(2), %{"started_at" => "2026-11-16T11:00:00Z"})
      turn!(home, id(1), :none)

      pages = all_pages(@all, %{limit: 2})

      assert Enum.map(pages, &ids/1) == [[id(1), id(3)], [id(4), id(5)], [id(2)]]
      assert Enum.map(pages, & &1.more) == [true, true, false]

      # The last page's cursor yields what started later, and only that.
      turn!(home, id(6), %{"started_at" => "2026-11-16T12:00:00Z"})
      next = list!(@all, %{limit: 2, cursor: List.last(pages).cursor})
      assert {ids(next), next.more} == {[id(6)], false}
    end

    test "a page never exceeds 100 turns; an empty home gives an empty last page", %{
      home: home
    } do
      empty = list!(@all, %{limit: 5})
      assert {empty.turns, empty.more} == {[], false}
      assert list!(@all, %{cursor: empty.cursor}).turns == []

      for n <- 1..101, do: turn!(home, id(n))
      page = list!(@all, %{limit: 100})
      assert {length(page.turns), page.more} == {100, true}
      # Without a limit, a page is 100 turns (§13.1 Q1).
      default = list!(@all, %{})
      assert {length(default.turns), default.more} == {100, true}
      assert default.turns == page.turns
      assert ids(list!(@all, %{cursor: default.cursor})) == [id(101)]
    end

    test "slot and since filter before paging", %{home: home} do
      turn!(home, id(1), %{"worker_id" => "alpha", "started_at" => "2026-11-16T09:00:00Z"})
      turn!(home, id(2), %{"worker_id" => "beta", "started_at" => "2026-11-16T10:00:00Z"})
      turn!(home, id(3), %{"worker_id" => "alpha", "started_at" => "2026-11-16T10:00:00Z"})
      turn!(home, id(4), :none)

      assert ids(list!(@all, %{slot: "alpha"})) == [id(1), id(3)]
      assert ids(list!(@all, %{since: "2026-11-16T10:00:00Z"})) == [id(2), id(3)]
      assert ids(list!(@all, %{slot: "alpha", since: "2026-11-16T10:00:00Z"})) == [id(3)]
    end

    test "a cursor the Runtime did not give is refused; a limit outside 1..100 is invalid",
         %{home: home} do
      turn!(home, id(1))
      assert_raise ArgumentError, ~r/cursor/, fn -> Facade.list_turns(@all, %{cursor: "x"}) end

      for limit <- [0, 101] do
        assert %InvalidInput{capability: :list_turns, reasons: [reason]} =
                 Facade.list_turns(@all, %{limit: limit})

        assert reason =~ "limit must be in 1..100"
      end
    end
  end

  describe "projection" do
    test "provenance comes from the work record, otherwise from the turn record", %{home: home} do
      turn!(home, id(1))
      turn!(home, id(2), %{"worker_id" => "beta", "backend" => "codex", "model" => nil})

      work!(home, "work-a", "local:reader", [
        {id(1),
         %{
           "harness" => "claude-code",
           "configured_model" => "claude-opus-4-5",
           "reported_model" => "claude-opus-4-5-20261101",
           "conversation_id" => "conversation-1"
         }}
      ])

      [from_work, from_turn] = list!(@all).turns

      assert %Facade.Turn{
               turn_id: turn,
               slot: "alpha",
               state: :finished,
               native_outcome: :finished,
               harness: "claude-code",
               configured_model: "claude-opus-4-5",
               reported_model: "claude-opus-4-5-20261101",
               conversation_id: "conversation-1"
             } = from_work

      assert turn == id(1)
      assert from_work.started_at == ~U[2026-11-16 10:00:00.000000Z]
      assert from_work.ended_at == ~U[2026-11-16 10:05:00.000000Z]

      assert %Facade.Turn{
               slot: "beta",
               harness: "codex",
               configured_model: "claude-opus-4-1",
               reported_model: nil,
               conversation_id: conversation
             } = from_turn

      assert conversation == "session-" <> id(2)
    end

    test "a historic review-packet turn is still listed, projected like any saved turn",
         %{home: home} do
      # Saved before the profile was removed (S5b B2e): its permissions are never projected,
      # so it reads exactly as a materialized-folder turn does, and its record stays as is.
      scope = fn profile ->
        %{
          "sandbox" => nil,
          "session_id" => "session-historic",
          "cwd" => "/private/packet/tree",
          "permissions" => %{"profile" => profile, "root" => "/private/packet/tree"}
        }
      end

      turn!(home, id(1), scope.("review-packet"))
      turn!(home, id(2), scope.("materialized-folder"))
      before = files(home)

      assert [review, folder] = list!(@all).turns
      assert review.turn_id == id(1)
      assert %{Facade.Turn.dump(review) | "turn_id" => id(2)} == Facade.Turn.dump(folder)

      assert %Facade.Outcome.Found{turn: ^review} = Facade.get_turn(@all, %{turn_id: id(1)})
      assert files(home) == before
    end

    # The reader inventory (plan §2 HR): each field a reader takes today is a built turn
    # field, or one the built contract drops: RQ1's, and the pending question, which the
    # watcher finds from the journal (C1; RQ7).
    @inventory %{
      "turn_id" => :turn_id,
      "id" => :turn_id,
      "worker_id" => :slot,
      "state" => :state,
      "backend" => :harness,
      "requested_model" => :configured_model,
      "model" => :reported_model,
      "started_at" => :started_at,
      "ended_at" => :ended_at
    }
    @dropped ~w(recorded_state source_turn_id result error pending_question)

    test "parity: every reader field is a projected turn field or a built drop", %{home: home} do
      readers = %{
        learn:
          ~w(turn_id worker_id state recorded_state backend model requested_model source_turn_id
             started_at ended_at result error),
        cli: ~w(turn_id worker_id state backend model started_at ended_at),
        watcher: ~w(worker_id id state pending_question)
      }

      turn!(home, id(1), %{
        "recorded_state" => "running",
        "source_turn_id" => id(9),
        "error" => "x"
      })

      [turn] = list!(@all).turns
      dumped = Facade.Turn.dump(turn)
      declared = Enum.map(contract_fields(:turn), &Atom.to_string(&1.name))

      assert Enum.sort(Map.keys(dumped) -- declared) == []

      for {reader, fields} <- readers, field <- fields, field not in @dropped do
        assert target = @inventory[field], "#{reader}.#{field} has no history field"

        assert Map.get(turn, target) != nil,
               "#{reader}.#{field} (as #{target}) is not projected"
      end
    end

    test "every turn state is produced from a record, and none outside the enum", %{home: home} do
      saved = %{
        1 => {%{"state" => "finished"}, :finished},
        2 => {%{"state" => "failed", "recorded_state" => "running"}, :failed},
        3 => {%{"state" => "stopped"}, :stopped},
        4 => {%{"state" => "killed"}, :killed},
        # A Service that is gone owns nothing: its unfinished turns are unknown.
        5 => {%{"state" => "running"}, :unknown},
        6 => {%{"state" => "stopping"}, :unknown},
        7 => {:none, :unknown},
        8 => {%{"state" => "idle"}, :unknown}
      }

      for {n, {fields, _}} <- saved, do: turn!(home, id(n), fields)

      # The running Service's own turns carry their live state.
      live =
        for {state, n} <- [{"running", 11}, {"stopping", 12}, {"killing", 13}] do
          %{"id" => id(n), "worker_id" => "w#{n}", "state" => state, "backend" => "claude"}
        end

      expected =
        Map.new(saved, fn {n, {_, state}} -> {id(n), state} end)
        |> Map.merge(%{id(11) => :running, id(12) => :stopping, id(13) => :killing})

      {:ok, _} =
        start_supervised(%{
          id: :service,
          start:
            {GenServer, :start_link,
             [
               __MODULE__.Service,
               live ++ AtlasRuntime.Persistence.History.list(home, %{}).turns,
               [name: AtlasRuntime.Service]
             ]}
        })

      turns = Map.new(list!(@all, %{limit: 100}).turns, &{&1.turn_id, &1})
      assert Map.new(turns, fn {id, t} -> {id, t.state} end) == expected

      {:enum, states} = Enum.find(contract_fields(:turn), &(&1.name == :state)).type
      assert Enum.sort(Enum.uniq(Map.values(expected))) == Enum.sort(states)

      for {_id, turn} <- turns do
        terminal = turn.state in [:finished, :failed, :stopped, :killed]
        assert turn.native_outcome == if(terminal, do: turn.state)
      end
    end

    test "a work record that cannot be read hides only its own turns, and widens nothing",
         %{home: home} do
      turn!(home, id(1))
      turn!(home, id(2))
      turn!(home, id(3))
      work!(home, "work-a", "local:reader", [{id(1), %{"harness" => "claude-code"}}])
      work!(home, "work-b", "local:reader", [{id(2), %{"harness" => "claude-code"}}])
      work!(home, "work-c", "local:other", [{id(3), %{}}])
      # work-b is of a newer format, work-c damaged: neither is read.
      path = Path.join([home, "work", "work-b.json"])

      File.write!(
        path,
        path |> File.read!() |> String.replace(~s("format_version":1), ~s("format_version":2))
      )

      File.write!(Path.join([home, "work", "work-c.json"]), "{\"format_ver")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          # The readable work's client still reads its turn; the unreadable work's turn is
          # not shown to that client, nor to any other without read_all.
          assert ids(list!(@reader)) == [id(1)]
          assert %Facade.Outcome.Found{} = Facade.get_turn(@reader, %{turn_id: id(1)})
          assert %Facade.Outcome.NotFound{} = Facade.get_turn(@reader, %{turn_id: id(2)})
          assert ids(list!({"local:other", [:read]})) == []

          # read_all sees every turn, as before; the skipped work's turn has the turn
          # record's provenance, the readable one its work's.
          turns = Map.new(list!(@all).turns, &{&1.turn_id, &1})
          assert Map.keys(turns) |> Enum.sort() == [id(1), id(2), id(3)]
          assert turns[id(1)].harness == "claude-code"
          assert turns[id(2)].harness == "claude"
        end)

      assert log =~ "work-b.json"
      assert log =~ "work-c.json"
    end
  end

  test "reads change nothing under the home", %{home: home} do
    turn!(home, id(1))
    turn!(home, id(2), %{"state" => "running"})
    turn!(home, id(3), :none)
    work!(home, "work-a", "local:reader", [{id(1), %{}}])
    File.write!(Path.join([home, "work", "index.json"]), "{\"format_version\":1,\"entries\":[]}")
    before = files(home)

    list!(@all)
    list!(@reader, %{limit: 1})
    Facade.get_turn(@all, %{turn_id: id(2)})
    Facade.get_turn(@reader, %{turn_id: id(3)})
    AtlasRuntime.History.pre_cutover_output(@all, id(3))

    assert files(home) == before
  end

  defmodule Service do
    @moduledoc false
    # Answers `turns` as the Service does: its live runs, string-keyed, with the saved ones.
    use GenServer
    @impl true
    def init(runs), do: {:ok, runs}
    @impl true
    def handle_call(%{"command" => "turns"}, _from, runs),
      do: {:reply, {%{turns: runs}, false}, runs}
  end
end

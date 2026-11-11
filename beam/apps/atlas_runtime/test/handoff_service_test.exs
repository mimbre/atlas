defmodule AtlasRuntime.HandoffServiceTest do
  use ExUnit.Case, async: true

  alias AtlasRuntime.{ExecutionEvents, HandoffRecords, Service}

  @moduletag capture_log: true
  @turn "turn-0000000000000001"
  @other "turn-0000000000000002"
  @sha String.duplicate("a", 40)

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ah-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, service: launch(dir)}
  end

  defp launch(dir) do
    File.rm(Path.join(dir, "runtime.sock"))
    {:ok, pid} = GenServer.start(Service, dir)
    on_exit(fn -> stop(pid) end)
    pid
  end

  defp stop(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end
  end

  defp call(pid, request) do
    {reply, false} = GenServer.call(pid, request, 10_000)
    reply
  end

  defp declaration do
    %{
      "kind" => "completion",
      "repository_url" => "https://github.com/Owner/Repo.git",
      "branch" => "work/task",
      "base_sha" => @sha,
      "head_sha" => String.duplicate("b", 40),
      "result" => "Declared work complete",
      "verification" => ["Not independently verified"],
      "limits" => [],
      "remaining_processes" => []
    }
  end

  defp request(command \\ "submit-handoff", turn \\ @turn) do
    request = %{"command" => command, "worker_id" => "alpha", "turn_id" => turn}
    if command == "submit-handoff", do: Map.put(request, "handoff", declaration()), else: request
  end

  defp save(dir, turn \\ @turn, extra \\ %{}) do
    folder = Path.join([dir, "turns", turn])
    File.mkdir_p!(folder)

    run =
      Map.merge(
        %{
          "id" => turn,
          "worker_id" => "alpha",
          "state" => "finished",
          "backend" => "codex",
          "result" => "Native result is not a handoff",
          "artifacts" => folder
        },
        extra
      )

    File.write!(Path.join(folder, "turn.json"), JSON.encode!(run))
    run
  end

  defp events(pid), do: call(pid, %{"command" => "events"})["events"]

  test "requires exact selectors and rejects unknown fields and targets", %{
    dir: dir,
    service: pid
  } do
    save(dir)

    for command <- ["submit-handoff", "handoff"] do
      base = request(command)

      for field <- ["worker_id", "turn_id"] do
        assert %{command_error: _} = call(pid, Map.delete(base, field))

        for invalid <- [nil, "", "../escape", 7] do
          assert %{command_error: _} = call(pid, Map.put(base, field, invalid))
        end
      end

      assert %{command_error: _} = call(pid, Map.put(base, "unknown", true))
      assert %{command_error: _} = call(pid, Map.put(base, "worker_id", "beta"))
      assert %{command_error: _} = call(pid, Map.put(base, "turn_id", @other))
    end

    assert %{command_error: _} = call(pid, Map.put(request("handoff"), "handoff", declaration()))
    assert %{command_error: _} = call(pid, Map.delete(request(), "handoff"))

    for payload <- [nil, %{}, Map.put(declaration(), "trusted", true)] do
      assert %{command_error: _} = call(pid, Map.put(request(), "handoff", payload))
    end

    assert events(pid) == []
    refute File.exists?(Path.join([dir, "turns", @turn, "handoff.json"]))
  end

  test "first submission binds saved identity and managed repository fields", %{
    dir: dir,
    service: pid
  } do
    save(dir, @turn, %{
      "repository" => %{
        "url" => "https://github.com/owner/repo",
        "branch" => "work/task",
        "base_sha" => @sha
      }
    })

    for {field, value} <- [
          {"repository_url", "https://github.com/other/repo"},
          {"branch", "other"},
          {"base_sha", String.duplicate("c", 40)}
        ] do
      bad = put_in(request(), ["handoff", field], value)
      assert %{command_error: _} = call(pid, bad)
    end

    assert events(pid) == []
    assert %{"worker_id" => "alpha", "turn_id" => @turn} = call(pid, request())

    for invalid <- [%{"id" => @turn}, %{"worker_id" => nil}] do
      save(dir, @other, invalid)
      assert %{command_error: _} = call(pid, request("submit-handoff", @other))
    end
  end

  test "declaration neither accepts nor changes any execution state", %{dir: dir, service: pid} do
    for {status, number} <-
          Enum.with_index(["running", "finished", "failed", "stopped", "unknown"], 1) do
      turn = "turn-" <> String.pad_leading(Integer.to_string(number, 16), 16, "0")
      saved = save(dir, turn, %{"state" => status})
      path = Path.join([dir, "turns", turn, "turn.json"])
      before = File.read!(path)

      worker = %{
        agent: self(),
        monitor: make_ref(),
        run: %{id: turn, worker_id: "alpha", state: status}
      }

      :sys.replace_state(pid, fn state -> %{state | workers: %{"alpha" => worker}} end)
      assert %{command_error: _} = call(pid, request("handoff", turn))

      assert %{"handoff" => payload, "provenance" => "coordinator_submitted_declaration"} =
               call(pid, request("submit-handoff", turn))

      assert payload == declaration()
      assert :sys.get_state(pid).workers == %{"alpha" => worker}
      assert File.read!(path) == before
      assert JSON.decode!(before) == saved
    end

    assert Enum.all?(events(pid), &(&1["kind"] == "handoff_submitted"))
    assert length(events(pid)) == 5
    refute_received {:"$gen_call", _, _}
  end

  test "concurrent retries serialize one record and reject conflicting declarations", %{
    dir: dir,
    service: pid
  } do
    save(dir)

    records =
      1..12
      |> Enum.map(fn _ -> Task.async(fn -> call(pid, request()) end) end)
      |> Task.await_many()

    assert [record] = Enum.uniq(records)
    assert record["handoff"] == declaration()
    assert [event] = events(pid)

    assert event == %{
             "sequence" => 1,
             "kind" => "handoff_submitted",
             "worker_id" => "alpha",
             "turn_id" => @turn,
             "record_ref" => "turns/#{@turn}/handoff.json",
             "timestamp" => record["submitted_at"]
           }

    save(dir, @other)

    replies =
      1..12
      |> Enum.map(fn number ->
        Task.async(fn ->
          call(
            pid,
            put_in(request("submit-handoff", @other), ["handoff", "result"], "result #{number}")
          )
        end)
      end)
      |> Task.await_many()

    assert Enum.count(replies, &Map.has_key?(&1, "handoff")) == 1
    assert Enum.count(replies, &Map.has_key?(&1, :command_error)) == 11
    assert length(events(pid)) == 2
  end

  test "restart and changed snapshots cannot reattribute or revalidate a saved declaration", %{
    dir: dir,
    service: pid
  } do
    save(dir)
    record = call(pid, request())
    journal = events(pid)

    save(dir, @turn, %{
      "worker_id" => "beta",
      "repository" => %{"url" => "https://github.com/other/repo"}
    })

    stop(pid)
    restarted = launch(dir)
    assert call(restarted, request("handoff")) == record
    assert call(restarted, request()) == record
    assert %{command_error: _} = call(restarted, Map.put(request(), "worker_id", "beta"))
    assert %{command_error: _} = call(restarted, Map.put(request("handoff"), "worker_id", "beta"))
    File.rm!(Path.join([dir, "turns", @turn, "turn.json"]))
    assert call(restarted, request()) == record
    assert events(restarted) == journal
    assert :sys.get_state(restarted).workers == %{}
  end

  test "PR handoffs remain explicit declarations without GitHub or native execution", %{
    dir: dir,
    service: pid
  } do
    save(dir)

    pr =
      declaration()
      |> Map.put("kind", "pull_request")
      |> Map.put("pr_url", "https://github.com/owner/repo/pull/999999999")

    assert %{command_error: _} =
             call(pid, Map.put(request(), "handoff", Map.delete(pr, "pr_url")))

    assert %{command_error: _} =
             call(pid, Map.put(request(), "handoff", Map.put(pr, "kind", "completion")))

    assert %{"handoff" => ^pr, "provenance" => "coordinator_submitted_declaration"} =
             call(pid, Map.put(request(), "handoff", pr))

    assert :sys.get_state(pid).workers == %{}
    assert [%{"kind" => "handoff_submitted"}] = events(pid)
  end

  test "init recovers both publication crash windows without duplicate events", %{
    dir: dir,
    service: pid
  } do
    save(dir)
    journal_path = Path.join(dir, "execution-events.json")
    empty_journal = File.read!(journal_path)
    record = call(pid, request())
    record_path = Path.join(dir, record["record_ref"])
    stop(pid)
    unpublished = record_path |> File.read!() |> JSON.decode!() |> Map.put("published", false)
    File.write!(record_path, JSON.encode!(unpublished))
    File.write!(journal_path, empty_journal)

    recovered = launch(dir)
    assert call(recovered, request("handoff")) == record
    assert [%{"sequence" => 1, "timestamp" => timestamp}] = events(recovered)
    assert timestamp == record["submitted_at"]
    assert JSON.decode!(File.read!(record_path))["published"]
    stop(recovered)
    File.write!(record_path, JSON.encode!(unpublished))

    replayed = launch(dir)
    assert call(replayed, request()) == record
    assert [%{"sequence" => 1}] = events(replayed)
    assert JSON.decode!(File.read!(record_path))["published"]
  end

  test "authoritative record corruption is fatal while ordinary File.Error stays command_error",
       %{dir: dir, service: pid} do
    save(dir)
    state = :sys.get_state(pid)
    path = Path.join([dir, "turns", @turn, "turn.json"])
    File.rm!(path)
    File.mkdir!(path)

    assert {:reply, {%{command_error: _}, false}, ^state} =
             Service.handle_call(request(), {self(), make_ref()}, state)

    File.rmdir!(path)
    save(dir)
    call(pid, request())
    state = :sys.get_state(pid)
    File.write!(Path.join([dir, "turns", @turn, "handoff.json"]), "null")

    assert_raise HandoffRecords.StorageError, fn ->
      Service.handle_call(request("handoff"), {self(), make_ref()}, state)
    end

    assert ExecutionEvents.open(dir) == state.events
  end
end

defmodule AtlasRuntime.GuidanceInboxTest do
  use ExUnit.Case, async: true
  alias AtlasRuntime.Agent, as: Harness
  alias AtlasRuntime.Agent.FakeInbox
  @moduletag :tmp_dir
  @turn %{
    key: "turn-a",
    agent: "worker-a",
    attempt: "attempt-a",
    environment: "private",
    machine: "box"
  }
  @identity %{
    "environment" => "private",
    "worker" => "worker-a",
    "turn" => "turn-a",
    "attempt" => "attempt-a",
    "interaction" => "interaction-a"
  }
  @request Map.merge(@identity, %{
             "body" => "/stop\n/do not interpret `$(anything)` — literal 🦉",
             "mode" => "queued_guidance"
           })

  defmodule Responder do
    def capabilities(pid), do: Agent.get(pid, & &1.capabilities)
    def accept(pid, _), do: Agent.get(pid, & &1.result)
    def query(pid, _), do: Agent.get(pid, & &1.result)
  end

  defmodule CapabilitiesOnly do
    def capabilities(pid), do: Agent.get(pid, & &1.capabilities)
  end

  defp start(dir, opts \\ [], turn \\ @turn) do
    result = FakeInbox.start(turn, [inbox_dir: dir] ++ opts)

    if match?({:ok, _}, result) do
      {:ok, pid} = result
      on_exit(fn -> if Process.alive?(pid), do: FakeInbox.stop(pid) end)
    end

    result
  end

  test "existing adapters default unsupported without starting any process" do
    for adapter <- [Harness.Stub, Harness.Claude] do
      assert Harness.capabilities(adapter, self()) == {:error, :unsupported}
      assert Harness.accept(adapter, self(), @request) == {:error, :unsupported}
      assert Harness.query(adapter, self(), @identity) == {:error, :unsupported}
    end

    assert Harness.port(%{"port" => "private_fake"}) == nil
    assert Harness.port(%{"port" => "stub"}) == Harness.Stub
  end

  test "concurrent duplicate admission has one immutable evidence record", %{tmp_dir: dir} do
    {:ok, pid} = start(dir, initialize: true)
    assert {:not_admitted, @identity} = Harness.query(FakeInbox, pid, @identity)
    results = for _ <- 1..8, do: Task.async(fn -> Harness.accept(FakeInbox, pid, @request) end)
    [first | rest] = Enum.map(results, &Task.await/1)
    assert {:ok, %{"stage" => "admitted", "identity" => @identity}} = first
    assert Enum.all?(rest, &(&1 == first))
    assert Harness.query(FakeInbox, pid, @identity) == first

    for {field, value} <- [
          {"body", "different"},
          {"turn", "turn-b"},
          {"worker", "worker-b"},
          {"attempt", "attempt-b"},
          {"environment", "elsewhere"},
          {"mode", "interrupt"}
        ] do
      assert {:error, _} = Harness.accept(FakeInbox, pid, Map.put(@request, field, value))
    end

    assert Harness.query(FakeInbox, pid, @identity) == first

    assert {:error, :conflict} =
             Harness.query(FakeInbox, pid, %{@identity | "attempt" => "other"})
  end

  test "safe-boundary consumption is durable, correlated and literal", %{tmp_dir: dir} do
    {:ok, pid} = start(dir, initialize: true)
    {:ok, admitted} = Harness.accept(FakeInbox, pid, @request)
    assert {:error, :not_consumed} = FakeInbox.context_input(pid, @identity)
    {:ok, consumed} = FakeInbox.consume(pid, @identity)
    assert consumed["admission_id"] == admitted["admission_id"]
    assert consumed["consumption_id"] != nil
    assert_receive {:agent, ^pid, {:guidance, ^consumed}}
    assert FakeInbox.context_input(pid, @identity) == {:ok, @request["body"]}
    assert {:ok, ^consumed} = FakeInbox.consume(pid, @identity)
    refute_receive {:agent, ^pid, _}
    :ok = FakeInbox.stop(pid)
    {:ok, reopened} = start(dir)
    assert Harness.query(FakeInbox, reopened, @identity) == {:ok, consumed}
    assert Harness.accept(FakeInbox, reopened, @request) == {:ok, consumed}
    assert FakeInbox.context_input(reopened, @identity) == {:ok, @request["body"]}
  end

  test "concurrent conflicting input IDs have one immutable winner", %{tmp_dir: dir} do
    {:ok, pid} = start(dir, initialize: true)

    tasks =
      for n <- 1..8 do
        request = Map.put(@request, "body", if(rem(n, 2) == 0, do: "first", else: "second"))
        Task.async(fn -> Harness.accept(FakeInbox, pid, request) end)
      end

    results = Enum.map(tasks, &Task.await/1)
    assert Enum.count(results, &match?({:error, :conflict}, &1)) == 4
    successful = Enum.filter(results, &match?({:ok, _}, &1))
    assert length(Enum.uniq(successful)) == 1
    assert {:ok, _} = FakeInbox.consume(pid, @identity)
    assert {:ok, body} = FakeInbox.context_input(pid, @identity)
    assert body in ["first", "second"]
  end

  for phase <- [:before_accept, :after_accept, :before_consume, :after_consume] do
    test "crash recovery at #{phase} does not guess or reinject", %{tmp_dir: dir} do
      assert_crash_recovery(dir, unquote(phase))
    end
  end

  # The barrier is sent only after the inbox's disk work (sync, binding checks), which a
  # loaded machine can take far past assert_receive's 100ms. Wait for the event itself, and
  # fail at once if the inbox stops before reaching it.
  defp await_barrier(pid, phase) do
    ref = Process.monitor(pid)

    receive do
      {:inbox_barrier, ^pid, ^phase, "interaction-a"} ->
        Process.demonitor(ref, [:flush])

      {:DOWN, ^ref, :process, ^pid, reason} ->
        flunk("inbox stopped before #{phase}: #{inspect(reason)}")
    end
  end

  defp assert_crash_recovery(dir, phase) do
    {:ok, pid} = start(dir, initialize: true, barrier: {self(), phase})

    if phase in [:before_consume, :after_consume],
      do: assert({:ok, _} = Harness.accept(FakeInbox, pid, @request))

    task =
      Task.async(fn ->
        if phase in [:before_accept, :after_accept],
          do: Harness.accept(FakeInbox, pid, @request),
          else:
            Harness.query(FakeInbox, pid, @identity)
            |> then(fn _ ->
              try do
                FakeInbox.consume(pid, @identity)
              catch
                :exit, _ -> {:error, :uncertain}
              end
            end)
      end)

    await_barrier(pid, phase)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert {:error, :uncertain} = Task.await(task)
    {:ok, reopened} = start(dir)
    answer = Harness.query(FakeInbox, reopened, @identity)

    case phase do
      :before_accept ->
        assert answer == {:not_admitted, @identity}
        assert {:ok, %{"stage" => "admitted"}} = Harness.accept(FakeInbox, reopened, @request)

      :after_accept ->
        assert {:ok, %{"stage" => "admitted"}} = answer
        assert Harness.accept(FakeInbox, reopened, @request) == answer

      :before_consume ->
        assert {:ok, %{"stage" => "admitted"}} = answer
        assert {:ok, %{"stage" => "consumed"}} = FakeInbox.consume(reopened, @identity)

      :after_consume ->
        assert {:ok, %{"stage" => "consumed"}} = answer
        assert FakeInbox.consume(reopened, @identity) == answer
        refute_receive {:agent, ^reopened, _}
    end
  end

  test "closed attempts retain evidence and cannot transfer input to a successor", %{tmp_dir: dir} do
    {:ok, pid} = start(dir, initialize: true)
    {:ok, original} = Harness.accept(FakeInbox, pid, @request)
    :ok = FakeInbox.close_attempt(pid)
    assert {:error, :stale} = Harness.accept(FakeInbox, pid, %{@request | "interaction" => "new"})
    assert {:error, :stale} = FakeInbox.consume(pid, @identity)
    :ok = FakeInbox.stop(pid)
    {:ok, next} = start(dir, [], %{@turn | key: "turn-b", attempt: "attempt-b"})
    assert Harness.query(FakeInbox, next, @identity) == {:ok, original}
    changed = %{@request | "turn" => "turn-b", "attempt" => "attempt-b"}
    assert {:error, :conflict} = Harness.accept(FakeInbox, next, changed)
    assert {:error, :stale} = FakeInbox.accept(next, %{@request | "interaction" => "old-fresh"})
    assert {:ok, _} = Harness.accept(FakeInbox, next, %{changed | "interaction" => "next"})
    :ok = FakeInbox.close_attempt(next)
    :ok = FakeInbox.stop(next)
    assert {:error, :target_conflict} = start(dir)
  end

  test "callback failures, partial capabilities and mismatched evidence cannot claim success", %{
    tmp_dir: dir
  } do
    {:ok, inbox} = start(dir, initialize: true)
    {:ok, descriptor} = FakeInbox.capabilities(inbox)
    {:ok, evidence} = FakeInbox.accept(inbox, @request)

    {:ok, responder} =
      Agent.start_link(fn -> %{capabilities: {:ok, descriptor}, result: {:ok, evidence}} end)

    assert Harness.capabilities(CapabilitiesOnly, responder) == {:error, :unsupported}

    for caps <- [
          Map.put(descriptor, "capability_version", "future"),
          Map.delete(descriptor, "literal_text"),
          Map.put(descriptor, "durable_accept_query", false),
          Map.put(descriptor, "reported_model", %{"private" => "invalid"}),
          Map.put(descriptor, "extra", String.duplicate("x", 8_192))
        ] do
      Agent.update(responder, &%{&1 | capabilities: {:ok, caps}})
      assert Harness.accept(Responder, responder, @request) == {:error, :unsupported}
    end

    Agent.update(responder, &%{&1 | capabilities: {:ok, descriptor}})

    for result <- [
          {:ok, put_in(evidence, ["identity", "attempt"], "other")},
          {:ok, Map.put(evidence, "extra", "untrusted")},
          {:ok, %{evidence | "stage" => "consumed", "consumption_id" => nil}},
          {:not_admitted, Map.put(@identity, "turn", "other")},
          {:error, String.duplicate("x", 50_000)},
          :unknown
        ] do
      Agent.update(responder, &%{&1 | result: result})
      assert Harness.query(Responder, responder, @identity) == {:error, :uncertain}
    end

    Agent.update(responder, &%{&1 | result: {:not_admitted, @identity}})
    assert Harness.query(Responder, responder, @identity) == {:not_admitted, @identity}
    assert Harness.accept(Responder, responder, @request) == {:error, :uncertain}
  end

  test "failed storage and malformed retained records never report not-admitted", %{tmp_dir: dir} do
    {:ok, pid} = start(dir, initialize: true)
    {:ok, _} = Harness.accept(FakeInbox, pid, @request)

    :sys.replace_state(pid, fn state ->
      :ok = :dets.close(state.table)
      state
    end)

    assert Harness.query(FakeInbox, pid, @identity) == {:error, :uncertain}

    assert Harness.query(FakeInbox, pid, %{@identity | "interaction" => "missing"}) ==
             {:error, :uncertain}

    FakeInbox.stop(pid)
    {:ok, reopened} = start(dir)

    :sys.replace_state(reopened, fn state ->
      :ok = :dets.insert(state.table, {{:input, "bad"}, %{request: @request, evidence: %{}}})
      :ok = :dets.sync(state.table)
      state
    end)

    FakeInbox.stop(reopened)
    assert {:error, :uncertain} = start(dir)
  end

  test "missing, damaged and unavailable inboxes never become authoritative absence", %{
    tmp_dir: dir
  } do
    assert {:error, :uncertain} = start(Path.join(dir, "missing"))
    {:ok, pid} = start(dir, initialize: true)
    assert {:ok, _} = Harness.accept(FakeInbox, pid, @request)
    FakeInbox.stop(pid)
    File.rename!(Path.join(dir, "inbox.dets"), Path.join(dir, "preserved.dets"))
    assert {:error, :uncertain} = start(dir)
    assert {:error, :uncertain} = start(dir, initialize: true)
    File.write!(Path.join(dir, "inbox.dets"), "damaged synthetic file")
    assert {:error, :uncertain} = start(dir)
    assert Harness.query(FakeInbox, pid, @identity) == {:error, :uncertain}
  end

  test "one physical inbox owner, including directory aliases", %{tmp_dir: dir} do
    inbox = Path.join(dir, "inbox")
    {:ok, pid} = start(inbox, initialize: true)
    assert {:error, :inbox_in_use} = start(inbox)
    alias_dir = Path.join(dir, "alias")
    File.ln_s!(inbox, alias_dir)
    assert {:error, :inbox_in_use} = start(alias_dir)
    assert {:ok, _} = Harness.accept(FakeInbox, pid, @request)
  end

  for {file, change, first} <- [
        {"inbox.dets", :move, :query},
        {"inbox.dets", :replace, :accept},
        {"identity.json", :move, :consume},
        {"identity.json", :replace, :close}
      ] do
    test "live #{file} #{change} refuses #{first} and latches uncertainty", %{tmp_dir: dir} do
      assert_binding_loss(dir, unquote(file), unquote(change), unquote(first))
    end
  end

  defp assert_binding_loss(dir, file, change, first) do
    {:ok, pid} = start(dir, initialize: true)
    {:ok, original} = FakeInbox.accept(pid, @request)
    table = :sys.get_state(pid).table
    retained = :dets.lookup(table, {:input, @identity["interaction"]})
    archive = move_binding(dir, file, change)
    assert binding_call(first, pid) == {:error, :uncertain}, "synthetic evidence: #{dir}"
    assert_uncertain(pid)
    assert :dets.lookup(table, {:input, @identity["interaction"]}) == retained
    assert :dets.lookup(table, {:input, "unseen"}) == []
    refute_receive {:agent, ^pid, _}
    restore_binding(dir, file, archive)
    assert_uncertain(pid)
    FakeInbox.stop(pid)
    {:ok, reopened} = start(dir)
    assert FakeInbox.query(reopened, @identity) == {:ok, original}
    assert File.exists?(archive)
  end

  defp binding_call(:query, pid),
    do: FakeInbox.query(pid, %{@identity | "interaction" => "unseen"})

  defp binding_call(:accept, pid),
    do: FakeInbox.accept(pid, %{@request | "interaction" => "unseen"})

  defp binding_call(:consume, pid), do: FakeInbox.consume(pid, @identity)
  defp binding_call(:close, pid), do: FakeInbox.close_attempt(pid)

  defp assert_uncertain(pid) do
    for op <- [:query, :accept, :consume, :close] do
      assert binding_call(op, pid) == {:error, :uncertain}
    end

    assert FakeInbox.context_input(pid, @identity) == {:error, :uncertain}
    assert Harness.query(FakeInbox, pid, @identity) == {:error, :uncertain}
  end

  defp move_binding(dir, file, change) do
    path = Path.join(dir, file)
    archive = Path.join(dir, "archived-" <> file)
    File.rename!(path, archive)
    if change == :replace, do: File.cp!(archive, path)
    archive
  end

  defp restore_binding(dir, file, archive) do
    path = Path.join(dir, file)
    if File.exists?(path), do: File.rename!(path, Path.join(dir, "replacement-" <> file))
    # Keep the archive; restore the same physical file to prove the failure latch.
    File.ln!(archive, path)
  end

  test "live marker content change at the same inode latches uncertainty", %{tmp_dir: dir} do
    {:ok, pid} = start(dir, initialize: true)
    marker = Path.join(dir, "identity.json")
    archive = Path.join(dir, "archived-identity.json")
    File.cp!(marker, archive)
    original = File.read!(marker)
    File.write!(marker, JSON.encode!(%{"environment" => "changed", "machine" => "box"}))
    assert FakeInbox.query(pid, @identity) == {:error, :uncertain}, "synthetic evidence: #{dir}"
    File.write!(marker, original)
    assert_uncertain(pid)
    assert File.read!(archive) == original
  end

  for phase <- [:before_accept, :after_accept, :before_consume, :after_consume] do
    test "binding replacement at #{phase} cannot emit success", %{tmp_dir: dir} do
      assert_binding_barrier(dir, unquote(phase))
    end
  end

  defp assert_binding_barrier(dir, phase) do
    {:ok, pid} = start(dir, initialize: true, barrier: {self(), phase})
    if phase in [:before_consume, :after_consume], do: FakeInbox.accept(pid, @request)

    task =
      Task.async(fn ->
        if phase in [:before_accept, :after_accept],
          do: FakeInbox.accept(pid, @request),
          else: FakeInbox.consume(pid, @identity)
      end)

    await_barrier(pid, phase)
    archive = move_binding(dir, "inbox.dets", :replace)
    send(pid, {:release, phase})
    assert Task.await(task) == {:error, :uncertain}, "synthetic evidence: #{dir}"
    refute_receive {:agent, ^pid, _}
    table = :sys.get_state(pid).table
    records = :dets.lookup(table, {:input, @identity["interaction"]})

    case phase do
      :before_accept -> assert records == []
      :after_accept -> assert [{_, %{evidence: %{"stage" => "admitted"}}}] = records
      :before_consume -> assert [{_, %{evidence: %{"stage" => "admitted"}}}] = records
      :after_consume -> assert [{_, %{evidence: %{"stage" => "consumed"}}}] = records
    end

    restore_binding(dir, "inbox.dets", archive)
    assert_uncertain(pid)
    FakeInbox.stop(pid)
    {:ok, reopened} = start(dir)

    case records do
      [] -> assert FakeInbox.query(reopened, @identity) == {:not_admitted, @identity}
      [{_, record}] -> assert FakeInbox.query(reopened, @identity) == {:ok, record.evidence}
    end

    assert File.exists?(archive)
  end

  test "record and response bounds, malformed identities and activity remain explicit", %{
    tmp_dir: dir
  } do
    assert {:error, :invalid_identity} = FakeInbox.start(%{@turn | attempt: ""}, inbox_dir: dir)
    assert {:error, :invalid_identity} = FakeInbox.start(@turn, [:invalid])
    {:ok, pid} = start(dir, initialize: true)

    for request <- [
          %{@request | "body" => String.duplicate("x", 24_576)},
          %{@request | "body" => <<255>>},
          Map.put(@request, "extra", "not allowed"),
          %{@request | "attempt" => ""},
          %{@request | "interaction" => String.duplicate("x", 257)}
        ] do
      assert {:error, _} = Harness.accept(FakeInbox, pid, request)
    end

    assert {:not_admitted, @identity} = Harness.query(FakeInbox, pid, @identity)
    assert {:ok, evidence} = Harness.accept(FakeInbox, pid, @request)
    assert byte_size(JSON.encode!(evidence)) <= 8_192
    assert {:ok, %{"reported_model" => nil} = descriptor} = Harness.capabilities(FakeInbox, pid)
    assert byte_size(JSON.encode!(descriptor)) <= 8_192

    base = Map.merge(@request, %{"body" => "", "interaction" => "interaction-b"})
    bounded = Map.put(base, "body", String.duplicate("z", 24_576 - byte_size(JSON.encode!(base))))
    assert byte_size(JSON.encode!(bounded)) == 24_576
    assert {:ok, _} = Harness.accept(FakeInbox, pid, bounded)
    assert {:ok, _} = FakeInbox.consume(pid, Map.drop(bounded, ["body", "mode"]))
    table = :sys.get_state(pid).table
    [{_, record}] = :dets.lookup(table, {:input, "interaction-b"})
    assert byte_size(JSON.encode!(record)) <= 32_768
    assert {:ok, %{"summary" => "safe 🦉"}} = Harness.activity("status", "safe 🦉")
    assert {:error, :invalid_activity} = Harness.activity("consumed", "not proof")
    assert {:error, :invalid_activity} = Harness.activity("tool", String.duplicate("x", 1_025))
  end

  test "expired typed deadline is explicit stale, with no durable admission", %{tmp_dir: dir} do
    {:ok, pid} = start(dir, initialize: true)

    assert {:error, :stale} =
             Harness.accept(FakeInbox, pid, @request, System.system_time(:millisecond) - 1)

    assert {:not_admitted, @identity} = Harness.query(FakeInbox, pid, @identity)
  end

  test "historical recovery cannot activate or close a different current attempt", %{tmp_dir: dir} do
    {:ok, pid} = start(dir, initialize: true)
    {:ok, original} = Harness.accept(FakeInbox, pid, @request)
    :ok = FakeInbox.close_attempt(pid)
    :ok = FakeInbox.stop(pid)
    successor = %{@turn | key: "turn-b", attempt: "attempt-b"}
    {:ok, next} = start(dir, [], successor)
    :ok = FakeInbox.stop(next)
    {:ok, history} = FakeInbox.recover_input(@turn, inbox_dir: dir)
    assert {:ok, ^original} = Harness.query(FakeInbox, history, @identity)
    assert {:error, :stale} = FakeInbox.consume(history, @identity)
    new_request = %{@request | "interaction" => "interaction-new"}
    assert {:error, :stale} = Harness.accept(FakeInbox, history, new_request)
    :ok = FakeInbox.stop(history)
    {:ok, current} = start(dir, [], successor)
    request = %{@request | "turn" => "turn-b", "attempt" => "attempt-b", "interaction" => "new"}
    assert {:ok, _} = Harness.accept(FakeInbox, current, request)
  end
end

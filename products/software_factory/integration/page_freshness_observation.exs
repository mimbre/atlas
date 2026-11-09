# Focused observation regression: real Facts, Flow, Control and assigned-row logic;
# existing neutral Workshop concepts and in-memory Rela storage. No native launcher.
# From products/software_factory/: MIX_ENV=test mix run integration/page_freshness_observation.exs
Code.require_file(Path.expand("../e2e/test/page_freshness/sessions.exs", __DIR__))
ExUnit.start(seed: 0)

defmodule LateFrameModel do
  use RelaDSL.Composition, name: "late-frame-workshop", subflow_behaviour: AtlasFlow.Subflow
  @behaviour AtlasFlow.Model
  schema(version: "1.0", namespace: "https://example.invalid/late-frame#")
  modules([AtlasFlow.Workshop.Module])
  environments([:prod, :test])

  defcomposition :late_frame_workshop do
    subflows([AtlasFlow.Workshop.Things])
  end

  start_page(assigned: [relation: :tended_by, title: "Assigned", count: "{count} assigned"])
end

defmodule LateFrameDiagnosis do
  use ExUnit.Case, async: false
  alias AtlasFacts.FakeRela
  alias AtlasFlow.{Engine, ManualClock, Talk}
  alias PageFreshness.Sessions
  @model LateFrameModel

  defp put(socket, message), do: :gen_tcp.send(socket, [JSON.encode!(message), "\n"])

  # Retain every wire message, even when awaiting a particular protocol event.
  defp until_message(socket, predicate) do
    {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)
    message = JSON.decode!(line)
    Process.put(:wire, Process.get(:wire, []) ++ [message])
    if predicate.(message), do: message, else: until_message(socket, predicate)
  end

  defp page(socket, predicate),
    do: until_message(socket, &(&1["op"] == "page" and predicate.(&1)))

  defp sync(socket) do
    :ok = put(socket, %{"op" => "diagnosis_barrier"})
    until_message(socket, &(&1["text"] == "Unknown op \"diagnosis_barrier\""))
  end

  test "collector backlog preserves pending frames before coverage and every covered frame after it" do
    Application.put_env(:atlas_bus, :store, "late-frame-diagnosis")
    rela = FakeRela.start(@model)
    on_exit(fn -> if Process.alive?(rela), do: Agent.stop(rela) end)

    facts =
      start_supervised!(
        {AtlasFacts.Server,
         rela: {FakeRela, rela},
         model: @model,
         data_dir:
           Path.join(
             System.fetch_env!("TMPDIR"),
             "frame-observation-#{Base.encode16(:crypto.strong_rand_bytes(8))}"
           )}
      )

    :ok = AtlasBus.attach("control/session-late-frame-fixture")

    assert {:stored, _} =
             Talk.put("maker", %{"op" => "create", "key" => "mia", "values" => %{"name" => "Mia"}})

    for n <- 1..3 do
      assert {:stored, _} =
               Talk.put("widget", %{
                 "op" => "create",
                 "key" => "W-#{n}",
                 "values" => %{"title" => "Widget #{n}"}
               })
    end

    clock = start_supervised!({ManualClock, ~U[2026-11-14 00:00:00Z]})

    engine =
      start_supervised!({Engine, every: 3_600_000, clock: {ManualClock, clock}, model: @model})

    :ok = Engine.round(engine)
    assert :sys.get_state(engine).refusal == nil
    start_supervised!({AtlasControl.Gateway, port: 0, name: :diagnosis_gateway, model: @model})

    on_exit(fn ->
      AtlasControl.Clock.release()

      for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasControl.Sessions),
          do: DynamicSupervisor.terminate_child(AtlasControl.Sessions, pid)
    end)

    AtlasControl.Clock.hold(self())

    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", AtlasControl.Gateway.port(:diagnosis_gateway), [
        :binary,
        packet: :line,
        active: false
      ])

    on_exit(fn -> :gen_tcp.close(socket) end)

    :ok =
      put(socket, %{
        "op" => "hello",
        "env" => "test",
        "client" => "diagnosis",
        "as" => "mia",
        "spec" => AtlasControl.Blocks.version()
      })

    initial = page(socket, &(&1["path"] == "/"))
    before = Enum.map(Sessions.rows(initial), & &1.key)
    assert Enum.sort(before) == ~w(W-1 W-2 W-3)
    [{_, session, _, _}] = DynamicSupervisor.which_children(AtlasControl.Sessions)
    tracer = Sessions.watch([session])
    boundary = Sessions.cursor(tracer, session)
    true = :erlang.suspend_process(tracer)

    on_exit(fn ->
      if Process.alive?(tracer), do: Process.exit(tracer, :kill)
      :erlang.trace_pattern({:gen_tcp, :send, 2}, false, [:global])
      :erlang.trace_pattern({AtlasControl.Session, :handle_info, 2}, false, [:global])
    end)

    :ok = :sys.suspend(engine)
    :ok = put(socket, %{"op" => "open", "to" => "/k/widget/W-2/edit"})
    page(socket, &(&1["path"] == "/k/widget/W-2/edit"))

    :ok =
      put(socket, %{
        "op" => "submit",
        "to" => "/k/widget/W-2/edit",
        "values" => %{"state" => "done"}
      })

    assert_receive {:clock, ^session, {:settle_timeout, _}, 1_000}, 5_000
    position = :sys.get_state(session).settling.position
    pending = page(socket, &(&1["path"] == "/" and &1["reason"] == "pending"))
    assert Enum.map(Sessions.rows(pending), & &1.key) == before
    assert Enum.any?(Sessions.rows(pending), &(&1.key == "W-2" and &1.pending))
    :ok = put(socket, %{"op" => "open", "to" => "/"})
    opened = page(socket, &(&1["path"] == "/" and &1["reason"] == "open"))
    assert Enum.map(Sessions.rows(opened), & &1.key) == before
    assert Enum.any?(Sessions.rows(opened), &(&1.key == "W-2" and &1.pending))
    sync(socket)
    pre_count = length(Process.get(:wire))
    assert (:sys.get_state(session).settled || -1) < position
    # No frame can be processed by the collector until after covering settlement.
    :ok = :sys.resume(engine)
    cleared = page(socket, &(&1["path"] == "/" and &1["reason"] == "hint"))
    state = :sys.get_state(session)
    assert state.settled >= position
    assert Sessions.unmarked?(session)
    sync(socket)

    post_pages =
      Process.get(:wire)
      |> Enum.drop(pre_count)
      |> Enum.filter(&(&1["op"] == "page" and &1["path"] == "/"))

    assert post_pages != []

    for p <- post_pages do
      assert Enum.map(Sessions.rows(p), & &1.key) == before -- ["W-2"]
      refute Enum.any?(Sessions.rows(p), & &1.pending)
    end

    delivered = :erlang.trace_delivered(session)
    assert_receive {:trace_delivered, ^session, ^delivered}, 5_000
    true = :erlang.resume_process(tracer)
    ledger = Sessions.ledger(tracer, session, boundary, position)
    IO.puts("proof: controlled frames " <> JSON.encode!(Sessions.evidence(ledger)))
    Sessions.assert_marker_frames(ledger, before, %{key: "W-2", label: "W-2"})

    lists =
      for %{type: "send", message: %{"op" => "page", "path" => "/"}} = frame <- ledger, do: frame

    assert Enum.any?(lists, &(&1.phase == "pending"))
    assert Enum.any?(lists, &(&1.phase == "covered"))
    assert Enum.any?(lists, &(&1.message == pending and &1.phase == "pending"))
    assert Enum.any?(lists, &(&1.message == opened and &1.phase == "pending"))
    assert Enum.any?(lists, &(&1.message == cleared and &1.phase == "covered"))
    # No TCP page is lost by the trace/collector barrier, nor filtered by reason.
    wire_pages = for %{"op" => "page"} = p <- Enum.drop(Process.get(:wire), 2), do: p
    traced_pages = for %{type: "send", message: %{"op" => "page"} = p} <- ledger, do: p
    assert traced_pages == wire_pages

    for frame <- lists do
      if frame.phase == "pending" do
        assert Enum.map(Sessions.rows(frame.message), & &1.key) == before
        assert Enum.any?(Sessions.rows(frame.message), &(&1.key == "W-2" and &1.pending))
      else
        assert Enum.map(Sessions.rows(frame.message), & &1.key) == before -- ["W-2"]
        refute Enum.any?(Sessions.rows(frame.message), & &1.pending)
      end
    end

    assert Process.alive?(facts)
  end

  test "real Session handler accepts covering late ids, but not invalid or below-position answers" do
    state = %{
      settled: 7,
      marks: %{"W-2" => 10},
      settling: %{id: "current-request", position: 10},
      recent: AtlasControl.Freshness.Recent.new()
    }

    tracer = Sessions.watch([self()])

    on_exit(fn ->
      Process.exit(tracer, :kill)
      :erlang.trace_pattern({:gen_tcp, :send, 2}, false, [:global])
      :erlang.trace_pattern({AtlasControl.Session, :handle_info, 2}, false, [:global])
    end)

    late = %{AtlasBus.Envelope.new("answer", "_settled") | id: "old-request"}

    for value <- ["10", 10.0, nil, 9, 10] do
      assert {:noreply, changed} =
               AtlasControl.Session.handle_info({:atlas_bus, late, %{"settled" => value}}, state)

      if value === 10 do
        assert changed.marks == %{}
        assert changed.settled == 10
      else
        assert changed.marks == state.marks
      end

      # The late answer clears marks without ending a different outstanding wait.
      assert changed.settling == state.settling
    end

    ledger = Sessions.ledger(tracer, self(), 0, 10)
    assert Enum.map(ledger, & &1.phase) == ["pending", "pending", "pending", "pending", "covered"]
    IO.puts("proof: late-answer boundaries " <> JSON.encode!(Sessions.evidence(ledger)))
  end
end

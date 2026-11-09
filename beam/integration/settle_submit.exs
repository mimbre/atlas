# A submit through Control waits for Flow to settle past it (docs/design/page-freshness.md
# §2.1, §2.2), on the real path: Facts (on its in-memory rela), Flow's engine and the
# processes of the facts, and a Control session over its Gateway, all on the Bus. The
# neutral workshop model (atlas_flow's test support). No time passes but the manual
# clocks': Flow's, and Control's held waits.
# From beam/: MIX_ENV=test mix run integration/settle_submit.exs
ExUnit.start(seed: 0)

defmodule SettleSubmitTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AtlasBus.Envelope
  alias AtlasFacts.FakeRela
  alias AtlasFlow.{Engine, ManualClock}

  @moduletag :tmp_dir
  @model AtlasFlow.Workshop
  # How long a message may take to arrive: a bound for delivery, never a wait under test.
  @arrives 5_000
  # The most `_page` reads one submit makes Control ask: the stored page and the recent
  # pages pushed with it (at most 3).
  @page_reads 4

  setup %{tmp_dir: dir} do
    Application.put_env(:atlas_bus, :store, "settle-#{System.unique_integer([:positive])}")
    :ok = Supervisor.terminate_child(AtlasFlow.Root, AtlasFlow.Supervisor)
    {:ok, _} = Supervisor.restart_child(AtlasFlow.Root, AtlasFlow.Supervisor)

    rela = FakeRela.start(@model)

    facts =
      start_supervised!({AtlasFacts.Server, rela: {FakeRela, rela}, data_dir: dir, model: @model})

    {:ok, _} = FakeRela.create(rela, "makers", "mia", %{"name" => "Mia"}, %{})
    widgets(rela, facts, 1..10)

    clock = start_supervised!({ManualClock, ~U[2026-11-12 00:00:00Z]})

    engine =
      start_supervised!({Engine, every: 3_600_000, clock: {ManualClock, clock}, model: @model})

    Engine.round(engine)
    settle(engine)

    AtlasControl.Clock.hold(self())
    on_exit(&AtlasControl.Clock.release/0)
    start_supervised!({AtlasControl.Gateway, port: 0, name: :settle_gateway, model: @model})

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasControl.Sessions),
          do: DynamicSupervisor.terminate_child(AtlasControl.Sessions, pid)

      for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasFlow.Supervisor),
          do: DynamicSupervisor.terminate_child(AtlasFlow.Supervisor, pid)
    end)

    %{rela: rela, facts: facts, engine: engine, clock: clock, socket: client()}
  end

  # Widgets put in the store behind Facts' back, as a fixture: no hint, so only a round
  # gives them processes.
  defp widgets(rela, facts, numbers) do
    for n <- numbers,
        do: {:ok, _} = FakeRela.create(rela, "widgets", "W-#{n}", %{"title" => "W#{n}"}, %{})

    :ok = AtlasFacts.Server.flush_collections(facts)
  end

  defp items,
    do: for({_, pid, _, _} <- DynamicSupervisor.which_children(AtlasFlow.Supervisor), do: pid)

  # Every process handled what it was sent, and the engine what they reported.
  defp settle(engine) do
    for _ <- 1..3 do
      Enum.each(items(), &handled/1)
      :sys.get_state(engine)
    end
  end

  # A process handled what it was sent; one that stopped meanwhile (its fact is done or
  # gone) has nothing left to handle.
  defp handled(pid) do
    :sys.get_state(pid)
  catch
    :exit, _ -> :ok
  end

  defp client do
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", AtlasControl.Gateway.port(:settle_gateway), [
        :binary,
        packet: :line,
        active: false,
        buffer: 4_194_304
      ])

    put(socket, %{
      "op" => "hello",
      "env" => "test",
      "client" => "test",
      "spec" => AtlasControl.Blocks.version()
    })

    assert %{"path" => "/"} = next(socket, "page")
    socket
  end

  defp put(socket, message), do: :ok = :gen_tcp.send(socket, [JSON.encode!(message), "\n"])

  defp next(socket, op, test \\ fn _ -> true end) do
    {:ok, line} = :gen_tcp.recv(socket, 0, @arrives)
    message = JSON.decode!(line)
    if message["op"] == op and test.(message), do: message, else: next(socket, op, test)
  end

  # Open `path`, submit `values` on it; Flow's looks run once Control asked how far Flow
  # settled. `{session, position, the stored page}`; the settle timeout is never run out.
  defp submit(c, path, values) do
    put(c.socket, %{"op" => "open", "to" => path})
    # Pages pushed for what earlier submits changed may come first.
    assert %{"path" => ^path} = next(c.socket, "page", &(&1["path"] == path))
    put(c.socket, %{"op" => "submit", "to" => path, "values" => values})

    # Stored: the session asks Flow and waits, at most its budget (held here).
    assert_receive {:clock, session, {:settle_timeout, _}, 1_000}, @arrives
    position = :sys.get_state(session).settling.position

    # The hint came before the question: the processes it poked look now.
    :sys.get_state(c.engine)
    Enum.each(items(), &handled/1)
    ManualClock.advance(c.clock, 50)
    settle(c.engine)

    page = next(c.socket, "page", &(&1["reason"] == "stored"))
    {session, position, page}
  end

  test "a submit's _settled is answered past its position, and no settle timeout fires", c do
    log =
      capture_log(fn ->
        {session, position, page} = submit(c, "/k/widget/W-1/edit", %{"title" => "Changed"})
        assert page["path"] == "/k/widget/W-1"
        state = :sys.get_state(session)
        assert state.settling == nil
        assert state.settled >= position
      end)

    refute log =~ "settle timeout"
  end

  test "one submit reads as much from Facts with 200 facts as with 10", c do
    # A plain change, a create and a delete, each of a widget no other submit touched, each
    # from a client of its own (a session's recent pages are its history, not the store's).
    once = fn path, values ->
      c = %{c | socket: client()}
      measured(c, fn -> submit(c, path, values) end)
    end

    shapes = fn n ->
      %{
        change: once.("/k/widget/W-#{n}/edit", %{"title" => "Changed"}),
        create: once.("/k/widget/new", %{"title" => "New #{n}"}),
        delete: once.("/k/widget/W-#{n + 1}/delete", %{})
      }
    end

    few = shapes.(1)
    widgets(c.rela, c.facts, 11..200)
    Engine.round(c.engine)
    settle(c.engine)
    # Each widget has its process (the in-memory rela lists every fact under each kind).
    assert length(items()) >= 200
    many = shapes.(3)

    for shape <- [:change, :create, :delete] do
      IO.puts(
        "Facts' answers for one #{shape}: 10 facts #{inspect(few[shape])}, " <>
          "200 facts #{inspect(many[shape])}"
      )
    end

    # Flow reads around the facts the write is about: the same, whatever else exists.
    # Control reads one page per page that shows what changed, at most a few.
    for shape <- [:change, :create, :delete] do
      assert many[shape].flow == few[shape].flow, "Flow's reads for a #{shape}"
      assert many[shape].control_reads <= @page_reads
      assert few[shape].control_reads <= @page_reads
    end
  end

  # What Facts answered while a submit ran: Flow's reads and the facts they held; the
  # submitting session's reads.
  defp measured(c, fun) do
    :erlang.trace_pattern({AtlasBus, :send, 2}, true, [:global])
    :erlang.trace(c.facts, true, [:call, {:tracer, self()}])
    {session, _, _} = fun.()
    :erlang.trace(c.facts, false, [:call])
    :erlang.trace_pattern({AtlasBus, :send, 2}, false, [:global])

    answers = traced([])
    endpoint = :sys.get_state(session).endpoint

    flow = for {"flow" <> _, content} <- answers, do: content
    control = for {^endpoint, _} <- answers, do: :read

    %{flow: {length(flow), Enum.sum(Enum.map(flow, &held/1))}, control_reads: length(control)}
  end

  defp traced(acc) do
    receive do
      {:trace, _, :call, {AtlasBus, :send, [%Envelope{class: "answer", address: to}, content]}} ->
        traced([{to, content} | acc])

      {:trace, _, :call, _} ->
        traced(acc)
    after
      0 -> acc
    end
  end

  defp held(%{"facts" => facts}) when is_list(facts), do: length(facts)
  defp held(%{"fact" => %{}}), do: 1
  defp held(_), do: 0
end

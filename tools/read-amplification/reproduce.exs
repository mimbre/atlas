# Private source investigation for GitHub86. Run from beam with MIX_ENV=test,
# ELIXIR_ERL_OPTIONS='+S 1:1', mix run --no-start ../tools/read-amplification/reproduce.exs.
# No production settings, copied data, model, external HTTP or fixed listener port.
if Mix.env() != :test, do: raise("This private probe requires MIX_ENV=test")

ExUnit.start(autorun: false)
Application.put_env(:atlas_control, :start, false)
{:ok, _} = Application.ensure_all_started(:atlas_control)

defmodule ReadAmplification.Backend do
  @behaviour AtlasFacts.Rela

  def description(config) do
    {n, mode} =
      Agent.get_and_update(config.counter, fn s ->
        {{s.n + 1, s.mode}, %{s | n: s.n + 1, mode: if(s.mode == :hold, do: :open, else: s.mode)}}
      end)

    case mode do
      {:delay, ms} ->
        send(config.owner, {:schema_started, n})
        Process.sleep(ms)

      :hold ->
        ref = make_ref()
        send(config.owner, {:schema_held, self(), ref})

        receive do
          {:release_schema, ^ref} -> :ok
        after
          3_000 -> raise "private gate not released"
        end

      :open ->
        :ok
    end

    AtlasFacts.FakeRela.description(config.fake)
  end

  for {name, arity} <- AtlasFacts.Rela.behaviour_info(:callbacks), name != :description do
    args = Macro.generate_arguments(arity - 1, __MODULE__)

    def unquote(name)(config, unquote_splicing(args)),
      do: apply(AtlasFacts.FakeRela, unquote(name), [config.fake, unquote_splicing(args)])
  end
end

defmodule ReadAmplification.Probe do
  use ExUnit.Case, async: false
  alias AtlasBus.Envelope

  setup do
    Application.put_env(
      :atlas_bus,
      :store,
      "private-pressure-#{System.unique_integer([:positive])}"
    )

    Application.put_env(:atlas_control, :read_timeout_ms, 500)
    {:ok, counter} = Agent.start_link(fn -> %{n: 0, mode: :open} end)
    fake = AtlasFacts.FakeRela.start()
    config = %{counter: counter, fake: fake, owner: self()}
    nonce = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    dir = Path.join(System.tmp_dir!(), "atlas-pressure-#{nonce}")
    File.mkdir!(dir)

    facts =
      start_supervised!(
        {AtlasFacts.Server, rela: {ReadAmplification.Backend, config}, data_dir: dir}
      )

    start_supervised!({AtlasControl.Gateway, port: 0, name: :private_pressure_gateway})

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasControl.Sessions),
          do: DynamicSupervisor.terminate_child(AtlasControl.Sessions, pid)

      Application.delete_env(:atlas_control, :read_timeout_ms)
    end)

    %{
      counter: counter,
      facts: facts,
      port: AtlasControl.Gateway.port(:private_pressure_gateway),
      dir: dir
    }
  end

  defp evidence(name, data) do
    root = System.fetch_env!("ATLAS_READ_PROBE_EVIDENCE")
    File.mkdir_p!(root)
    File.write!(Path.join(root, name <> ".json"), JSON.encode!(data) <> "\n")
    IO.puts("PRIVATE_PROBE #{name}: #{JSON.encode!(data)}")
  end

  defp put(socket, message), do: :gen_tcp.send(socket, [JSON.encode!(message), "\n"])

  defp connect(port) do
    {:ok, s} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :line, active: false])

    put(s, %{
      "op" => "hello",
      "env" => "test",
      "client" => "test",
      "spec" => AtlasControl.Blocks.version()
    })

    s
  end

  defp page(s, frames \\ []) do
    {:ok, line} = :gen_tcp.recv(s, 0, 3_000)
    f = JSON.decode!(line)
    if f["op"] == "page", do: Enum.reverse([f | frames]), else: page(s, [f | frames])
  end

  defp observe(facts) do
    observer = spawn(fn -> observations(facts, %{ids: [], max_facts_queue: 0}) end)
    :erlang.trace(Process.whereis(AtlasBus.Router), true, [:send, {:tracer, observer}])

    on_exit(fn ->
      :erlang.trace(Process.whereis(AtlasBus.Router), false, [:send])
      Process.exit(observer, :kill)
    end)

    observer
  end

  defp observations(facts, data) do
    receive do
      {:trace, _, :send, {:atlas_bus, %Envelope{class: "read", kind: "_description", id: id}, _},
       ^facts} ->
        {:message_queue_len, n} = Process.info(facts, :message_queue_len)

        observations(facts, %{ids: [id | data.ids], max_facts_queue: max(n, data.max_facts_queue)})

      {:snapshot, from, ref} ->
        send(from, {ref, data})
        observations(facts, data)

      _ ->
        observations(facts, data)
    end
  end

  test "one logical description fetch reaches backend once", ctx do
    :ok = AtlasBus.attach("private-pressure-reader")
    e = Envelope.new("read", "_description")
    :ok = AtlasBus.send(e, %{})
    id = e.id
    assert_receive {:atlas_bus, %Envelope{id: ^id, class: "answer"}, %{"description" => _}}, 1_000
    n = Agent.get(ctx.counter, & &1.n)
    evidence("double-schema", %{backend_description_calls: n, expected: 1, fixture: ctx.dir})
    assert n == 1
  end

  test "healthy 300ms backend can answer inside 1500ms logical budget", ctx do
    Agent.update(ctx.counter, &%{&1 | mode: {:delay, 300}})
    observer = observe(ctx.facts)
    began = System.monotonic_time(:millisecond)
    s = connect(ctx.port)
    on_exit(fn -> :gen_tcp.close(s) end)
    frames = page(s)
    elapsed = System.monotonic_time(:millisecond) - began
    ref = make_ref()
    send(observer, {:snapshot, self(), ref})
    assert_receive {^ref, data}
    failed = Enum.any?(frames, &String.contains?(JSON.encode!(&1), "Facts did not answer"))

    evidence("slow-schema", %{
      backend_ms: 300,
      read_wait_ms: 500,
      logical_budget_ms: 1500,
      elapsed_ms: elapsed,
      backend_description_calls: Agent.get(ctx.counter, & &1.n),
      distinct_read_ids: Enum.uniq(data.ids),
      max_facts_queue: data.max_facts_queue,
      facts_did_not_answer: failed,
      fixture: ctx.dir
    })

    refute failed
  end

  test "observational: refresh frames queue and each renders after backend unblocks", ctx do
    s = connect(ctx.port)
    on_exit(fn -> :gen_tcp.close(s) end)
    page(s)
    before = Agent.get(ctx.counter, & &1.n)
    Agent.update(ctx.counter, &%{&1 | mode: :hold})
    put(s, %{"op" => "refresh"})
    assert_receive {:schema_held, state, ref}, 1_000
    on_exit(fn -> send(state, {:release_schema, ref}) end)
    [{_, session, _, _}] = DynamicSupervisor.which_children(AtlasControl.Sessions)
    for _ <- 1..6, do: put(s, %{"op" => "refresh"})
    queued = queued_refreshes(session, System.monotonic_time(:millisecond) + 500)
    send(state, {:release_schema, ref})
    pages = for _ <- 1..7, do: page(s) |> List.last()
    calls = Agent.get(ctx.counter, & &1.n) - before

    evidence("refresh-queue", %{
      queued_refreshes: queued,
      reconcile_pages: length(pages),
      backend_description_calls: calls,
      fixture: ctx.dir
    })

    assert queued == 6
    assert length(pages) == 7
  end

  defp queued_refreshes(pid, deadline) do
    {:messages, messages} = Process.info(pid, :messages)

    n =
      Enum.count(messages, fn
        {:tcp, _, line} -> JSON.decode!(line)["op"] == "refresh"
        _ -> false
      end)

    if n >= 6 or System.monotonic_time(:millisecond) >= deadline do
      n
    else
      Process.sleep(5)
      queued_refreshes(pid, deadline)
    end
  end
end

result = ExUnit.run()
System.halt(if result.failures == 0, do: 0, else: 1)

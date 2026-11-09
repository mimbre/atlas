defmodule AtlasBus.LinkTest do
  use ExUnit.Case, async: false
  require Logger
  alias AtlasBus.{Envelope, Link}

  setup do
    Application.put_env(:atlas_bus, :environment, "test")

    start_supervised!(
      {Link.Server, %{"port" => 0, "tokens" => %{"laptop" => "private-test-token"}}}
    )

    %{port: Link.Server.port()}
  end

  defp connect(port, more \\ %{}) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :line, active: false])

    frame =
      Map.merge(
        %{"environment" => "test", "machine" => "laptop", "token" => "private-test-token"},
        more
      )

    :ok = :gen_tcp.send(socket, Link.encode("hello", frame))
    socket
  end

  defp recv(socket) do
    {:ok, line} = :gen_tcp.recv(socket, 0, 1_000)
    JSON.decode!(line)
  end

  defp eventually(fun, n \\ 100) do
    cond do
      fun.() ->
        :ok

      n == 0 ->
        flunk("Bus did not reconcile")

      true ->
        Process.sleep(10)
        eventually(fun, n - 1)
    end
  end

  # Whether `name`'s entry is gone once each Registry partition has handled what it was sent:
  # synchronous calls to the partitions, asked again while an exit is still on its way.
  defp registry_dropped(name, tries \\ 1_000) do
    for {_, partition, _, _} <- Supervisor.which_children(AtlasBus.Endpoints),
        do: :sys.get_state(partition)

    cond do
      Registry.lookup(AtlasBus.Endpoints, name) == [] -> true
      tries == 0 -> false
      true -> registry_dropped(name, tries - 1)
    end
  end

  defp attach_remote(socket, name) do
    :ok = :gen_tcp.send(socket, Link.encode("attach", %{"endpoint" => name}))
    eventually(fn -> Registry.lookup(AtlasBus.Endpoints, name) != [] end)
  end

  defp send_remote(socket, name, envelope, content \\ %{}) do
    :gen_tcp.send(
      socket,
      Link.encode("send", %{
        "endpoint" => name,
        "envelope" => Link.envelope_out(envelope),
        "content" => content
      })
    )
  end

  test "hello binds the token to both environment and machine", %{port: port} do
    for more <- [%{"token" => "wrong"}, %{"environment" => "prod"}, %{"machine" => "other"}] do
      s = connect(port, more)
      assert recv(s)["op"] == "refused"
      assert :gen_tcp.recv(s, 0, 1_000) == {:error, :closed}
      :gen_tcp.close(s)
    end
  end

  test "endpoint impersonation and forged acknowledgements close the link", %{port: port} do
    for name <- ["state", "flow", "control/output", "runtime@other", "runtime@laptop-other"] do
      s = connect(port)
      assert recv(s)["op"] == "welcome"
      :gen_tcp.send(s, Link.encode("attach", %{"endpoint" => name}))
      assert recv(s)["op"] == "refused"
      :gen_tcp.close(s)
    end

    s = connect(port)
    recv(s)
    :gen_tcp.send(s, Link.encode("attach", %{"endpoint" => "runtime@laptop"}))

    :gen_tcp.send(
      s,
      Link.encode("send", %{
        "endpoint" => "runtime@laptop",
        "envelope" => Link.envelope_out(Envelope.new("stored", "parcel")),
        "content" => %{}
      })
    )

    assert recv(s)["op"] == "refused"
    :gen_tcp.close(s)
  end

  test "stopping or crashing the listener closes its connections and registrations", %{port: port} do
    for how <- [:stop, :kill] do
      s = connect(if(how == :stop, do: port, else: Link.Server.port()))
      recv(s)
      name = "runtime@laptop/owned-by-listener"
      :gen_tcp.send(s, Link.encode("attach", %{"endpoint" => name}))
      eventually(fn -> Registry.lookup(AtlasBus.Endpoints, name) != [] end)

      case how do
        :stop ->
          stop_supervised!(Link.Server)

          start_supervised!(
            {Link.Server, %{"port" => 0, "tokens" => %{"laptop" => "private-test-token"}}}
          )

        :kill ->
          Process.exit(Process.whereis(Link.Server), :kill)
      end

      assert :gen_tcp.recv(s, 0, 1_000) == {:error, :closed}
      eventually(fn -> Registry.lookup(AtlasBus.Endpoints, name) == [] end)
      :gen_tcp.close(s)
    end
  end

  test "envelopes cross both ways with the registered sender; disconnect removes endpoints", %{
    port: port
  } do
    store = "link-test-store"
    Application.put_env(:atlas_bus, :store, store)
    :ok = AtlasBus.attach(store)
    s = connect(port)
    assert recv(s)["op"] == "welcome"
    name = "runtime@laptop/T-1"
    :gen_tcp.send(s, Link.encode("attach", %{"endpoint" => name}))
    :gen_tcp.send(s, Link.encode("listen", %{"endpoint" => name, "kind" => "parcel"}))
    envelope = %{Envelope.new("read", "parcel") | sender: "state"}

    :gen_tcp.send(
      s,
      Link.encode("send", %{
        "endpoint" => name,
        "envelope" => Link.envelope_out(envelope),
        "content" => %{"key" => "P-1"}
      })
    )

    assert_receive {:atlas_bus, received, %{"key" => "P-1"}}, 1_000
    assert received.sender == name
    AtlasBus.send(Envelope.reply(received, "answer"), %{"value" => 42})
    assert %{"op" => "deliver", "endpoint" => ^name, "content" => %{"value" => 42}} = recv(s)
    AtlasBus.send(%{Envelope.new("stored", "parcel") | address: nil}, %{"key" => "P-1"})
    assert recv(s)["envelope"]["class"] == "stored"
    # One proxy owns both registrations, and each Registry drops its own entry after the proxy
    # exits: wait for that exit, then for both entries, never for one and assert the other.
    [{proxy, _}] = Registry.lookup(AtlasBus.Endpoints, name)
    assert Registry.keys(AtlasBus.Listeners, proxy) == ["parcel"]
    ref = Process.monitor(proxy)
    :gen_tcp.close(s)
    assert_receive {:DOWN, ^ref, :process, ^proxy, _}, 1_000

    eventually(fn ->
      Registry.lookup(AtlasBus.Endpoints, name) == [] and
        Registry.lookup(AtlasBus.Listeners, "parcel") == []
    end)
  end

  test "Control output requests and answers retain IDs, payload and authenticated sender", %{
    port: port
  } do
    control = "control/output-test"
    name = "runtime@laptop/output"
    :ok = AtlasBus.attach(control)
    socket = connect(port)
    assert recv(socket)["op"] == "welcome"
    attach_remote(socket, name)

    request = %{Envelope.new("request", "runtime.output") | address: name}

    payload = %{
      "id" => request.id,
      "request" => %{"runtime_output_snapshot" => %{"cursor" => nil}}
    }

    assert :ok = AtlasBus.send(request, payload)
    frame = recv(socket)
    assert frame["op"] == "deliver"
    assert frame["endpoint"] == name
    assert frame["content"] == payload
    received = Link.envelope_in(frame["envelope"])
    assert received == %{request | sender: control}
    assert received.position == nil

    reply = %{Envelope.reply(received, "answer") | sender: "runtime@other/output"}
    result = %{"id" => request.id, "result" => %{"events" => []}}
    assert :ok = send_remote(socket, name, reply, result)
    id = request.id

    assert_receive {:atlas_bus,
                    %Envelope{
                      class: "answer",
                      kind: "runtime.output",
                      id: ^id,
                      sender: ^name,
                      address: ^control,
                      position: nil
                    }, ^result},
                   1_000

    :gen_tcp.close(socket)
  end

  test "the core only delivers output requests from Control to the machine output endpoint", %{
    port: port
  } do
    :ok = AtlasBus.attach("control/output-permissions")
    socket = connect(port)
    assert recv(socket)["op"] == "welcome"
    output = "runtime@laptop/output"
    turn = "runtime@laptop/T-output"
    attach_remote(socket, output)
    attach_remote(socket, turn)
    request = %{Envelope.new("request", "runtime.output") | address: output}

    for envelope <- [
          %{request | kind: "another-kind"},
          %{request | address: turn},
          %{request | position: 1},
          %{request | class: "answer"}
        ] do
      assert :ok = AtlasBus.send(envelope, %{})
      assert :gen_tcp.recv(socket, 0, 50) == {:error, :timeout}
    end

    assert :ok = AtlasBus.send(request, %{"allowed" => true})
    assert recv(socket)["content"] == %{"allowed" => true}
    :gen_tcp.close(socket)
  end

  test "a non-Control sender cannot deliver an output request by claiming Control", %{port: port} do
    :ok = AtlasBus.attach("not-control")
    socket = connect(port)
    assert recv(socket)["op"] == "welcome"
    name = "runtime@laptop/output"
    attach_remote(socket, name)

    request = %{
      Envelope.new("request", "runtime.output")
      | address: name,
        sender: "control/forged"
    }

    assert :ok = AtlasBus.send(request, %{})
    assert :gen_tcp.recv(socket, 0, 50) == {:error, :timeout}
    :gen_tcp.close(socket)
  end

  test "remote requests and out-of-scope output answers close the link", %{port: port} do
    output = "runtime@laptop/output"
    answer = %{Envelope.new("answer", "runtime.output") | address: "control/output-replies"}

    for {name, envelope} <- [
          {output, %{answer | class: "request", sender: "control/forged", address: output}},
          {output, %{answer | class: "request", kind: "another-kind"}},
          {output, %{answer | class: "fact"}},
          {output, %{answer | class: "read"}},
          {output, %{answer | class: "stored"}},
          {output, %{answer | address: "state"}},
          {output, %{answer | address: "control/"}},
          {output, %{answer | address: "control-other/replies"}},
          {output, %{answer | address: nil}},
          {output, %{answer | position: 1}},
          {output, %{answer | id: ""}},
          {output, %{answer | environment: "prod"}},
          {"runtime@laptop/T-output", answer}
        ] do
      socket = connect(port)
      assert recv(socket)["op"] == "welcome"
      attach_remote(socket, name)
      assert :ok = send_remote(socket, name, envelope)
      assert recv(socket)["op"] == "refused"
      assert :gen_tcp.recv(socket, 0, 1_000) == {:error, :closed}
      eventually(fn -> Registry.lookup(AtlasBus.Endpoints, name) == [] end)
      :gen_tcp.close(socket)
    end
  end

  test "the client also enforces output request direction, scope and envelope validation", %{
    port: port
  } do
    name = "runtime@laptop/output"
    :ok = AtlasBus.attach(name)
    socket = connect(port)
    assert recv(socket)["op"] == "welcome"
    state = %{socket: socket, settings: %{"machine" => "laptop"}}

    request = %{
      Envelope.new("request", "runtime.output")
      | address: name,
        sender: "control/output"
    }

    for {endpoint, envelope} <- [
          {name, %{request | kind: "another-kind"}},
          {name, %{request | sender: "runtime@laptop"}},
          {name, %{request | sender: "control/"}},
          {name, %{request | sender: nil}},
          {name, %{request | address: "runtime@other/output"}},
          {name, %{request | address: nil}},
          {"runtime@other/output", %{request | address: "runtime@other/output"}},
          {name, %{request | class: "answer"}},
          {name, %{request | position: 1}},
          {name, %{request | environment: "prod"}},
          {name, %{request | id: ""}}
        ] do
      line =
        Link.encode("deliver", %{
          "endpoint" => endpoint,
          "envelope" => Link.envelope_out(envelope),
          "content" => %{}
        })
        |> IO.iodata_to_binary()

      assert {:noreply, ^state} = Link.Client.handle_info({:tcp, socket, line}, state)
      refute_receive {:atlas_bus, _, _}, 10
    end

    line =
      Link.encode("deliver", %{
        "endpoint" => name,
        "envelope" => Link.envelope_out(request),
        "content" => %{"id" => request.id}
      })
      |> IO.iodata_to_binary()

    assert {:noreply, ^state} = Link.Client.handle_info({:tcp, socket, line}, state)
    id = request.id
    assert_receive {:atlas_bus, ^request, %{"id" => ^id}}
    :gen_tcp.close(socket)
  end

  test "the supervised client authenticates and reconnects; its diagnostics never print the token",
       %{
         port: port
       } do
    import ExUnit.CaptureLog
    token = "private-test-token"
    previous = Application.fetch_env(:atlas_bus, :link)
    %{filters: filters} = :logger.get_primary_config()

    # Restores the logger and the env once the test is done.
    on_exit(fn ->
      :ok = :logger.set_primary_config(:filters, filters)

      case previous do
        {:ok, link} -> Application.put_env(:atlas_bus, :link, link)
        :error -> Application.delete_env(:atlas_bus, :link)
      end
    end)

    Application.put_env(:atlas_bus, :link, %{
      "mode" => "client",
      "host" => "127.0.0.1",
      "port" => port,
      "machine" => "laptop",
      "token" => token
    })

    # The test's own supervisor holds the client, so its deliberate crashes spend that
    # supervisor's restart budget, never AtlasBus.Supervisor's. ExUnit stops it before the
    # on_exit above, so the client is gone before the env is client-free.
    supervisor =
      start_supervised!(%{
        id: :link_client_supervisor,
        start: {Supervisor, :start_link, [[Link.Client], [strategy: :one_for_one]]},
        type: :supervisor
      })

    authenticated? = fn ->
      try do
        Link.Client.status()
      catch
        :exit, _ -> false
      end
    end

    eventually(authenticated?, 500)

    # No settings, so no token, in the child spec or its start arguments.
    {:ok, spec} = :supervisor.get_childspec(supervisor, Link.Client)
    refute inspect(spec, limit: :infinity) =~ token

    # Reconnect with the same token after the core drops the connection.
    socket = :sys.get_state(Link.Client).socket
    for pid <- :sys.get_state(Link.Server).connections, do: Process.exit(pid, :shutdown)
    eventually(fn -> :sys.get_state(Link.Client).socket not in [nil, socket] end, 500)
    assert authenticated?.()

    crash = fn ->
      parent = self()
      before = Process.whereis(Link.Client)

      spawn(fn ->
        send(
          parent,
          {:caller, catch_exit(GenServer.call(Link.Client, :synthetic_verifier_crash))}
        )
      end)

      assert_receive {:caller, reason}, 5_000
      # The supervisor restarts it, and it authenticates again.
      eventually(fn -> Process.whereis(Link.Client) not in [nil, before] end, 500)
      eventually(authenticated?, 500)
      reason
    end

    for sasl <- [false, true] do
      {fun, config} = filters[:logger_translator]
      translator = {:logger_translator, {fun, %{config | sasl: sasl}}}

      :ok =
        :logger.set_primary_config(
          :filters,
          List.keyreplace(filters, :logger_translator, 0, translator)
        )

      log = capture_log(fn -> send(self(), {:reason, crash.()}) end)
      assert_received {:reason, reason}

      # The failure stays real and diagnosable, without the token.
      assert {{:function_clause,
               [{Link.Client, :handle_call, [:synthetic_verifier_crash | _], _} | _]},
              {GenServer, :call, _}} = reason

      refute inspect(reason, limit: :infinity) =~ token
      assert log =~ "AtlasBus.Link.Client"
      assert log =~ ":synthetic_verifier_crash"
      refute log =~ token
    end
  end

  # A reply that comes after its link closed finds nobody (the Router drops it). A fact is sent
  # again with the same id (AtlasRuntime.Talk); sent again over a new link, without waiting for
  # the attach, it gets its reply: the endpoint is there before what it sends is routed.
  test "a reply after its link closed is dropped; sent again over a new link, it is delivered",
       %{port: port} do
    store = "link-test-store"
    Application.put_env(:atlas_bus, :store, store)
    :ok = AtlasBus.attach(store)
    name = "runtime@laptop/T-late"
    fact = Envelope.new("fact", "parcel")

    first = connect(port)
    assert recv(first)["op"] == "welcome"
    :gen_tcp.send(first, Link.encode("attach", %{"endpoint" => name}))
    send_remote(first, name, fact)
    id = fact.id
    assert_receive {:atlas_bus, %Envelope{id: ^id, sender: ^name} = asked, _}, 1_000

    [{proxy, _}] = Registry.lookup(AtlasBus.Endpoints, name)
    ref = Process.monitor(proxy)
    :gen_tcp.close(first)
    assert_receive {:DOWN, ^ref, :process, ^proxy, _}, 1_000
    # The Registry drops the entry when it handles the proxy's exit, after that DOWN.
    assert registry_dropped(name)
    # The drop is logged, naming the reply, at debug (the Router's level is raised here only).
    Logger.put_module_level(AtlasBus.Router, :debug)
    on_exit(fn -> Logger.delete_module_level(AtlasBus.Router) end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok =
                 AtlasBus.send(Envelope.reply(asked, "stored", position: 1), %{"reply" => "late"})
      end)

    assert log =~ id
    Logger.delete_module_level(AtlasBus.Router)

    again = connect(port)
    assert recv(again)["op"] == "welcome"
    :gen_tcp.send(again, Link.encode("attach", %{"endpoint" => name}))
    send_remote(again, name, fact)
    assert_receive {:atlas_bus, %Envelope{id: ^id, sender: ^name} = asked_again, _}, 1_000

    assert :ok =
             AtlasBus.send(Envelope.reply(asked_again, "stored", position: 1), %{
               "reply" => "fresh"
             })

    assert %{"op" => "deliver", "endpoint" => ^name, "envelope" => %{"id" => ^id}} =
             frame = recv(again)

    assert frame["content"] == %{"reply" => "fresh"}
    :gen_tcp.close(again)
  end

  # On (re)connect the client attaches every endpoint before it forwards anything, so the core
  # knows where each answer goes before the request it answers arrives.
  test "connecting, the client attaches its endpoints before it forwards a send" do
    name = "runtime@laptop/T-replay"
    :ok = AtlasBus.Router.attach(name)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :line, active: false])
    {:ok, port} = :inet.port(listener)
    test = self()

    core =
      spawn_link(fn ->
        {:ok, s} = :gen_tcp.accept(listener)
        {:ok, _hello} = :gen_tcp.recv(s, 0, 1_000)
        :ok = :gen_tcp.send(s, Link.encode("welcome", %{}))

        for _ <- 1..2 do
          {:ok, line} = :gen_tcp.recv(s, 0, 1_000)
          send(test, {:frame, JSON.decode!(line)})
        end

        receive do: (:done -> :gen_tcp.close(s))
      end)

    state = %{
      settings: %{"host" => "127.0.0.1", "port" => port, "machine" => "laptop"},
      secret: fn -> "private-test-token" end,
      socket: nil,
      refs: %{self() => make_ref()},
      delay: 2_000,
      names: %{}
    }

    assert {:noreply, %{socket: socket} = connected} = Link.Client.handle_info(:connect, state)
    read = %{Envelope.new("read", "parcel") | sender: name}
    assert {:noreply, ^connected} = Link.Client.handle_cast({:send, read, %{}}, connected)

    assert_receive {:frame, %{"op" => "attach", "endpoint" => ^name}}, 1_000
    assert_receive {:frame, %{"op" => "send", "endpoint" => ^name}}, 1_000
    send(core, :done)
    :gen_tcp.close(socket)
    :gen_tcp.close(listener)
    Registry.unregister(AtlasBus.Endpoints, name)
  end
end

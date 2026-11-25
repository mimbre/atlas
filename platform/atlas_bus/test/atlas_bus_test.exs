defmodule AtlasBusTest do
  use ExUnit.Case, async: false

  alias AtlasBus.Envelope

  # An endpoint process: attaches, optionally listens, forwards what it receives to the
  # test, and sends what the test tells it to (the Bus takes the sender from the process).
  defp endpoint(name, listen \\ []) do
    test = self()

    pid =
      spawn_link(fn ->
        :ok = AtlasBus.attach(name)
        Enum.each(listen, &(:ok = AtlasBus.listen(&1)))
        send(test, {:ready, name})
        loop(test, name)
      end)

    assert_receive {:ready, ^name}
    Process.put({:endpoint, name}, pid)
    pid
  end

  defp loop(test, name) do
    receive do
      {:atlas_bus, envelope, content} -> send(test, {name, envelope, content})
      {:send, envelope, content} -> send(test, {:sent, name, AtlasBus.send(envelope, content)})
      {:settle, ref} -> send(test, {:settled, ref})
    end

    loop(test, name)
  end

  # Once endpoint `name` has passed on all it was delivered: the Router has handled all it
  # was sent (it delivers there), and the endpoint forwards in order, so a refute after it
  # needs no window.
  defp settled(name) do
    :sys.get_state(AtlasBus.Router)
    ref = make_ref()
    send(Process.get({:endpoint, name}), {:settle, ref})
    assert_receive {:settled, ^ref}
  end

  defp send_from(pid, envelope, content \\ %{}) do
    send(pid, {:send, envelope, content})
    assert_receive {:sent, _, result}
    result
  end

  setup do
    name = "t#{System.unique_integer([:positive])}"
    Application.put_env(:atlas_bus, :store, name <> "-store")
    AtlasBus.drop_hints(0)
    %{store: name <> "-store", sender: name <> "-sender", other: name <> "-other"}
  end

  test "a fact goes to the store, and stored goes back to the sender and to listeners", c do
    store = endpoint(c.store)
    sender = endpoint(c.sender)
    endpoint(c.other, ["thing"])

    fact = Envelope.new("fact", "thing")
    :ok = send_from(sender, fact, %{"anything" => 1})
    store_name = c.store
    sender_name = c.sender
    assert_receive {^store_name, received, %{"anything" => 1}}
    assert %Envelope{id: id, sender: ^sender_name, address: ^store_name} = received
    assert id == fact.id

    :ok = send_from(store, Envelope.reply(received, "stored", position: 7), %{"key" => "x"})
    other = c.other
    assert_receive {^sender_name, %Envelope{class: "stored", id: ^id, position: 7}, _}
    assert_receive {^other, %Envelope{class: "stored", id: ^id, position: 7}, _}
  end

  test "refused and answer go to the sender only", c do
    store = endpoint(c.store)
    sender = endpoint(c.sender)
    endpoint(c.other, ["thing"])

    for {ask, reply} <- [{"fact", "refused"}, {"read", "answer"}] do
      :ok = send_from(sender, Envelope.new(ask, "thing"))
      store_name = c.store
      assert_receive {^store_name, received, _}
      :ok = send_from(store, Envelope.reply(received, reply))
      sender_name = c.sender
      other = c.other
      assert_receive {^sender_name, %Envelope{class: ^reply}, _}
      settled(other)
      refute_received {^other, %Envelope{class: ^reply}, _}
    end
  end

  test "an addressed request and its answer bypass Facts and hints", c do
    endpoint(c.store)
    sender = endpoint(c.sender)
    target = endpoint(c.other)
    listener_name = c.other <> "-listener"
    endpoint(listener_name, ["direct"])
    request = %{Envelope.new("request", "direct") | address: c.other, sender: "forged"}
    content = %{"operation" => "snapshot", "cursor" => nil}

    assert "request" in AtlasBus.classes()
    assert :ok = send_from(sender, request, content)
    target_name = c.other
    sender_name = c.sender
    id = request.id

    assert_receive {^target_name,
                    %Envelope{
                      class: "request",
                      sender: ^sender_name,
                      address: ^target_name,
                      id: ^id,
                      position: nil
                    } = received, ^content}

    assert :ok = send_from(target, Envelope.reply(received, "answer"), %{"events" => []})

    assert_receive {^sender_name,
                    %Envelope{
                      class: "answer",
                      sender: ^target_name,
                      id: ^id,
                      position: nil
                    }, %{"events" => []}}

    store_name = c.store
    settled(store_name)
    refute_received {^store_name, _, _}
    settled(listener_name)
    refute_received {^listener_name, _, _}
  end

  test "a listener gets only hints of the kinds it listens to", c do
    store = endpoint(c.store)
    sender = endpoint(c.sender)
    endpoint(c.other, ["a"])

    for kind <- ["a", "b"] do
      :ok = send_from(sender, Envelope.new("fact", kind))
      store_name = c.store
      assert_receive {^store_name, received, _}
      :ok = send_from(store, Envelope.reply(received, "stored", position: 1))
    end

    other = c.other
    assert_receive {^other, %Envelope{kind: "a"}, _}
    settled(other)
    refute_received {^other, %Envelope{kind: "b"}, _}
  end

  test "the Bus never reads content: any term passes through unchanged", c do
    endpoint(c.store)
    sender = endpoint(c.sender)

    for content <- [nil, "text", {:a, :tuple}, %{"deep" => [1, %{"x" => 2}]}, self()] do
      :ok = send_from(sender, Envelope.new("fact", "thing"), content)
      store = c.store
      assert_receive {^store, _, ^content}
    end
  end

  test "the sender is the sending endpoint, whatever the envelope claims", c do
    endpoint(c.store)
    sender = endpoint(c.sender)

    :ok = send_from(sender, %{Envelope.new("fact", "thing") | sender: "someone-else"})
    store = c.store
    sender_name = c.sender
    assert_receive {^store, %Envelope{sender: ^sender_name}, _}
    assert {:error, :not_attached} = AtlasBus.send(Envelope.new("fact", "thing"), %{})
  end

  test "an incomplete envelope, an unknown class or the other environment is refused", c do
    sender = endpoint(c.sender)

    assert {:error, {:incomplete_envelope, [:kind]}} =
             send_from(sender, Envelope.new("fact", ""))

    assert {:error, {:unknown_class, "whatever"}} =
             send_from(sender, Envelope.new("whatever", "thing"))

    assert {:error, {:other_environment, "prod"}} =
             send_from(sender, Envelope.new("fact", "thing", environment: "prod"))

    assert {:error, :not_an_envelope} = AtlasBus.send(%{id: "1"}, %{})
  end

  test "a prod Bus refuses test messages, and never drops a hint", c do
    Application.put_env(:atlas_bus, :environment, "prod")
    on_exit(fn -> Application.put_env(:atlas_bus, :environment, "test") end)
    sender = endpoint(c.sender)

    assert {:error, {:other_environment, "test"}} =
             send_from(sender, Envelope.new("fact", "thing", environment: "test"))

    assert :ok = send_from(sender, Envelope.new("fact", "thing"))
    assert {:error, :prod} = AtlasBus.drop_hints(1)
    # A failure to cause (IS-Atlas-23) is never routed in prod.
    assert {:error, :prod} = send_from(sender, %{Envelope.new("fault", "_fault") | address: "x"})
  end

  test "a fault goes to its address only (IS-Atlas-23)", c do
    sender = endpoint(c.sender)
    endpoint(c.other, ["_fault"])
    endpoint(c.store)
    :ok = send_from(sender, %{Envelope.new("fault", "_fault") | address: c.other})
    other = c.other
    assert_receive {^other, %Envelope{class: "fault", sender: sender_name}, _}
    assert sender_name == c.sender
    store = c.store
    settled(store)
    refute_received {^store, _, _}
  end

  test "a dropped hint still acknowledges the sender", c do
    store = endpoint(c.store)
    sender = endpoint(c.sender)
    endpoint(c.other, ["thing"])
    :ok = AtlasBus.drop_hints(1)

    :ok = send_from(sender, Envelope.new("fact", "thing"))
    store_name = c.store
    assert_receive {^store_name, received, _}
    :ok = send_from(store, Envelope.reply(received, "stored", position: 1))
    sender_name = c.sender
    other = c.other
    assert_receive {^sender_name, %Envelope{class: "stored"}, _}
    settled(other)
    refute_received {^other, _, _}
  end

  test "an endpoint name is taken once", c do
    endpoint(c.store)
    assert {:error, :taken} = AtlasBus.attach(c.store)
  end

  test "waiting counts the messages queued at an endpoint without waiting for it" do
    test = self()

    busy =
      spawn_link(fn ->
        :ok = AtlasBus.attach("waiting-test")
        send(test, :attached)

        receive do
          :go -> :ok
        end
      end)

    assert_receive :attached
    assert AtlasBus.waiting("waiting-test") == 0
    for n <- 1..3, do: send(busy, {:queued, n})
    assert AtlasBus.waiting("waiting-test") == 3
    assert AtlasBus.waiting("nobody-is-attached-as-this") == nil
    send(busy, :go)
  end
end

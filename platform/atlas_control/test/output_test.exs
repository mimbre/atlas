defmodule AtlasControl.OutputTest do
  use ExUnit.Case, async: false

  alias AtlasBus.Envelope
  alias AtlasControl.Output
  alias AtlasBFFContract.Wire.Runtime.OutputProtocol, as: Wire

  setup do
    if is_nil(Process.whereis(Output)), do: start_supervised!(Output)
    eventually(fn -> map_size(:sys.get_state(Output)) == 0 end)
    suffix = Integer.to_string(System.unique_integer([:positive]))

    execution = %{
      "worker" => %{
        "environment" => AtlasBus.environment(),
        "machine" => "output-test-" <> suffix,
        "worker" => "worker-1"
      },
      "turn" => "turn-1",
      "attempt" => "attempt-1"
    }

    %{execution: execution, view: view(execution)}
  end

  defp view(execution) do
    %{
      "execution" => execution,
      "state" => "running",
      "guidance" => %{"available" => false, "reason" => "not_supported"}
    }
  end

  defp stream(execution) do
    %{
      "execution" => execution,
      "epoch" => "epoch-1",
      "first_sequence" => 1,
      "watermark" => 1,
      "ended" => false
    }
  end

  defp result(:runtime_output_snapshot, request) do
    %{"id" => request["id"], "stream" => stream(request["execution"]), "cursor" => "cursor-1"}
  end

  defp result(:runtime_output_read, request) do
    %{
      "id" => request["id"],
      "stream" => stream(request["execution"]),
      "events" => [%{"sequence" => 1, "kind" => "text", "text" => "hello"}],
      "cursor" => "cursor-2",
      "more" => false
    }
  end

  defp reply(envelope, operation, props, kind \\ :result) do
    :ok = AtlasBus.send(Envelope.reply(envelope, "answer"), Wire.reply(operation, kind, props))
  end

  defp error(envelope, operation, code) do
    reply(
      envelope,
      operation,
      %{
        "id" => envelope.id,
        "error" => %{"code" => code, "message" => code, "retryable" => false}
      },
      :error
    )
  end

  defp process(fun) do
    parent = self()
    pid = spawn_link(fn -> fun.(parent) end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    assert_receive {:ready, ^pid}, 1_000
    pid
  end

  defp runtime(execution, handler \\ &reply(&1, &2, result(&2, &3))) do
    process(fn parent ->
      :ok = AtlasBus.attach("runtime@" <> execution["worker"]["machine"] <> "/output")
      send(parent, {:ready, self()})
      runtime_loop(parent, handler)
    end)
  end

  defp runtime_loop(parent, handler) do
    receive do
      {:atlas_bus, %Envelope{class: "request", kind: "runtime.output"} = envelope, payload} ->
        {:ok, operation, request} = Wire.decode_request(payload)
        send(parent, {:runtime_request, operation, envelope, request})
        handler.(envelope, operation, request)
        runtime_loop(parent, handler)
    end
  end

  defp viewer(view) do
    process(fn parent ->
      :ok = AtlasBus.attach("control/output-test-#{System.unique_integer([:positive])}")
      send(parent, {:ready, self()})
      viewer_loop(parent, {:ok, %{"view" => view}}, nil)
    end)
  end

  defp viewer_loop(parent, authorization, state) do
    receive do
      {:call, from, ref, {:authorize, next}} ->
        send(from, {ref, :ok})
        viewer_loop(parent, next, state)

      {:call, from, ref, {:handle, operation, request}} ->
        inspect = fn execution ->
          send(parent, {:authorized, self(), execution})
          authorization
        end

        result = Output.handle(operation, request, state, inspect)
        send(from, {ref, result})
        viewer_loop(parent, authorization, elem(result, tuple_size(result) - 1))

      {:call, from, ref, :acquire} ->
        send(from, {ref, GenServer.call(Output, :acquire)})
        viewer_loop(parent, authorization, state)
    end
  end

  defp call(pid, message) do
    ref = make_ref()
    send(pid, {:call, self(), ref, message})
    assert_receive {^ref, result}, 3_000
    result
  end

  defp subscribe(pid, execution, extra \\ %{}) do
    call(pid, {:handle, "worker_output_subscribe", Map.merge(%{"execution" => execution}, extra)})
  end

  defp next(pid, token, cursor \\ "cursor-1") do
    call(pid, {:handle, "worker_output_next", %{"subscription" => token, "cursor" => cursor}})
  end

  defp unsubscribe(pid, token) do
    call(pid, {:handle, "worker_output_unsubscribe", %{"subscription" => token}})
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("output owners did not reconcile")

      true ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end

  test "snapshot and next use the real addressed Bus and preserve exact execution", c do
    runtime(c.execution)
    owner = viewer(c.view)
    assert {:ok, snapshot, state} = subscribe(owner, c.execution)
    token = snapshot["subscription"]
    assert is_binary(token) and byte_size(token) > 20
    assert state.execution == c.execution
    assert snapshot["stream"] == stream(c.execution)
    assert snapshot["cursor"] == "cursor-1"
    assert snapshot["view"]["output"] == %{"available" => true, "replay" => true}
    assert snapshot["view"]["guidance"] == c.view["guidance"]
    assert_receive {:authorized, ^owner, execution}
    assert execution == c.execution
    assert_receive {:runtime_request, :runtime_output_snapshot, envelope, request}
    assert envelope.address == "runtime@" <> c.execution["worker"]["machine"] <> "/output"
    assert String.starts_with?(envelope.sender, "control/")
    assert envelope.position == nil
    assert request["id"] == envelope.id
    assert request["execution"] == c.execution
    refute Map.has_key?(request, "cursor")
    refute Map.has_key?(snapshot, "id")
    refute Map.has_key?(snapshot, "channel")

    assert {:ok, batch, ^state} = next(owner, token)
    assert batch["subscription"] == token
    assert batch["cursor"] == "cursor-2"
    assert batch["events"] == [%{"sequence" => 1, "kind" => "text", "text" => "hello"}]
    refute batch["more"]
    refute Map.has_key?(batch, "view")
    assert_receive {:authorized, ^owner, ^execution}
    assert_receive {:runtime_request, :runtime_output_read, _, read}
    assert read["execution"] == c.execution
    assert read["cursor"] == "cursor-1"
  end

  test "tokens belong to one connection and unsubscribe is idempotent without stopping Runtime",
       c do
    runtime(c.execution)
    first = viewer(c.view)
    second = viewer(c.view)
    assert {:ok, a, first_state} = subscribe(first, c.execution)
    assert {:ok, b, second_state} = subscribe(second, c.execution)
    refute a["subscription"] == b["subscription"]
    assert {:error, "invalid_subscription", %{}, ^second_state} = next(second, a["subscription"])

    assert {:error, "invalid_subscription", %{}, ^first_state} =
             unsubscribe(first, b["subscription"])

    assert {:error, "subscription_exists", %{}, ^first_state} = subscribe(first, c.execution)
    assert {:ok, %{"subscription" => token}, closed} = unsubscribe(first, a["subscription"])
    assert token == a["subscription"]
    assert closed.closed
    assert {:ok, %{"subscription" => ^token}, ^closed} = unsubscribe(first, token)
    assert {:error, "invalid_subscription", %{}, ^closed} = next(first, token)
    assert {:ok, _, ^second_state} = next(second, b["subscription"])
    assert {:ok, resumed, resumed_state} = subscribe(first, c.execution)
    refute resumed["subscription"] == token
    assert {:ok, %{"subscription" => ^token}, ^resumed_state} = unsubscribe(first, token)
    assert {:ok, _, ^resumed_state} = next(first, resumed["subscription"])
  end

  test "authorization precedes every snapshot and read; revocation returns no view", c do
    runtime(c.execution)
    owner = viewer(c.view)
    assert :ok = call(owner, {:authorize, {:error, "forbidden"}})
    assert {:error, "forbidden", %{}, nil} = subscribe(owner, c.execution)
    refute_receive {:runtime_request, _, _, _}, 20
    assert :ok = call(owner, {:authorize, {:ok, %{"view" => c.view}}})
    assert {:ok, snapshot, state} = subscribe(owner, c.execution)
    assert_receive {:runtime_request, :runtime_output_snapshot, _, _}
    assert :ok = call(owner, {:authorize, {:error, "forbidden"}})
    assert {:error, "forbidden", %{}, ^state} = next(owner, snapshot["subscription"])
    refute_receive {:runtime_request, :runtime_output_read, _, _}, 20
  end

  test "a reset returns the newly authorized view without replacing the execution", c do
    reset = %{"reason" => "retention_gap", "from_sequence" => 1, "to_sequence" => 3}

    runtime(c.execution, fn envelope, operation, request ->
      props = result(operation, request)

      props =
        if operation == :runtime_output_read, do: Map.put(props, "reset", reset), else: props

      reply(envelope, operation, props)
    end)

    owner = viewer(c.view)
    assert {:ok, snapshot, state} = subscribe(owner, c.execution)
    fresh = Map.put(c.view, "state", "done")
    assert :ok = call(owner, {:authorize, {:ok, %{"view" => fresh}}})
    assert {:ok, batch, ^state} = next(owner, snapshot["subscription"])
    assert batch["reset"] == reset
    assert batch["view"] == Map.put(fresh, "output", %{"available" => true, "replay" => true})
    assert batch["stream"]["execution"] == c.execution
  end

  test "missing ring returns authorized view and explicit reset without inventing a stream", c do
    runtime(c.execution, fn envelope, operation, _ ->
      error(envelope, operation, "output_unavailable")
    end)

    owner = viewer(c.view)
    assert {:error, "output_unavailable", details, nil} = subscribe(owner, c.execution)
    assert details["reset"] == %{"reason" => "output_unavailable"}
    assert details["view"]["execution"] == c.execution
    assert details["view"]["guidance"] == c.view["guidance"]

    assert details["view"]["output"] == %{
             "available" => false,
             "replay" => false,
             "reason" => "output_unavailable"
           }

    refute Map.has_key?(details, "stream")
    refute Map.has_key?(details, "cursor")
    refute Map.has_key?(:sys.get_state(Output), owner)
  end

  test "ring disappearance during next keeps the exact subscription and refreshes its view", c do
    runtime(c.execution, fn envelope, operation, request ->
      if operation == :runtime_output_snapshot,
        do: reply(envelope, operation, result(operation, request)),
        else: error(envelope, operation, "output_unavailable")
    end)

    owner = viewer(c.view)
    assert {:ok, snapshot, state} = subscribe(owner, c.execution)
    fresh = Map.put(c.view, "state", "done")
    assert :ok = call(owner, {:authorize, {:ok, %{"view" => fresh}}})
    assert {:error, "output_unavailable", details, ^state} = next(owner, snapshot["subscription"])
    assert details["view"]["state"] == "done"
    assert details["view"]["execution"] == c.execution
    assert details["reset"] == %{"reason" => "output_unavailable"}
    refute Map.has_key?(details, "stream")
  end

  test "invalid cursors pass through unchanged and never become a reset or retarget", c do
    runtime(c.execution, fn envelope, operation, request ->
      if request["cursor"] == "wrong-scope",
        do: error(envelope, operation, "invalid_cursor"),
        else: reply(envelope, operation, result(operation, request))
    end)

    owner = viewer(c.view)

    assert {:error, "invalid_cursor", %{}, nil} =
             subscribe(owner, c.execution, %{"cursor" => "wrong-scope"})

    assert_receive {:runtime_request, :runtime_output_snapshot, _, invalid}
    assert invalid["cursor"] == "wrong-scope"
    assert invalid["execution"] == c.execution
    assert {:ok, snapshot, state} = subscribe(owner, c.execution)

    assert {:error, "invalid_cursor", %{}, ^state} =
             next(owner, snapshot["subscription"], "wrong-scope")

    assert_receive {:runtime_request, :runtime_output_read, _, invalid_read}
    assert invalid_read["cursor"] == "wrong-scope"
    assert invalid_read["execution"] == c.execution
  end

  test "wrong Bus ID and Runtime sender cannot satisfy a pending request", c do
    impostor =
      process(fn parent ->
        :ok = AtlasBus.attach("runtime@impostor/output")
        send(parent, {:ready, self()})

        receive do
          {:forge, envelope, payload, runtime} ->
            :ok = AtlasBus.send(envelope, payload)
            send(runtime, :forged)
        end
      end)

    runtime(c.execution, fn envelope, operation, request ->
      payload =
        Wire.reply(operation, :result, Map.put(result(operation, request), "cursor", "forged"))

      answer = Envelope.reply(envelope, "answer")
      send(impostor, {:forge, answer, payload, self()})
      receive do: (:forged -> :ok)
      :ok = AtlasBus.send(%{answer | id: "another-request"}, payload)
      reply(envelope, operation, result(operation, request))
    end)

    owner = viewer(c.view)
    assert {:ok, snapshot, _} = subscribe(owner, c.execution)
    assert snapshot["cursor"] == "cursor-1"
  end

  test "matching Bus envelope still requires typed payload ID and exact execution", c do
    runtime(c.execution, fn envelope, operation, request ->
      props = result(operation, request)

      props =
        case request["cursor"] do
          "wrong-id" -> Map.put(props, "id", "another-request")
          "wrong-execution" -> put_in(props, ["stream", "execution", "attempt"], "successor")
        end

      reply(envelope, operation, props)
    end)

    owner = viewer(c.view)

    for cursor <- ["wrong-id", "wrong-execution"] do
      assert {:error, "invalid_output_reply", %{}, nil} =
               subscribe(owner, c.execution, %{"cursor" => cursor})

      refute Map.has_key?(:sys.get_state(Output), owner)
    end
  end

  test "global admission is bounded, repeated acquire is free, and owner death releases capacity",
       c do
    owners = for _ <- 1..128, do: viewer(c.view)
    for owner <- owners, do: assert(:ok == call(owner, :acquire))
    assert :ok = call(hd(owners), :acquire)
    assert map_size(:sys.get_state(Output)) == 128
    extra = viewer(c.view)
    assert {:error, "viewer_limit", %{}, nil} = subscribe(extra, c.execution)
    refute_receive {:runtime_request, _, _, _}, 20
    Process.unlink(hd(owners))
    Process.exit(hd(owners), :kill)
    eventually(fn -> map_size(:sys.get_state(Output)) == 127 end)
    runtime(c.execution)
    assert {:ok, snapshot, _} = subscribe(extra, c.execution)
    assert map_size(:sys.get_state(Output)) == 128
    assert {:ok, _, _} = unsubscribe(extra, snapshot["subscription"])
    assert map_size(:sys.get_state(Output)) == 127
  end
end

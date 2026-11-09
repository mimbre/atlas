defmodule AtlasRuntime.OutputEndpointTest do
  use ExUnit.Case, async: true

  alias AtlasBFFContract.Wire.Runtime.OutputProtocol, as: Wire
  alias AtlasBus.Envelope
  alias AtlasRuntime.{Output, OutputEndpoint}

  setup do
    id = System.unique_integer([:positive])
    machine = "output-endpoint-#{id}"
    client = "control/output-test-#{id}"
    :ok = AtlasBus.attach(client)
    output = start_supervised!({Output, name: nil})
    endpoint = start_supervised!({OutputEndpoint, machine: machine, output: output})

    execution = %{
      "worker" => %{
        "environment" => AtlasBus.environment(),
        "machine" => machine,
        "worker" => "worker"
      },
      "turn" => "turn",
      "attempt" => "attempt"
    }

    :ok = Output.open(execution, self(), output)
    :ok = Output.append(execution, %{"kind" => "text", "text" => "public answer"}, output)

    envelope = %{
      Envelope.new("request", "runtime.output")
      | sender: client,
        address: "runtime@#{machine}/output"
    }

    %{endpoint: endpoint, output: output, execution: execution, envelope: envelope}
  end

  # Injection isolates this endpoint's validation from the separately owned Bus request router.
  # Replies still traverse the real Bus, including its authoritative sender stamping.
  test "output cannot be disclosed through a foreign machine or mismatched request ID", context do
    request =
      Wire.request(:runtime_output_snapshot, %{
        id: context.envelope.id,
        execution: context.execution
      })

    for bad <- [
          put_in(request, ["execution", "worker", "machine"], "somewhere-else"),
          Map.put(request, "id", "another-request")
        ] do
      send(context.endpoint, {:atlas_bus, context.envelope, bad})
      assert_receive {:atlas_bus, %Envelope{class: "answer", sender: sender, id: id}, reply}
      assert sender == context.envelope.address
      assert id == context.envelope.id

      assert {:ok, :error, %{"error" => %{"code" => "invalid_request"}}} =
               Wire.decode_reply(:runtime_output_snapshot, reply)

      refute Map.has_key?(reply, "stream")
    end
  end

  test "a Runtime sender cannot invoke the Control-only output endpoint", context do
    request =
      Wire.request(:runtime_output_snapshot, %{
        id: context.envelope.id,
        execution: context.execution
      })

    sender = "runtime@#{context.envelope.id}/output"
    parent = self()

    viewer =
      Task.async(fn ->
        :ok = AtlasBus.attach(sender)
        send(parent, :runtime_sender_attached)

        receive do
          {:atlas_bus, _, _} = reply -> reply
          :finish -> :no_reply
        end
      end)

    assert_receive :runtime_sender_attached
    envelope = %{context.envelope | sender: sender}
    send(context.endpoint, {:atlas_bus, envelope, request})
    :sys.get_state(context.endpoint)
    send(viewer.pid, :finish)
    assert Task.await(viewer) == :no_reply
  end

  test "retained output is readable after producer closure without reopening execution",
       context do
    :ok = Output.finish(context.execution, context.output)
    {:ok, snapshot} = Output.snapshot(context.execution, nil, context.output)

    request =
      Wire.request(:runtime_output_read, %{
        id: context.envelope.id,
        execution: context.execution,
        cursor: snapshot["cursor"]
      })

    send(context.endpoint, {:atlas_bus, context.envelope, request})
    assert_receive {:atlas_bus, %Envelope{class: "answer"}, reply}

    assert {:ok, :result,
            %{
              "events" => [%{"text" => "public answer", "sequence" => 1}],
              "stream" => %{"ended" => true}
            }} =
             Wire.decode_reply(:runtime_output_read, reply)

    assert {:error, "output_ended"} =
             Output.append(
               context.execution,
               %{"kind" => "text", "text" => "late"},
               context.output
             )
  end
end

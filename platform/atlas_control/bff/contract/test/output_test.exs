defmodule AtlasBFFContract.OutputTest do
  use ExUnit.Case, async: true

  alias AtlasBFFContract.Wire.Runtime.OutputProtocol, as: RuntimeWire
  alias AtlasBFFContract.Wire.Control.Workers.Protocol, as: WorkerWire

  @execution %{
    "worker" => %{"environment" => "private", "machine" => "local", "worker" => "worker"},
    "turn" => "turn",
    "attempt" => "attempt"
  }
  @stream %{
    "execution" => @execution,
    "epoch" => "epoch",
    "first_sequence" => 1,
    "watermark" => 1,
    "ended" => false
  }

  test "output replies reject unprojected native payloads at both transport boundaries" do
    for {wire, operation, extra} <- [
          {RuntimeWire, :runtime_output_read, %{}},
          {WorkerWire, :worker_output_next, %{"subscription" => "viewer"}}
        ] do
      reply =
        wire.reply(
          operation,
          :result,
          Map.merge(extra, %{
            "id" => "request",
            "stream" => @stream,
            "events" => [%{"sequence" => 1, "kind" => "text", "text" => "public answer"}],
            "cursor" => "opaque",
            "more" => false
          })
        )

      for private_field <- ~w(reasoning input arguments environment raw) do
        [event] = reply["events"]
        bad = Map.put(reply, "events", [Map.put(event, private_field, "private payload")])
        assert {:invalid, _} = wire.decode_reply(operation, bad)
      end
    end
  end

  test "output requests reject durable numeric Facts positions as cursors" do
    for {wire, operation, fields} <- [
          {RuntimeWire, :runtime_output_read, %{execution: @execution}},
          {WorkerWire, :worker_output_next, %{subscription: "viewer"}}
        ] do
      request = wire.request(operation, Map.merge(fields, %{id: "request", cursor: "opaque"}))
      assert {:invalid, _} = wire.decode_request(Map.put(request, "cursor", 42))
    end
  end
end

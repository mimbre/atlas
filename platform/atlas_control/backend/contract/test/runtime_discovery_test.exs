defmodule AtlasBFFContract.RuntimeDiscoveryTest do
  use ExUnit.Case, async: true
  alias AtlasBFFContract.Wire.Control.DiscoveryProtocol, as: Wire

  test "literal discovery command, exact machine identity and typed replies round trip" do
    target = %{"environment" => "test", "machine" => "synthetic"}

    assert {:ok, :runtime_machine_discover, request} =
             Wire.cli(["discover"], id: "r", target: target, grant: "private")

    assert {:ok, :runtime_machine_discover, ^request} =
             Wire.decode_request_json(JSON.encode!(request))

    assert {:invalid, _} = AtlasBFFContract.Wire.Runtime.MachineProtocol.decode_request(request)
    assert {:invalid, _} = AtlasBFFContract.Wire.Runtime.Protocol.decode_request(request)

    assert {:ok, %{"machine" => "synthetic"}} =
             Wire.options(:runtime_discovery_options, ["--machine", "synthetic"])

    assert {:invalid, _} = Wire.options(:runtime_discovery_options, [])

    for bad <- [
          Map.put(request, "as", "synthetic"),
          put_in(request, ["target"], []),
          Map.put(request, "version", "future")
        ] do
      assert {:invalid, _} = Wire.decode_request(bad)
    end

    bytes =
      Wire.reply(:runtime_machine_discover, :result,
        id: "r",
        target: target,
        availability: %{target: target, registered: false, basis: "bus_endpoint_registry"}
      )
      |> JSON.encode!()

    assert {:ok, :result, %{"availability" => %{"registered" => false}}} =
             Wire.decode_reply_json(:runtime_machine_discover, bytes)

    error =
      Wire.reply(:runtime_machine_discover, :error,
        id: "r",
        target: target,
        error: %{code: "unauthorized", message: "refused", retryable: false}
      )

    refute Map.has_key?(error, "grant")

    assert {:ok, :error, ^error} =
             Wire.decode_reply_json(:runtime_machine_discover, JSON.encode!(error))
  end
end

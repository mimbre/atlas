defmodule AtlasBFFContract.RuntimeMachineTest do
  use ExUnit.Case, async: true
  alias AtlasBFFContract.Wire.Runtime.MachineProtocol, as: Wire

  test "machine diagnostics never invent or weaken a worker identity" do
    target = %{"environment" => "test", "machine" => "fixture"}
    assert {:ok, :runtime_machine_status, request} = Wire.cli(["status"], id: "r", target: target)

    assert {:ok, :runtime_machine_status, ^request} =
             Wire.decode_request_json(JSON.encode!(request))

    assert {:invalid, _} = AtlasBFFContract.Wire.Runtime.Protocol.decode_request(request)
    assert {:invalid, _} = Wire.decode_request(put_in(request, ["target", "worker"], "invented"))

    for {command, operation} <- [
          {"start", :runtime_machine_start},
          {"stop", :runtime_machine_stop}
        ] do
      assert {:ok, ^operation, frame} = Wire.cli([command], id: "r", target: target)
      assert {:ok, ^operation, ^frame} = Wire.decode_request_json(JSON.encode!(frame))
      assert {:invalid, _} = AtlasBFFContract.Wire.Runtime.Protocol.decode_request(frame)

      bytes =
        Wire.encode_reply(operation, :error,
          id: "r",
          target: target,
          error: %{code: "ownership_refused", message: "unproven", retryable: false}
        )

      assert {:ok, :error, %{"target" => ^target}} = Wire.decode_reply_json(operation, bytes)
    end

    assert_raise ArgumentError, fn ->
      AtlasBFFContract.Wire.Runtime.Protocol.request(:runtime_status, id: "r", target: target)
    end

    status = %{
      target: target,
      state: "unverified",
      basis: "pid_only_legacy",
      message: "ownership unknown",
      pid: 123,
      capabilities: %{
        local_status: true,
        local_start: false,
        local_stop: false,
        remote_status: false
      }
    }

    bytes =
      Wire.encode_reply(:runtime_machine_status, :result, id: "r", target: target, status: status)

    assert {:ok, :result, %{"status" => %{"target" => ^target}}} =
             Wire.decode_reply_json(:runtime_machine_status, bytes)

    assert {:ok, %{"machine" => "fixture", "json" => true}} =
             Wire.options(:runtime_machine_status_options, ["--machine", "fixture", "--json"])

    assert {:invalid, _} =
             Wire.options(:runtime_machine_status_options, [
               "--machine",
               "fixture",
               "--machine",
               "other"
             ])
  end

  test "managed boot options and acknowledgement preserve exact instance and machine scope" do
    argv = [
      "--environment",
      "test",
      "--machine",
      "fixture",
      "--configuration",
      "/private/runtime.json",
      "--directory",
      "/private/instance",
      "--instance",
      "nonce"
    ]

    assert {:ok, boot} = Wire.options(:runtime_machine_boot, argv)
    assert boot["directory"] == "/private/instance"
    assert {:invalid, _} = Wire.options(:runtime_machine_boot, argv ++ ["--instance", "other"])
    assert {:invalid, _} = Wire.options(:runtime_machine_boot, ["--machine", "fixture"])

    receipt =
      Wire.model(:runtime_machine_boot_receipt,
        target: %{environment: "test", machine: "fixture"},
        instance: "nonce",
        pid: 123
      )

    assert receipt["target"] == %{"environment" => "test", "machine" => "fixture"}
    assert receipt["instance"] == "nonce"

    assert_raise ArgumentError, fn ->
      Wire.model(:runtime_machine_boot_receipt, target: [], instance: "nonce", pid: 123)
    end
  end
end

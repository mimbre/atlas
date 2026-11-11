defmodule AtlasRuntimeStatusCLI do
  @moduledoc false
  alias AtlasBFFContract.Wire.Runtime.MachineProtocol, as: Wire

  def run([root, environment, settings, "--operation", command, client | argv]) do
    execute(root, environment, settings, client, command, argv)
  end

  def run([root, environment, settings | argv]),
    do: execute(root, environment, settings, "unused", "status", argv)

  defp execute(root, environment, settings, client, command, argv) do
    id = Integer.to_string(System.unique_integer([:positive]))

    operation =
      Enum.find_value(Wire.commands(), :runtime_machine_status, fn %{name: name, words: words} ->
        if words == [command], do: name
      end)

    case Wire.options(:runtime_machine_status_options, argv) do
      {:invalid, why} ->
        error(id, environment, "invalid_options", why, "--json" in argv, operation)

      {:ok, options} ->
        machine = options["machine"] || configured_machine(settings)

        if is_binary(machine) and machine != "" do
          target = %{environment: environment, machine: machine}

          case Wire.cli([command], %{id: id, target: target}) do
            {:ok, operation, request} ->
              observe(root, client, environment, operation, request, options["json"] == true)

            {:invalid, _} ->
              error(
                id,
                environment,
                "unsupported",
                "operation is not in the built Runtime contract",
                options["json"] == true
              )
          end
        else
          error(
            id,
            environment,
            "machine_required",
            "machine identity unknown; supply --machine or a matching Runtime configuration",
            options["json"] == true,
            operation
          )
        end
    end
  end

  defp configured_machine(settings) do
    with {:ok, bytes} <- File.read(settings),
         {:ok, %{"runtime" => %{"machine" => machine}}} when is_binary(machine) <-
           JSON.decode(bytes),
         do: machine,
         else: (_ -> nil)
  end

  defp observe(root, client, environment, operation, request, json?) do
    {bytes, code} =
      System.cmd(
        System.find_executable("python3"),
        [
          Path.join(root, "tools/runtime.py"),
          if(operation == :runtime_machine_status,
            do: "_runtime-status-observe",
            else: "_runtime-machine-operate"
          ),
          root,
          client,
          environment,
          JSON.encode!(request)
        ],
        stderr_to_stdout: true,
        env: [{"ATLAS_RUNTIME_READ_TOKEN", nil}]
      )

    if code == 0 do
      with {:ok, %{} = status} <- JSON.decode(bytes),
           :ok <- validate_status(status),
           true <- status["target"] == request["target"] do
        if operation != :runtime_machine_status and status["state"] not in ["owned", "stopped"] do
          reply =
            Wire.reply(operation, :error, %{
              id: request["id"],
              target: request["target"],
              error: %{code: status["basis"], message: status["message"], retryable: false}
            })

          if json?,
            do: IO.puts(JSON.encode!(reply)),
            else: IO.puts(:stderr, "Runtime #{environment}: refused; #{status["message"]}")

          System.halt(2)
        end

        reply =
          Wire.reply(operation, :result, %{
            id: request["id"],
            target: request["target"],
            status: status
          })

        pid = if status["pid"], do: ", pid #{status["pid"]}", else: ""

        if json?,
          do: IO.puts(JSON.encode!(reply)),
          else:
            IO.puts(
              "Runtime #{environment}: #{status["state"]} (machine #{status["target"]["machine"]}#{pid}); #{status["message"]}; log #{status["log"]}"
            )
      else
        _ ->
          error(
            request["id"],
            environment,
            "invalid_diagnostic",
            "local status handler returned malformed or mismatched diagnostics",
            json?,
            operation,
            request["target"]
          )
      end
    else
      error(
        request["id"],
        environment,
        "diagnostic_unavailable",
        "local handler unavailable; lifecycle outcome unconfirmed, inspect retained records",
        json?,
        operation,
        request["target"]
      )
    end
  end

  defp validate_status(status) do
    AtlasBFF.Targets.Protocol.validate_value!(Wire.models(), :runtime_machine_status, status)
  rescue
    ArgumentError -> :invalid
  end

  defp error(
         id,
         environment,
         code,
         message,
         json?,
         operation \\ :runtime_machine_status,
         target \\ nil
       ) do
    reply =
      Wire.reply(operation, :error, %{
        id: id,
        target: target,
        error: %{code: code, message: message, retryable: false}
      })

    if json?,
      do: IO.puts(JSON.encode!(reply)),
      else: IO.puts(:stderr, "Runtime #{environment}: unsupported; #{message}")

    System.halt(2)
  end
end

AtlasRuntimeStatusCLI.run(System.argv())

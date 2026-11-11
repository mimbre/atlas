# Runtime nodes start only their own layer and its Bus dependency, never the core apps.
Mix.Task.run("app.config")
# IS136 boot ownership is optional for old direct invocations, mandatory for the
# managed CLI. All managed arguments and the receipt use the shared DSL.
arguments = System.argv()

boot =
  if arguments == [] do
    nil
  else
    {:ok, value} =
      AtlasBFFContract.Wire.Runtime.MachineProtocol.options(:runtime_machine_boot, arguments)

    unless value["environment"] == System.get_env("ATLAS_ENV") and
             value["machine"] == AtlasRuntime.Settings.get()[:machine] and
             value["configuration"] == System.get_env("ATLAS_ENV_FILE") and
             value["directory"] == System.get_env("ATLAS_RUNTIME_HOME") and
             value["instance"] == System.get_env("ATLAS_RUNTIME_INSTANCE"),
           do: raise("Runtime boot identity mismatch")

    value
  end

{:ok, _} = Application.ensure_all_started(:atlas_runtime)

started = Enum.map(Application.started_applications(), &elem(&1, 0))

if Enum.any?([:atlas_state, :atlas_flow, :atlas_control], &(&1 in started)),
  do: raise("a Runtime node must not start core layers")

IO.puts("Runtime node ready: #{inspect(AtlasBus.endpoints())}; core layers remain stopped")

if boot do
  receipt =
    AtlasBFFContract.Wire.Runtime.MachineProtocol.model(:runtime_machine_boot_receipt, %{
      target: %{environment: boot["environment"], machine: boot["machine"]},
      instance: boot["instance"],
      pid: String.to_integer(System.pid())
    })

  path = Path.join(boot["directory"], "runtime-ready-#{boot["instance"]}.json")
  File.write!(path <> ".pending", JSON.encode!(receipt))
  File.chmod!(path <> ".pending", 0o600)
  File.rename!(path <> ".pending", path)
end

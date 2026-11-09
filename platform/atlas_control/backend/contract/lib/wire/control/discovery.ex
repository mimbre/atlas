defmodule AtlasBFFContract.Wire.Control.Discovery do
  @moduledoc "Exact-machine discovery over Control, separate from Runtime lifecycle operations."
  use AtlasBFF.Schema
  version "0.1.0"
  models_from(AtlasBFFContract.Models.Runtime)

  @wire_version "0.1.0"

  defoperation :runtime_machine_discover, %{
    channel: :control,
    direction: :request,
    cli: ["discover"],
    request: %{
      select: %{"op" => "machine_discover", "channel" => "control", "version" => @wire_version},
      required: %{"id" => :string, "target" => :runtime_machine},
      optional: %{"grant" => :string}
    },
    replies: [
      %{
        name: :result,
        effect: :complete,
        select: %{
          "op" => "machine_discover_result",
          "channel" => "control",
          "version" => @wire_version
        },
        required: %{
          "id" => :string,
          "target" => :runtime_machine,
          "availability" => :runtime_machine_availability
        }
      },
      %{
        name: :error,
        effect: :error,
        select: %{
          "op" => "machine_discover_error",
          "channel" => "control",
          "version" => @wire_version
        },
        required: %{"id" => :string, "error" => :runtime_error},
        optional: %{"target" => :runtime_machine}
      }
    ]
  }
end

defmodule AtlasBFFContract.Wire.Control.DiscoveryProtocol do
  @moduledoc "Generated exact-machine read capability over the existing Control protocol."
  use AtlasBFF.Targets.Protocol,
    contract: AtlasBFFContract.Wire.Control.Discovery,
    channel: :control
end

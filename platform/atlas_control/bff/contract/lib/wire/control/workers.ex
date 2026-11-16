defmodule AtlasBFFContract.Wire.Control.Workers do
  @moduledoc "Worker reads, durable guidance and bounded ephemeral output; no lifecycle controls."
  use AtlasBFF.Schema
  version "0.1.0"
  models_from(AtlasBFFContract.Models.Workers)

  worker_operation = fn name, required, optional, result, result_optional, error_optional ->
    %{
      channel: :control,
      direction: :request,
      request: %{
        select: %{"op" => Atom.to_string(name), "channel" => "control", "version" => "0.1.0"},
        required: Map.put(required, "id", :string),
        optional: optional
      },
      replies: [
        %{
          name: :result,
          effect: :complete,
          select: %{
            "op" => Atom.to_string(name) <> "_result",
            "channel" => "control",
            "version" => "0.1.0"
          },
          required: Map.put(result, "id", :string),
          optional: result_optional
        },
        %{
          name: :error,
          effect: :error,
          select: %{
            "op" => Atom.to_string(name) <> "_error",
            "channel" => "control",
            "version" => "0.1.0"
          },
          required: %{"id" => :string, "error" => :runtime_error},
          optional: error_optional
        }
      ]
    }
  end

  defoperation :worker_overview,
               worker_operation.(
                 :worker_overview,
                 %{},
                 %{},
                 %{"workers" => {:list, :worker_view}, "confirmed_at" => :string},
                 %{},
                 %{}
               )

  defoperation :worker_inspect,
               worker_operation.(
                 :worker_inspect,
                 %{"execution" => :runtime_execution},
                 %{},
                 %{"view" => :worker_view},
                 %{},
                 %{}
               )

  defoperation :worker_submit,
               worker_operation.(
                 :worker_submit,
                 %{"execution" => :runtime_execution, "guidance" => :worker_guidance_input},
                 %{},
                 %{"interaction" => :worker_interaction},
                 %{},
                 %{}
               )

  defoperation :worker_query,
               worker_operation.(
                 :worker_query,
                 %{"execution" => :runtime_execution, "client_key" => :string},
                 %{},
                 %{"found" => :boolean},
                 %{"interaction" => :worker_interaction},
                 %{}
               )

  defoperation :worker_history,
               worker_operation.(
                 :worker_history,
                 %{"execution" => :runtime_execution},
                 %{"cursor" => :string},
                 %{
                   "interactions" => {:list, :worker_interaction},
                   "cursor" => :string,
                   "more" => :boolean
                 },
                 %{},
                 %{}
               )

  defoperation :worker_receipts,
               worker_operation.(
                 :worker_receipts,
                 %{"execution" => :runtime_execution, "interaction" => :string},
                 %{"cursor" => :string},
                 %{
                   "receipts" => {:list, :worker_receipt},
                   "cursor" => :string,
                   "more" => :boolean
                 },
                 %{},
                 %{}
               )

  defoperation :worker_output_subscribe,
               worker_operation.(
                 :worker_output_subscribe,
                 %{"execution" => :runtime_execution},
                 %{"cursor" => :string},
                 %{
                   "subscription" => :string,
                   "view" => :worker_view,
                   "stream" => :runtime_output_stream,
                   "cursor" => :string
                 },
                 %{"reset" => :runtime_output_reset},
                 %{"view" => :worker_view, "reset" => :runtime_output_reset}
               )

  defoperation :worker_output_next,
               worker_operation.(
                 :worker_output_next,
                 %{"subscription" => :string, "cursor" => :string},
                 %{},
                 %{
                   "subscription" => :string,
                   "stream" => :runtime_output_stream,
                   "events" => {:list, :runtime_output_event},
                   "cursor" => :string,
                   "more" => :boolean
                 },
                 %{"reset" => :runtime_output_reset, "view" => :worker_view},
                 %{"view" => :worker_view, "reset" => :runtime_output_reset}
               )

  defoperation :worker_output_unsubscribe,
               worker_operation.(
                 :worker_output_unsubscribe,
                 %{"subscription" => :string},
                 %{},
                 %{"subscription" => :string},
                 %{},
                 %{"view" => :worker_view, "reset" => :runtime_output_reset}
               )
end

defmodule AtlasBFFContract.Wire.Control.Workers.Protocol do
  use AtlasBFF.Targets.Protocol,
    contract: AtlasBFFContract.Wire.Control.Workers,
    channel: :control
end

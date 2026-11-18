defmodule AtlasBFFContract.Wire.Runtime do
  @moduledoc "Runtime worker, machine, attachment and ephemeral output wire operations."
  use AtlasBFF.Schema
  version "0.1.0"
  models_from(AtlasBFFContract.Models.Runtime)

  @wire_version "0.1.0"

  machine_operation = fn action ->
    %{
      channel: :runtime_machine,
      direction: :request,
      cli: [Atom.to_string(action)],
      request: %{
        select: %{
          "op" => "machine_#{action}",
          "channel" => "control",
          "version" => @wire_version
        },
        required: %{"id" => :string, "target" => :runtime_machine}
      },
      replies: [
        %{
          name: :result,
          select: %{
            "op" => "machine_#{action}_result",
            "channel" => "control",
            "version" => @wire_version
          },
          required: %{
            "id" => :string,
            "target" => :runtime_machine,
            "status" => :runtime_machine_status
          },
          effect: :complete
        },
        %{
          name: :error,
          select: %{
            "op" => "machine_#{action}_error",
            "channel" => "control",
            "version" => @wire_version
          },
          required: %{"id" => :string, "error" => :runtime_error},
          optional: %{"target" => :runtime_machine},
          effect: :error
        }
      ]
    }
  end

  defoperation :runtime_machine_start, machine_operation.(:start)
  defoperation :runtime_machine_stop, machine_operation.(:stop)
  defoperation :runtime_machine_status, machine_operation.(:status)

  @attachment_fields %{
    "target" => :runtime_worker,
    "execution" => :runtime_execution,
    "capabilities" => :runtime_attachment_capabilities,
    "turn" => :runtime_turn
  }

  attachment_operation = fn action ->
    %{
      channel: :runtime_attachment,
      direction: :request,
      cli: [Atom.to_string(action)],
      request: %{
        select: %{
          "op" => "execution_#{action}",
          "channel" => "control",
          "version" => @wire_version
        },
        required: %{
          "id" => :string,
          "target" => :runtime_worker,
          "execution" => :runtime_execution
        }
      },
      replies: [
        %{
          name: :result,
          effect: :complete,
          select: %{
            "op" => "execution_result",
            "channel" => "control",
            "version" => @wire_version
          },
          required: Map.put(@attachment_fields, "id", :string)
        },
        %{
          name: :error,
          effect: :error,
          select: %{
            "op" => "execution_error",
            "channel" => "control",
            "version" => @wire_version
          },
          required: %{
            "id" => :string,
            "target" => :runtime_worker,
            "execution" => :runtime_execution,
            "error" => :runtime_error
          }
        }
      ]
    }
  end

  defoperation :execution_attach, attachment_operation.(:attach)
  defoperation :execution_status, attachment_operation.(:status)
  defoperation :execution_detach, attachment_operation.(:detach)

  defoperation :execution_snapshot, %{
    channel: :runtime_attachment,
    direction: :push,
    replies: [
      %{
        name: :status,
        effect: :progress,
        select: %{
          "op" => "execution_snapshot",
          "channel" => "event",
          "version" => @wire_version
        },
        required: Map.put(@attachment_fields, "sequence", :integer)
      }
    ]
  }

  defoperation :execution_closed, %{
    channel: :runtime_attachment,
    direction: :push,
    replies: [
      %{
        name: :closed,
        effect: :progress,
        select: %{
          "op" => "execution_closed",
          "channel" => "event",
          "version" => @wire_version
        },
        required: %{
          "sequence" => :integer,
          "target" => :runtime_worker,
          "execution" => :runtime_execution,
          "error" => :runtime_error
        }
      }
    ]
  }

  @result %{
    name: :result,
    select: %{"op" => "result", "channel" => "control", "version" => @wire_version},
    required: %{"id" => :string, "target" => :runtime_worker, "status" => :runtime_status},
    effect: :complete
  }
  @error %{
    name: :error,
    select: %{"op" => "error", "channel" => "control", "version" => @wire_version},
    required: %{"id" => :string, "error" => :runtime_error},
    optional: %{"target" => :runtime_worker},
    effect: :error
  }

  runtime_operation = fn op, words, literals ->
    %{
      channel: :runtime,
      direction: :request,
      cli: words,
      request: %{
        select:
          Map.merge(%{"op" => op, "channel" => "control", "version" => @wire_version}, literals),
        required: %{"id" => :string, "target" => :runtime_worker}
      },
      replies: [@result, @error]
    }
  end

  defoperation :runtime_status, runtime_operation.("status", ["status"], %{})
  defoperation :runtime_start, runtime_operation.("start", ["start"], %{})
  defoperation :runtime_stop, runtime_operation.("stop", ["stop"], %{})
  defoperation :runtime_attach, runtime_operation.("attach", ["attach"], %{})
  defoperation :runtime_detach, runtime_operation.("detach", ["detach"], %{})

  defoperation :runtime_active,
               runtime_operation.("stub_mode", ["mode", "active"], %{"mode" => "active"})

  defoperation :runtime_idle,
               runtime_operation.("stub_mode", ["mode", "idle"], %{"mode" => "idle"})

  defoperation :runtime_silent,
               runtime_operation.("stub_mode", ["mode", "silent"], %{"mode" => "silent"})

  defoperation :runtime_crash_once,
               runtime_operation.("stub_mode", ["mode", "crash-once"], %{"mode" => "crash once"})

  defoperation :runtime_crash,
               runtime_operation.("stub_mode", ["mode", "crash"], %{"mode" => "crash"})

  defoperation :runtime_status_event, %{
    channel: :runtime,
    direction: :push,
    replies: [
      %{
        name: :status,
        select: %{"op" => "status", "channel" => "event", "version" => @wire_version},
        required: %{
          "sequence" => :integer,
          "target" => :runtime_worker,
          "status" => :runtime_status
        },
        effect: :progress
      }
    ]
  }

  output_operation = fn name, required, optional, result ->
    %{
      channel: :runtime_output,
      direction: :request,
      request: %{
        select: %{
          "op" => Atom.to_string(name),
          "channel" => "runtime_output",
          "version" => @wire_version
        },
        required: Map.merge(required, %{"id" => :string, "execution" => :runtime_execution}),
        optional: optional
      },
      replies: [
        %{
          name: :result,
          effect: :complete,
          select: %{
            "op" => Atom.to_string(name) <> "_result",
            "channel" => "runtime_output",
            "version" => @wire_version
          },
          required: Map.put(result, "id", :string),
          optional: %{"reset" => :runtime_output_reset}
        },
        %{
          name: :error,
          effect: :error,
          select: %{
            "op" => Atom.to_string(name) <> "_error",
            "channel" => "runtime_output",
            "version" => @wire_version
          },
          required: %{"id" => :string, "error" => :runtime_error}
        }
      ]
    }
  end

  defoperation :runtime_output_snapshot,
               output_operation.(
                 :runtime_output_snapshot,
                 %{},
                 %{"cursor" => :string},
                 %{"stream" => :runtime_output_stream, "cursor" => :string}
               )

  defoperation :runtime_output_read,
               output_operation.(
                 :runtime_output_read,
                 %{"cursor" => :string},
                 %{},
                 %{
                   "stream" => :runtime_output_stream,
                   "events" => {:list, :runtime_output_event},
                   "cursor" => :string,
                   "more" => :boolean
                 }
               )
end

defmodule AtlasBFFContract.Wire.Runtime.Protocol do
  @moduledoc "Generated typed Runtime codecs, dispatch and literal CLI command plumbing."
  use AtlasBFF.Targets.Protocol, contract: AtlasBFFContract.Wire.Runtime, channel: :runtime
end

defmodule AtlasBFFContract.Wire.Runtime.Types do
  @moduledoc "Generated shared data structures for any Atlas client or service adapter."
  use AtlasBFF.Targets.Client, contract: AtlasBFFContract.Wire.Runtime
end

defmodule AtlasBFFContract.Wire.Runtime.MachineProtocol do
  @moduledoc "Generated machine-scoped diagnostics, distinct from worker control."
  use AtlasBFF.Targets.Protocol,
    contract: AtlasBFFContract.Wire.Runtime,
    channel: :runtime_machine
end

defmodule AtlasBFFContract.Wire.Runtime.AttachmentProtocol do
  @moduledoc "Generated execution-bound snapshot profile; not a guidance or lifecycle API."
  use AtlasBFF.Targets.Protocol,
    contract: AtlasBFFContract.Wire.Runtime,
    channel: :runtime_attachment
end

defmodule AtlasBFFContract.Wire.Runtime.OutputProtocol do
  @moduledoc "Bounded ephemeral output reads; no worker lifecycle or durable history writes."
  use AtlasBFF.Targets.Protocol, contract: AtlasBFFContract.Wire.Runtime, channel: :runtime_output
end

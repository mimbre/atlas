defmodule AtlasBFFContract.Wire.Control.Session do
  @moduledoc "Control page/session and agent wire operations."
  use AtlasBFF.Schema
  version "0.15.0"
  models_from(AtlasBFFContract.Models.Presentation)

  # IS-101 described the 0.14.0 bytes without a bump; 0.15.0 adds the row fields `key` and
  # `pending` and the pushes below (docs/design/page-freshness.md §3).
  # A stored outcome acknowledges Facts only; Runtime/Flow still reconcile separately.
  @page_required %{"path" => :string, "title" => :string, "blocks" => :list, "markup" => :list}
  @page_optional %{
    "back" => :string,
    "position" => :integer,
    "at" => :string,
    "count" => :string,
    "refused" => :list,
    "actions_revision" => :string
  }
  @open %{
    name: :page,
    select: %{"op" => "page", "reason" => "open"},
    effect: :complete,
    required: @page_required,
    optional: @page_optional
  }
  @stored %{
    name: :stored,
    select: %{"op" => "page", "reason" => "stored"},
    effect: :complete,
    required: @page_required,
    optional: @page_optional
  }
  @refused %{
    name: :refused,
    select: %{"op" => "page", "reason" => "refused"},
    effect: :complete,
    required: @page_required,
    optional: @page_optional
  }
  @turn_error %{
    name: :error,
    select: %{"op" => "turn"},
    present: ["error"],
    effect: :error,
    required: %{"error" => :string}
  }
  @notice %{
    name: :notice,
    select: %{"op" => "notice"},
    effect: :progress,
    required: %{"tone" => :string, "text" => :string},
    optional: %{"at" => :string}
  }
  @plan %{name: :plan, select: %{"op" => "plan"}, effect: :progress, required: %{"block" => :map}}

  # Boot is additive: existing hello/welcome/page clients keep their exchange.
  defoperation :boot, %{
    channel: :control,
    direction: :request,
    request: %{select: %{"op" => "boot"}, optional: %{"to" => :string}},
    replies: [
      %{
        name: :shell,
        select: %{"op" => "boot"},
        absent: ["error"],
        effect: :complete,
        required: %{
          "title" => :string,
          "env" => :string,
          "spec" => :string,
          "revision" => :string,
          "tabs" => :list,
          "initial_to" => :string
        },
        optional: %{"active_tab" => :string}
      },
      %{
        name: :error,
        select: %{"op" => "boot"},
        present: ["error"],
        effect: :error,
        required: %{"error" => :string}
      }
    ]
  }

  # Exact stored data for subject-derived evidence; no page labels or form filtering.
  defoperation :facts_read, %{
    channel: :control,
    direction: :request,
    request: %{
      select: %{"op" => "facts_read"},
      required: %{"kind" => :string},
      optional: %{"key" => :string}
    },
    replies: [
      %{
        name: :result,
        select: %{"op" => "facts_read"},
        absent: ["error"],
        effect: :complete,
        required: %{"data" => :map}
      },
      %{
        name: :error,
        select: %{"op" => "facts_read"},
        present: ["error"],
        effect: :error,
        required: %{"error" => :string}
      }
    ]
  }

  defoperation :open,
               %{
                 channel: :control,
                 direction: :request,
                 request: %{select: %{"op" => "open"}, required: %{"to" => :string}},
                 replies: [@open]
               }

  defoperation :submit, %{
    channel: :control,
    direction: :request,
    request: %{
      select: %{"op" => "submit"},
      required: %{
        "endpoint" => :string,
        "params" => {:map, :string},
        "values" => {:map, :string}
      },
      optional: %{"cause" => :string}
    },
    # Some server-side validation/fault operations redraw without storing. This is
    # not a stored acknowledgement; the existing submit adapter keeps waiting.
    replies: [@stored, @refused, %{@open | effect: :progress}]
  }

  defoperation :hello, %{
    channel: :control,
    direction: :request,
    request: %{
      select: %{"op" => "hello"},
      required: %{"env" => :string, "client" => :string, "spec" => :string},
      optional: %{"as" => :string, "surface" => :string}
    },
    replies: [
      %{
        name: :welcome,
        select: %{"op" => "welcome"},
        effect: :progress,
        required: %{"env" => :string, "spec" => :string},
        optional: %{"surface" => :string}
      },
      Map.put(@open, :requires, [:welcome])
    ]
  }

  defoperation :turn, %{
    channel: :control,
    direction: :request,
    request: %{select: %{"op" => "turn"}},
    replies: [
      %{
        name: :turn,
        select: %{"op" => "turn"},
        absent: ["error"],
        effect: :complete,
        required: %{"key" => :string, "on" => :string},
        optional: %{"read_first" => :string}
      },
      @turn_error
    ]
  }

  defoperation :turn_end, %{
    channel: :control,
    direction: :request,
    request: %{
      select: %{"op" => "turn_end"},
      required: %{"key" => :string, "outcome" => :string}
    },
    replies: [@stored, @refused, @turn_error]
  }

  # Refresh does not answer while editing a form; callers need a form-aware adapter.
  defoperation :refresh, %{
    channel: :control,
    direction: :stream,
    request: %{select: %{"op" => "refresh"}},
    replies: [
      %{
        name: :page,
        select: %{"op" => "page", "reason" => "reconcile"},
        effect: :progress,
        required: @page_required,
        optional: @page_optional
      }
    ]
  }

  # A page Control sends unasked after a change: for the path on screen, and for a path
  # the client viewed recently (one of the last 8, at most 3 per flush). A client keeps
  # the newest page per path (by `position`) and shows it if the path is on screen.
  defoperation :hint, %{
    channel: :control,
    direction: :push,
    replies: [
      %{
        name: :page,
        select: %{"op" => "page", "reason" => "hint"},
        effect: :progress,
        required: @page_required,
        optional: @page_optional
      }
    ]
  }

  # The page sent again, as it was, with `pending` on the rows of facts a write of this
  # session changed and Flow has not yet settled; same `position` as the page it overlays.
  defoperation :pending, %{
    channel: :control,
    direction: :push,
    replies: [
      %{
        name: :page,
        select: %{"op" => "page", "reason" => "pending"},
        effect: :progress,
        required: @page_required,
        optional: @page_optional
      }
    ]
  }

  defoperation :reconcile, %{
    channel: :control,
    direction: :push,
    replies: [
      %{
        name: :page,
        select: %{"op" => "page", "reason" => "reconcile"},
        effect: :progress,
        required: @page_required,
        optional: @page_optional
      }
    ]
  }

  defoperation :notice, %{channel: :control, direction: :push, replies: [@notice]}

  defoperation :bye, %{
    channel: :control,
    direction: :push,
    replies: [
      %{name: :bye, select: %{"op" => "bye"}, effect: :terminal, required: %{"text" => :string}}
    ]
  }

  defoperation :ask, %{
    channel: :steer,
    direction: :stream,
    request: %{
      select: %{"op" => "ask"},
      required: %{"request" => :string, "on" => :string},
      optional: %{"intent" => :string}
    },
    replies: [@plan, @notice]
  }

  defoperation :run, %{
    channel: :steer,
    direction: :stream,
    request: %{select: %{"op" => "run"}, required: %{"steps" => :list}},
    replies: [@plan, @notice]
  }

  defoperation :cancel, %{
    channel: :steer,
    direction: :stream,
    request: %{select: %{"op" => "cancel"}},
    replies: [@plan]
  }

  defoperation :stop, %{
    channel: :steer,
    direction: :stream,
    request: %{select: %{"op" => "stop"}},
    replies: [@plan, @notice]
  }
end

defmodule AtlasBFFContract.Wire.Control.Session.Protocol do
  use AtlasBFF.Targets.Protocol,
    contract: AtlasBFFContract.Wire.Control.Session,
    channel: :control
end

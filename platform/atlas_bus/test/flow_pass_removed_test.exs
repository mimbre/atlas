defmodule AtlasBus.FlowPassRemovedTest do
  @moduledoc """
  Flow has no Bus pass delivery any more (F0): the link holds no rule of its own for the
  `flow_pass` kind. A pass request is never delivered to a machine's Runtime, and an answer
  of that kind is any answer, under the link's general rule, with no exception for
  `runtime@<machine>/passes` or `flow/passes`.
  """
  use ExUnit.Case, async: true
  alias AtlasBus.{Envelope, Link}

  @name "runtime@desk/passes"

  test "a flow_pass request reaches no machine, not even from flow/passes to its own endpoint" do
    e = %{Envelope.new("request", "flow_pass") | sender: "flow/passes", address: @name}
    refute Link.deliver_allowed?(@name, "desk", e)
    refute Link.deliver_allowed?(@name, "desk", %{e | sender: "flow"})

    # As any other request kind but Control's runtime.output: refused.
    refute Link.deliver_allowed?(@name, "desk", %{e | kind: "anything"})
  end

  test "a flow_pass answer follows the general answer rule, without a pass endpoint rule" do
    request = %{Envelope.new("request", "flow_pass") | sender: "flow/passes", address: @name}
    reply = %{Envelope.reply(request, "answer") | sender: @name, address: "flow/passes"}
    general = %{reply | kind: "anything"}

    # The removed rule allowed only flow/passes, from the machine's own /passes endpoint, with
    # no position; now the kind is judged exactly as any other answer is.
    for changed <- [
          reply,
          %{reply | address: "flow"},
          %{reply | address: "control/x"},
          %{reply | position: 1}
        ] do
      assert Link.send_allowed?(@name, "desk", changed) ==
               Link.send_allowed?(@name, "desk", %{changed | kind: general.kind})

      assert Link.send_allowed?(@name, "desk", changed)
    end

    assert Link.send_allowed?(@name, "other", reply)
    refute Link.send_allowed?(@name, "desk", %{reply | class: "request"})
  end
end

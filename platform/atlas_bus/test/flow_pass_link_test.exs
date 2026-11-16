defmodule AtlasBus.FlowPassLinkTest do
  use ExUnit.Case, async: true
  alias AtlasBus.{Envelope, Link}

  test "only the Flow pass endpoint can dispatch to the authenticated machine" do
    name = "runtime@desk/passes"
    e = %{Envelope.new("request", "flow_pass") | sender: "flow/passes", address: name}
    assert Link.deliver_allowed?(name, "desk", e)

    for changed <- [
          %{e | sender: "flow"},
          %{e | sender: "control/x"},
          %{e | address: "runtime@other/passes"},
          %{e | position: 1},
          %{e | class: "answer"}
        ] do
      refute Link.deliver_allowed?(name, "desk", changed)
    end

    refute Link.deliver_allowed?(name, "other", e)
    reply = %{Envelope.reply(e, "answer") | sender: name, address: "flow/passes"}
    assert Link.send_allowed?(name, "desk", reply)

    for changed <- [
          %{reply | address: "flow"},
          %{reply | address: "control/x"},
          %{reply | class: "request"},
          %{reply | position: 1}
        ] do
      refute Link.send_allowed?(name, "desk", changed)
    end

    refute Link.send_allowed?(name, "other", reply)
  end
end

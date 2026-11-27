defmodule AtlasRuntime.Sources.InBeamTargetTest do
  use ExUnit.Case, async: true

  alias AtlasRuntime.Sources.InBeamTarget
  alias AtlasRuntime.Test.WorkSourceFacade, as: F

  defmodule Source do
    alias AtlasRuntime.Test.WorkSourceFacade, as: F

    def poll(_client, _input) do
      %F.Outcome.Polled{
        leases: [],
        cancel: [],
        lease_lost: [],
        timing: %F.Timing{lease_ttl: 900, poll_max: 25},
        configuration: "policy",
        upgrade: %F.UpgradeOrder{id: "RU-01", build: "b2", action: :drain}
      }
    end
  end

  test "preserves configuration and upgrade orders in a poll answer" do
    assert {:polled, %{configuration: "policy", upgrade: upgrade}} =
             InBeamTarget.poll(%{facade: Source, client: {"mini", [:lease]}}, %{})

    assert %F.UpgradeOrder{id: "RU-01", build: "b2", action: :drain} = upgrade
  end
end

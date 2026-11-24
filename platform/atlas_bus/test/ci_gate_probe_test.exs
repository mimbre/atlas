defmodule AtlasBus.CiGateProbeTest do
  # Deliberately failing probe for the CI gate (IS-Atlas-115). Do not merge.
  use ExUnit.Case, async: true

  test "CI gate probe: fails on purpose" do
    assert 1 + 1 == 3
  end
end

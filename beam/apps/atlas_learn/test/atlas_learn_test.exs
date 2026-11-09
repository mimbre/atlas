defmodule AtlasLearnTest do
  use ExUnit.Case, async: true
  alias AtlasLearn.Fixtures

  test "writes the window's report, with evidence, to the caller's path" do
    out = Path.join(Fixtures.scratch("report"), "daily/learn.md")

    {:ok, ^out, _patterns} =
      AtlasLearn.run(
        out: out,
        until: Fixtures.until(),
        worker_passes: [read: Fixtures.runtime_read()],
        code_changes: [code_home: Fixtures.code_home()],
        decisions: [kind: "ledger", env: "test", client: Fixtures.atlas_client()]
      )

    report = File.read!(out)
    assert report =~ "# Learn report: 2026-11-10T06:00:00Z to 2026-11-11T06:00:00Z"
    assert report =~ "| Worker passes | Runtime read API (given reader) | read | 6 | 2 |"

    assert report =~
             "Evidence: `turn-00000000000000a1`, `turn-00000000000000a2`, `turn-00000000000000a3`"

    assert report =~ "Code does not know CI outcomes"
    refute report =~ "never-read-token"
  end

  test "a source that cannot be read is named in the report; the others still are" do
    out = Path.join(Fixtures.scratch("report"), "learn.md")

    AtlasLearn.run(
      out: out,
      until: Fixtures.until(),
      worker_passes: [read: fn "turns" -> {:error, "cannot reach read.sock"} end],
      decisions: [kind: "ledger", env: "test", client: Fixtures.atlas_client()]
    )

    report = File.read!(out)
    assert report =~ "unavailable: cannot reach read.sock"
    assert report =~ "| Changes through Code | no Code home given | not asked | 0 | 0 |"
    assert report =~ "Evidence: `D-0030`"
  end

  test "the window is the given hours before until" do
    window = AtlasLearn.Window.ending(Fixtures.until(), 2)
    assert AtlasLearn.Window.within?(window, "2026-11-11T04:00:00Z")
    refute AtlasLearn.Window.within?(window, "2026-11-11T06:00:00Z")
    refute AtlasLearn.Window.within?(window, "2026-11-11T03:59:59Z")
    refute AtlasLearn.Window.within?(window, nil)
  end
end

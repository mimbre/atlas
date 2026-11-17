defmodule AtlasRuntime.Work.HarnessTest do
  # The bench's own reads (AtlasRuntime.WorkHarness): a JSONL log is read only up to its last
  # complete line, and a launch is seen from facts that stay true, never from a state the
  # work only passes through.
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness

  @moduletag capture_log: true

  setup do
    %{bench: start!(%{"slots" => ["s1"]})}
  end

  test "a record still being written is not read", %{bench: bench} do
    path = Path.join(bench.dir, "work-launches.jsonl")
    first = JSON.encode!(%{"goal" => "complete one", "argv" => ["--model", "gpt-test"]})
    second = JSON.encode!(%{"goal" => "complete two", "argv" => ["--model", "gpt-test"]})

    # As a reader sees an append that is half done: the second record cut mid-way.
    File.write!(path, first <> "\n" <> binary_part(second, 0, div(byte_size(second), 2)))
    assert [%{"goal" => "complete one"}] = launches(bench)

    File.write!(path, first <> "\n" <> second)
    assert [%{"goal" => "complete one"}] = launches(bench)

    File.write!(path, first <> "\n" <> second <> "\n")
    assert [%{"goal" => "complete one"}, %{"goal" => "complete two"}] = launches(bench)

    File.write!(path, binary_part(first, 0, 10))
    assert launches(bench) == []
    assert complete_lines("") == []
  end

  test "a turn that ended before the bench looked is still launched", %{bench: bench} do
    work = submit!(bench, "complete at once")
    # The turn is over before await_launch first reads the work: it is never seen running.
    await_state(work.work_id, :completed)

    assert %{state: :completed, attempts: [%{turn_id: turn}]} = await_launch(bench, work)
    assert is_binary(turn)
    assert [%{"goal" => "complete at once"}] = launches(bench)
  end
end

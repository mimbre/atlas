Code.require_file("page_freshness/sessions.exs", __DIR__)

defmodule PageFreshness.ObservationTest do
  use ExUnit.Case, async: true
  alias PageFreshness.Sessions

  defp answer(n, reported, prior \\ nil),
    do: %{sequence: n, at: 0, type: "coverage", reported: reported, prior: prior}

  defp page(n, reason \\ "hint", position \\ 999),
    do: %{
      sequence: n,
      at: 0,
      type: "send",
      message: %{
        "op" => "page",
        "path" => "/",
        "reason" => reason,
        "position" => position,
        "blocks" => []
      }
    }

  test "integer coverage is inclusive and monotone; invalid and lower answers cannot cover" do
    events = [
      page(1),
      answer(2, "10"),
      page(3),
      answer(4, 10.0),
      page(5),
      answer(6, 9),
      page(7),
      answer(8, 10),
      page(9),
      answer(10, 3),
      page(11),
      answer(12, nil),
      page(13)
    ]

    frames = Sessions.frames(events, 10)

    assert Enum.map(Enum.filter(frames, &(&1.type == "send")), & &1.phase) ==
             ["pending", "pending", "pending", "pending", "covered", "covered", "covered"]

    assert List.last(frames).coverage == 10
    assert Enum.map(frames, & &1.sequence) == Enum.to_list(1..13)
  end

  test "same-timestamp sends stay on their side of coverage, regardless of reason or page position" do
    frames = Sessions.frames([page(1, "stored"), answer(2, 10), page(3, "pending", 0)], 10)
    assert [%{phase: "pending"}, %{phase: "covered"}, %{phase: "covered"}] = frames
    assert Enum.map(frames, & &1.at) == [0, 0, 0]
    # A stale covered frame must remain visible to the consumer assertions.
    assert List.last(frames).message["reason"] == "pending"
  end

  test "a watermark snapshot is diagnostic, not an observed covering answer" do
    assert [%{coverage: 2, phase: "pending"}, %{phase: "pending"}] =
             Sessions.frames([answer(1, 2, 12), page(2)], 10)

    assert [%{phase: "pending"}] = Sessions.frames([page(1)], 10)
  end

  defp assigned(n, keys, pending) do
    rows = for key <- keys, do: %{"key" => key, "label" => key, "pending" => key in pending}
    put_in(page(n), [:message, "blocks"], [%{"type" => "list", "props" => %{"rows" => rows}}])
  end

  test "consumer checks reject missing phases, premature removal, stale covered rows, flags and order" do
    before = ~w(A B C)
    changed = %{key: "B", label: "B"}
    pending = assigned(1, before, ["B"])
    covered = assigned(3, ~w(A C), [])

    check = fn events ->
      Sessions.assert_marker_frames(Sessions.frames(events, 10), before, changed)
    end

    check.([pending, answer(2, 10), covered])

    for bad <- [
          [answer(2, 10), covered],
          [pending],
          [assigned(1, ~w(A C), []), answer(2, 10), covered],
          [assigned(1, before, []), answer(2, 10), covered],
          [pending, answer(2, 10), assigned(3, before, ["B"])],
          [pending, answer(2, 10), assigned(3, before, [])],
          [pending, answer(2, 10), assigned(3, ~w(A C), ["C"])],
          [pending, answer(2, 10), assigned(3, ~w(C A), [])]
        ] do
      assert_raise ExUnit.AssertionError, fn -> check.(bad) end
    end
  end
end

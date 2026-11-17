defmodule AtlasFlow.ResultsTest do
  use ExUnit.Case, async: true

  alias AtlasFlow.ManualClock
  alias AtlasFlow.Results
  alias AtlasFlow.Results.Store

  @day 86_400_000
  @retention 14 * @day

  setup do
    dir = Path.join(System.tmp_dir!(), "results-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, clock} = ManualClock.start_link(~U[2026-11-17 12:00:00Z])
    %{dir: dir, clock: clock}
  end

  defp start(ctx, opts \\ []) do
    opts =
      Keyword.merge(
        [
          name: nil,
          dir: ctx.dir,
          clock: {ManualClock, ctx.clock},
          sweep_ms: 1,
          retention_ms: @retention,
          pins: fn -> [] end,
          store_cap: 1_000,
          result_cap: 500
        ],
        opts
      )

    start_supervised!(Supervisor.child_spec({Results, opts}, id: make_ref(), restart: :temporary))
  end

  defp sha(bytes), do: Store.sha256(bytes)

  defp put(server, bytes, opts \\ []) do
    room = Keyword.get_lazy(opts, :room, fn -> Results.room(0, server) end)
    content = Keyword.get(opts, :content, [bytes])

    Results.put(
      Keyword.get(opts, :sha, sha(bytes)),
      Keyword.get(opts, :size, byte_size(bytes)),
      content,
      room,
      server
    )
  end

  defp change_set(blobs) do
    %{
      base: "code-" <> String.duplicate("0", 64),
      roots: [
        %{
          root: "app",
          entries:
            for {bytes, i} <- Enum.with_index(blobs) do
              %{
                path: "f#{i}",
                op: "write",
                kind: "file",
                mode: "100644",
                size: byte_size(bytes),
                sha256: sha(bytes)
              }
            end
        }
      ]
    }
  end

  # Blobs stored, their manifest stored: the manifest's sha.
  defp result(server, blobs) do
    for bytes <- blobs, do: assert(put(server, bytes) == :stored)
    {:ok, manifest} = Results.put_manifest(change_set(blobs), server)
    manifest
  end

  defp present?(server, bytes), do: match?({:ok, _, _}, Results.blob(sha(bytes), server))

  defp manifest?(server, manifest),
    do: match?({:ok, _}, Results.manifest_by_sha(manifest, server))

  # Advances the clock. With `sweep_ms: 1` every advance runs one sweep, at the new time; it
  # has run once `room/2` (a call from this process, after the wakeup it sent) answers.
  defp advance(ctx, server, ms) do
    ManualClock.advance(ctx.clock, ms)
    Results.room(0, server)
  end

  defp reporting(bytes) do
    test = self()

    bytes
    |> :binary.bin_to_list()
    |> Stream.map(fn byte ->
      send(test, :chunk_read)
      <<byte>>
    end)
  end

  defp reads(n \\ 0) do
    receive do
      :chunk_read -> reads(n + 1)
    after
      0 -> n
    end
  end

  # A writer that has streamed `bytes` of a blob declared one byte longer, and then holds
  # them in flight until it is killed. Answers once the bytes are written, or flunks if the
  # writer ended first. No timeout: the answer does not depend on how loaded the VM is.
  defp held_writer(server, bytes) do
    test = self()
    size = byte_size(bytes) + 1

    held =
      Stream.concat(
        [bytes],
        Stream.map([:wait], fn :wait ->
          send(test, {:written, self()})
          Process.sleep(:infinity)
        end)
      )

    {writer, monitor} =
      spawn_monitor(fn -> Results.put(sha(bytes <> "!"), size, held, size, server) end)

    receive do
      {:written, ^writer} -> {writer, monitor}
      {:DOWN, ^monitor, :process, ^writer, _} -> flunk("writer ended before it held its bytes")
    end
  end

  # Kills a held writer, waits for it to be dead, then until the store has handled its
  # `:DOWN` (its room is `room` again). The store's `:DOWN` and this test's calls come from
  # different processes, so their order is not guaranteed: the test asks again until the
  # room holds, with no deadline (ExUnit's per-test timeout is the only backstop).
  defp kill_writer(server, {writer, monitor}, room) do
    Process.exit(writer, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^writer, _} -> :ok
    end

    until(fn -> Results.room(0, server) == room end)
  end

  defp until(fun) do
    if not fun.() do
      Process.sleep(1)
      until(fun)
    end
  end

  describe "storing" do
    test "is content-addressed and idempotent: stored again, no second copy", ctx do
      server = start(ctx)
      assert put(server, "hello") == :stored
      room = Results.room(0, server)
      assert put(server, "hello", content: reporting("hello")) == :stored
      assert reads() == 0
      assert Results.room(0, server) == room
      assert Store.scan(ctx.dir).blobs == %{sha("hello") => 5}
      assert {:ok, 5, stream} = Results.blob(sha("hello"), server)
      assert Enum.join(stream) == "hello"
    end

    test "concurrent puts of the same blob store it once", ctx do
      server = start(ctx)
      bytes = String.duplicate("z", 100)

      answers =
        1..8
        |> Enum.map(fn _ -> Task.async(fn -> put(server, bytes, room: 500) end) end)
        |> Enum.map(&Task.await/1)

      assert Enum.uniq(answers) == [:stored]
      assert Store.scan(ctx.dir).blobs == %{sha(bytes) => 100}
      assert Results.room(0, server) == 500
      assert Results.room(450, server) == 50
      assert Path.wildcard(Path.join([ctx.dir, "tmp", "*"])) == []
    end

    test "the store cap counts every blob already held", ctx do
      server = start(ctx, store_cap: 100, result_cap: 1_000)
      assert put(server, String.duplicate("a", 80)) == :stored
      assert Results.room(0, server) == 20

      assert put(server, String.duplicate("b", 21), content: reporting(String.duplicate("b", 21))) ==
               :too_large

      assert reads() == 0
      assert put(server, String.duplicate("c", 20)) == :stored
      assert Results.room(0, server) == 0
    end

    test "the store cap refuses a stale room before a byte when the declared size cannot fit",
         ctx do
      server = start(ctx, store_cap: 100, result_cap: 1_000)
      stale = Results.room(0, server)
      assert stale == 100
      assert put(server, String.duplicate("a", 80), room: stale) == :stored
      bytes = String.duplicate("d", 30)
      assert put(server, bytes, room: stale, content: reporting(bytes)) == :too_large
      assert reads() == 0
      assert Path.wildcard(Path.join([ctx.dir, "tmp", "*"])) == []
      assert Map.keys(Store.scan(ctx.dir).blobs) == [sha(String.duplicate("a", 80))]
      assert Results.room(0, server) == 20
    end

    test "a stale room: exactly the store's free bytes are stored, free + 1 is refused before a byte",
         ctx do
      server = start(ctx, store_cap: 1_000, result_cap: 2_000)
      stale = Results.room(0, server)
      {:ok, _} = Results.put_manifest(change_set(["one"]), server)
      assert put(server, String.duplicate("a", 80), room: stale) == :stored
      free = Results.room(0, server)
      assert free > 0 and free < stale - 80

      over = String.duplicate("e", free + 1)
      assert put(server, over, room: stale, content: reporting(over)) == :too_large
      assert reads() == 0
      assert Path.wildcard(Path.join([ctx.dir, "tmp", "*"])) == []
      refute Map.has_key?(Store.scan(ctx.dir).blobs, sha(over))

      fit = String.duplicate("f", free)
      assert put(server, fit, room: stale, content: reporting(fit)) == :stored
      assert reads() == free
      assert Results.room(0, server) == 0
    end

    test "the store cap holds while bytes stream, even against a stale room", ctx do
      server = start(ctx, store_cap: 10, result_cap: 1_000)
      bytes = String.duplicate("s", 20)
      assert put(server, bytes, size: 5, room: 1_000, content: reporting(bytes)) == :too_large
      assert reads() == 11
      assert Store.scan(ctx.dir).blobs == %{}
      assert Results.room(0, server) == 10
    end

    test "the result cap: exactly the room is stored, room + 1 is refused before a byte", ctx do
      server = start(ctx, result_cap: 10)
      assert Results.room(0, server) == 10
      assert Results.room(4, server) == 6
      assert Results.room(12, server) == 0

      assert put(server, "123456", room: Results.room(4, server), content: reporting("123456")) ==
               :stored

      assert reads() == 6

      assert put(server, "1234567", room: 6, content: reporting("1234567")) == :too_large
      assert reads() == 0
    end

    test "streaming stops at the first byte past the room and leaves nothing", ctx do
      server = start(ctx)
      bytes = String.duplicate("x", 20)
      assert put(server, bytes, size: 5, room: 10, content: reporting(bytes)) == :too_large
      assert reads() == 11
      assert Results.blob(sha(bytes), server) == :not_found
      assert Store.scan(ctx.dir).blobs == %{}
      assert Path.wildcard(Path.join([ctx.dir, "tmp", "*"])) == []
      assert Results.room(0, server) == 500
    end

    test "a sha256 or size mismatch is digest_mismatch, and nothing is stored", ctx do
      server = start(ctx)
      claimed = sha("other")
      assert put(server, "hello", sha: claimed) == {:rejected, :digest_mismatch}
      assert put(server, "hello", size: 4) == {:rejected, :digest_mismatch}
      assert put(server, "hello", size: 6) == {:rejected, :digest_mismatch}

      assert put(server, "hello", sha: "../" <> binary_part(claimed, 0, 61)) ==
               {:rejected, :digest_mismatch}

      assert Results.blob(claimed, server) == :not_found
      assert Results.blob(sha("hello"), server) == :not_found
      assert Store.scan(ctx.dir).blobs == %{}
      assert Results.room(0, server) == 500
    end

    test "a writer killed between its temp write and the rename leaves no visible blob", ctx do
      server = start(ctx, result_cap: 1_000)
      writer = held_writer(server, "partial")
      assert Results.room(0, server) == 993
      assert [_temp] = Path.wildcard(Path.join([ctx.dir, "tmp", "*"]))

      kill_writer(server, writer, 1_000)
      assert Results.blob(sha("partial!"), server) == :not_found
      assert Store.scan(ctx.dir).blobs == %{}
      assert Path.wildcard(Path.join([ctx.dir, "tmp", "*"])) == []
    end

    test "bytes still streaming count against the store cap before a byte of a stale-room put",
         ctx do
      server = start(ctx, store_cap: 100, result_cap: 1_000)
      stale = Results.room(0, server)
      assert stale == 100
      writer = held_writer(server, String.duplicate("w", 60))
      assert Results.room(0, server) == 40

      over = String.duplicate("g", 41)
      assert put(server, over, room: stale, content: reporting(over)) == :too_large
      assert reads() == 0
      assert [_held] = Path.wildcard(Path.join([ctx.dir, "tmp", "*"]))

      fit = String.duplicate("h", 40)
      assert put(server, fit, room: stale, content: reporting(fit)) == :stored
      assert reads() == 40
      assert Results.room(0, server) == 0

      kill_writer(server, writer, 60)
      assert Store.scan(ctx.dir).blobs == %{sha(fit) => 40}
      assert Path.wildcard(Path.join([ctx.dir, "tmp", "*"])) == []
    end

    test "with no directory every put is too_large and nothing is read", ctx do
      server = start(ctx, dir: nil)
      assert Results.room(0, server) == 0
      assert put(server, "hello", room: 500, content: reporting("hello")) == :too_large
      assert reads() == 0
      assert Results.put_manifest(change_set(["hello"]), server) == :too_large
      assert Results.manifest("TK-a-1", server) == :not_found
      assert Results.blob(sha("hello"), server) == :not_found
    end

    test "with no store running every put is too_large and every read not_found" do
      server = :results_never_started
      assert Results.room(0, server) == 0
      assert Results.put(sha("x"), 1, ["x"], 10, server) == :too_large
      assert Results.put_manifest(%{base: "b", roots: []}, server) == :too_large
      assert Results.manifest("TK-a-1", server) == :not_found
      assert Results.blob(sha("x"), server) == :not_found
      assert Results.unpin("TK-a-1", DateTime.utc_now(), server) == :ok
    end
  end

  describe "manifests" do
    test "the same change set has one sha whatever its key form and order", ctx do
      server = start(ctx)
      {:ok, a} = Results.put_manifest(change_set(["one", "two"]), server)

      stringly = %{
        "roots" => [
          %{
            "entries" =>
              for(
                {bytes, i} <- Enum.with_index(["one", "two"]),
                do: %{
                  "sha256" => sha(bytes),
                  "size" => byte_size(bytes),
                  "mode" => "100644",
                  "kind" => "file",
                  "op" => "write",
                  "path" => "f#{i}",
                  "target" => nil
                }
              ),
            "root" => "app"
          }
        ],
        "base" => "code-" <> String.duplicate("0", 64)
      }

      assert Results.put_manifest(stringly, server) == {:ok, a}
      assert Store.scan(ctx.dir).manifests |> Map.keys() == [a]

      assert {:ok, %{"base" => _, "roots" => [%{"root" => "app", "entries" => [_, _]}]}} =
               Results.manifest_by_sha(a, server)

      assert Results.manifest_by_sha(sha("none"), server) == :not_found
    end

    test "a manifest counts against the store cap", ctx do
      server = start(ctx, store_cap: 2_000, result_cap: 2_000)
      {:ok, manifest} = Results.put_manifest(change_set(["one"]), server)
      assert Results.room(0, server) == 2_000 - Store.scan(ctx.dir).manifests[manifest]

      tiny = start(%{ctx | dir: ctx.dir <> "-tiny"}, store_cap: 10)
      on_exit(fn -> File.rm_rf!(ctx.dir <> "-tiny") end)
      assert Results.put_manifest(change_set(["one"]), tiny) == :too_large
    end

    test "a pin names a stored manifest only, and the task's manifest reads back", ctx do
      server = start(ctx)
      manifest = result(server, ["one"])
      assert Results.pin("TK-a-1", sha("none"), server) == :not_found
      assert Results.manifest("TK-a-1", server) == :not_found
      assert Results.pin("TK-a-1", manifest, server) == :ok

      assert {:ok, %{"roots" => [%{"entries" => [%{"sha256" => blob}]}]}} =
               Results.manifest("TK-a-1", server)

      assert blob == sha("one")
    end
  end

  describe "retention" do
    test "unpinned + 14 days is deleted; pinned never; a blob shared with a pinned result is kept",
         ctx do
      server = start(ctx)
      first = result(server, ["a", "b"])
      second = result(server, ["b", "c"])
      :ok = Results.pin("TK-x-1", first, server)
      :ok = Results.pin("TK-y-1", second, server)
      Results.unpin("TK-x-1", ManualClock.now(ctx.clock), server)

      advance(ctx, server, @retention - 1)
      assert manifest?(server, first) and present?(server, "a")

      advance(ctx, server, 1)
      refute manifest?(server, first)
      refute present?(server, "a")
      assert present?(server, "b") and present?(server, "c") and manifest?(server, second)
      assert Results.manifest("TK-x-1", server) == :not_found

      advance(ctx, server, 3 * @retention)
      assert present?(server, "b") and present?(server, "c") and manifest?(server, second)
      assert {:ok, _} = Results.manifest("TK-y-1", server)
      assert Map.keys(Store.scan(ctx.dir).blobs) |> Enum.sort() == Enum.sort([sha("b"), sha("c")])
    end

    test "the unpin time is the caller's `at`", ctx do
      server = start(ctx)
      manifest = result(server, ["a"])
      :ok = Results.pin("TK-x-1", manifest, server)
      advance(ctx, server, 3 * @day)

      Results.unpin(
        "TK-x-1",
        DateTime.add(ManualClock.now(ctx.clock), -3 * @day, :millisecond),
        server
      )

      advance(ctx, server, @retention - 3 * @day)
      refute manifest?(server, manifest)
      refute present?(server, "a")
    end

    test "a second pin of the same task replaces the first; its clock starts then", ctx do
      server = start(ctx)
      first = result(server, ["a", "b"])
      :ok = Results.pin("TK-x-1", first, server)
      advance(ctx, server, 3 * @day)
      second = result(server, ["b", "c"])
      assert Results.pin("TK-x-1", second, server) == :ok

      assert {:ok, %{"roots" => [%{"entries" => [_, %{"sha256" => c}]}]}} =
               Results.manifest("TK-x-1", server)

      assert c == sha("c")

      advance(ctx, server, @retention - 1)
      assert manifest?(server, first) and present?(server, "a")

      advance(ctx, server, 1)
      refute manifest?(server, first)
      refute present?(server, "a")
      assert present?(server, "b") and present?(server, "c") and manifest?(server, second)
    end

    test "pinning the manifest a task already pins changes nothing", ctx do
      server = start(ctx)
      manifest = result(server, ["a"])
      :ok = Results.pin("TK-x-1", manifest, server)
      advance(ctx, server, @day)
      assert Results.pin("TK-x-1", manifest, server) == :ok

      advance(ctx, server, 3 * @retention)
      assert manifest?(server, manifest) and present?(server, "a")
      assert {:ok, _} = Results.manifest("TK-x-1", server)
    end

    test "a manifest two tasks pin is kept until both release it", ctx do
      server = start(ctx)
      manifest = result(server, ["a"])
      :ok = Results.pin("TK-x-1", manifest, server)
      :ok = Results.pin("TK-y-1", manifest, server)
      Results.unpin("TK-x-1", ManualClock.now(ctx.clock), server)

      advance(ctx, server, 2 * @retention)
      assert manifest?(server, manifest) and present?(server, "a")
    end

    test "a blob no manifest references goes 14 days after it was stored", ctx do
      server = start(ctx)
      assert put(server, "loose") == :stored
      advance(ctx, server, @retention - 1)
      assert present?(server, "loose")
      advance(ctx, server, 1)
      refute present?(server, "loose")
      assert Results.room(0, server) == 500
    end
  end

  describe "rebuild" do
    test "a pin list restores the index; a manifest not in it goes 14 days after the rebuild, not earlier",
         ctx do
      server = start(ctx)
      kept = result(server, ["a"])
      dropped = result(server, ["b"])
      :ok = Results.pin("TK-x-1", kept, server)
      :ok = Results.pin("TK-y-1", dropped, server)
      advance(ctx, server, 10 * @day)

      assert Results.rebuild([{"TK-x-1", kept}, {"TK-z-1", sha("never stored")}], server) == :ok
      assert {:ok, _} = Results.manifest("TK-x-1", server)
      assert Results.manifest("TK-y-1", server) == :not_found
      assert Results.manifest("TK-z-1", server) == :not_found

      advance(ctx, server, @retention - 1)
      assert manifest?(server, dropped) and present?(server, "b")

      advance(ctx, server, 1)
      refute manifest?(server, dropped)
      refute present?(server, "b")
      assert manifest?(server, kept) and present?(server, "a")
    end

    test "a rebuild re-dates a loose blob: it goes 14 days after the rebuild, not earlier", ctx do
      server = start(ctx)
      assert put(server, "loose") == :stored
      advance(ctx, server, 10 * @day)
      assert Results.rebuild([], server) == :ok

      advance(ctx, server, @retention - 1)
      assert present?(server, "loose")

      advance(ctx, server, 1)
      refute present?(server, "loose")
      assert Store.scan(ctx.dir).blobs == %{}
    end

    test "a restarted store rebuilds from the disk and its pins before it serves", ctx do
      server = start(ctx)
      manifest = result(server, ["a", "b"])
      other = result(server, ["c"])
      :ok = Results.pin("TK-x-1", manifest, server)
      :ok = GenServer.stop(server)

      File.write!(Path.join([ctx.dir, "tmp", "left-over"]), "half")
      test = self()

      pins = fn ->
        send(test, :pins_read)
        [{"TK-x-1", manifest}]
      end

      restarted = start(ctx, pins: pins)
      assert {:ok, _} = Results.manifest("TK-x-1", restarted)
      assert_received :pins_read
      assert Path.wildcard(Path.join([ctx.dir, "tmp", "*"])) == []
      held = Store.scan(ctx.dir)

      assert Results.room(0, restarted) ==
               1_000 - Enum.sum(Map.values(held.blobs)) - Enum.sum(Map.values(held.manifests))

      advance(ctx, restarted, @retention)

      assert manifest?(restarted, manifest) and present?(restarted, "a") and
               present?(restarted, "b")

      refute manifest?(restarted, other)
      refute present?(restarted, "c")
    end
  end
end

defmodule AtlasFlow.BasesTest do
  # Bases against FakeCode: the base and its manifest blob, reuse per revision, the names a
  # lease may read, blobs read through, and that no caller ever waits on Code.
  use ExUnit.Case, async: true

  alias AtlasFlow.{Bases, FakeCode, ManualClock}

  @repository "example.org/acme/app"
  @readme "hello\n"
  @run "#!/bin/sh\necho run\n"
  @large :binary.copy("0123456789abcdef", 10_000)

  setup do
    fake = start_supervised!({FakeCode, %{}}, id: :fake)
    FakeCode.put(fake, @repository, "develop", "rev_1", files())
    clock = start_supervised!({ManualClock, ~U[2026-11-17 12:00:00Z]}, id: :clock)
    name = :"bases_#{System.unique_integer([:positive])}"
    %{fake: fake, clock: clock, name: name}
  end

  defp files, do: %{"README.md" => @readme, "bin/run" => @run, "data/large.bin" => @large}

  defp start_bases(%{fake: fake, clock: clock, name: name}) do
    start_supervised!(
      {Bases, name: name, client: FakeCode.client(fake), clock: {ManualClock, clock}},
      id: name
    )
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp ready(context, reference \\ "develop") do
    :ok = Bases.request(@repository, reference, {self(), {:ready, reference}}, context.name)
    assert_receive {:ready, ^reference}
    {:ok, base} = Bases.cached(@repository, reference, context.name)
    base
  end

  defp count(fake, capability),
    do: fake |> FakeCode.calls() |> Enum.count(&(elem(&1, 0) == capability))

  # Waits until Bases has handled everything sent to it so far, and its task has answered.
  defp settle(context, until) do
    Enum.reduce_while(1..200, nil, fn _, _ ->
      :sys.get_state(context.name)

      if until.() do
        {:halt, :ok}
      else
        Process.sleep(5)
        {:cont, nil}
      end
    end)

    assert until.()
  end

  describe "a base" do
    test "is code-<snapshot hex> and the sha256 of the canonical manifest blob", context do
      start_bases(context)
      base = ready(context)

      assert %{base_id: "code-" <> hex, manifest: manifest, snapshot_id: "sha256:" <> hex} = base
      assert String.match?(hex, ~r/\A[0-9a-f]{64}\z/)

      expected =
        ~s({"roots":[{"entries":[) <>
          ~s({"kind":"file","mode":"100644","op":"write","path":"README.md","sha256":"#{sha256(@readme)}","size":#{byte_size(@readme)}},) <>
          ~s({"kind":"file","mode":"100755","op":"write","path":"bin/run","sha256":"#{sha256(@run)}","size":#{byte_size(@run)}},) <>
          ~s({"kind":"file","mode":"100644","op":"write","path":"data/large.bin","sha256":"#{sha256(@large)}","size":#{byte_size(@large)}}) <>
          ~s(],"root":"app"}]})

      assert {:ok, size, stream} = Bases.blob(manifest, base.snapshot_id, context.name)
      assert Enum.join(stream) == expected
      assert size == byte_size(expected)
      assert manifest == sha256(expected)
    end

    test "is deterministic: the same revision gives the same base, from any Bases", context do
      {:ok, first} = Bases.for(FakeCode.client(context.fake), @repository, "develop")

      other = start_supervised!({FakeCode, %{}}, id: :other)
      FakeCode.put(other, @repository, "main", "rev_1", files())
      assert {:ok, ^first} = Bases.for(FakeCode.client(other), @repository, "main")

      start_bases(context)
      assert ready(context) == first
    end

    test "is reused per revision: one snapshot, however many references or requests", context do
      FakeCode.put(context.fake, @repository, "main", "rev_1", files())
      start_bases(context)

      develop = ready(context, "develop")
      assert ready(context, "main") == develop
      assert ready(context, "develop") == develop
      assert count(context.fake, :create_snapshot) == 1
      # The cached reference answers at once: no third resolution.
      assert count(context.fake, :resolve_reference) == 2

      FakeCode.put(context.fake, @repository, "next", "rev_2", Map.put(files(), "NEW", "x"))
      assert ready(context, "next").base_id != develop.base_id
      assert count(context.fake, :create_snapshot) == 2
    end

    test "an unknown reference is unavailable, and the caller is not notified", context do
      start_bases(context)
      :ok = Bases.request(@repository, "nowhere", {self(), :ready}, context.name)

      settle(context, fn -> Bases.cached(@repository, "nowhere", context.name) == :unavailable end)

      refute_received :ready
    end
  end

  describe "names and blobs" do
    test "names: the manifest blob and every write entry's sha256", context do
      start_bases(context)
      base = ready(context)

      assert Bases.names(base.manifest, context.name) ==
               {:ok, MapSet.new([base.manifest, sha256(@readme), sha256(@run), sha256(@large)])}

      assert Bases.names(sha256("no manifest"), context.name) == :not_found
    end

    test "names leave out every entry that is not a write" do
      document = %{
        "roots" => [
          %{
            "root" => "app",
            "entries" => [
              %{"op" => "write", "path" => "a", "sha256" => "aa"},
              %{"op" => "delete", "path" => "b", "sha256" => "bb"},
              %{"path" => "c", "sha256" => "cc"}
            ]
          }
        ]
      }

      assert Bases.names_of("mm", document) == MapSet.new(["mm", "aa"])
    end

    test "blobs are read through from Code, in chunks; an unknown sha is not_found", context do
      start_bases(context)
      base = ready(context)

      assert {:ok, size, stream} = Bases.blob(sha256(@large), base.snapshot_id, context.name)
      assert size == byte_size(@large)
      refute is_binary(stream) or is_list(stream)
      chunks = Enum.to_list(stream)
      assert length(chunks) > 1
      assert IO.iodata_to_binary(chunks) == @large

      assert {:ok, _, readme} = Bases.blob(sha256(@readme), base.snapshot_id, context.name)
      assert Enum.join(readme) == @readme

      assert Bases.blob(sha256("unknown"), base.snapshot_id, context.name) == :not_found

      # The manifest blob belongs to its own snapshot only.
      assert Bases.blob(base.manifest, "sha256:" <> String.duplicate("0", 64), context.name) ==
               :not_found
    end
  end

  describe "no caller waits on Code" do
    test "with Code blocked, cached/3 and request/4 answer at once and never call Code",
         context do
      FakeCode.mode(context.fake, :blocked)
      start_bases(context)
      me = self()

      caller =
        Task.async(fn ->
          a = Bases.request(@repository, "develop", {me, :first}, context.name)
          b = Bases.request(@repository, "develop", {me, :second}, context.name)
          {self(), a, b, Bases.cached(@repository, "develop", context.name)}
        end)

      assert {:ok, {caller_pid, :ok, :ok, :missing}} = Task.yield(caller, 1_000)

      # One resolution for both requests, waiting on Code in a process of its own.
      settle(context, fn -> FakeCode.blocked(context.fake) == 1 end)
      assert Bases.cached(@repository, "develop", context.name) == :missing
      callers = context.fake |> FakeCode.calls() |> Enum.map(&elem(&1, 1))
      refute caller_pid in callers
      refute self() in callers
      refute Process.whereis(context.name) in callers

      FakeCode.mode(context.fake, :ok)
      FakeCode.release(context.fake)
      assert_receive :first
      assert_receive :second
      assert {:ok, _base} = Bases.cached(@repository, "develop", context.name)
      assert count(context.fake, :resolve_reference) == 1
      refute Enum.any?(FakeCode.calls(context.fake), &(elem(&1, 1) in [caller_pid, self()]))
    end

    test "Code slower than 15 s: unavailable, retried after 30 s, then notified", context do
      FakeCode.mode(context.fake, :blocked)
      start_bases(context)
      :ok = Bases.request(@repository, "develop", {self(), :ready}, context.name)
      settle(context, fn -> FakeCode.blocked(context.fake) == 1 end)

      ManualClock.advance(context.clock, 14_999)
      :sys.get_state(context.name)
      assert Bases.cached(@repository, "develop", context.name) == :missing

      ManualClock.advance(context.clock, 1)

      settle(context, fn -> Bases.cached(@repository, "develop", context.name) == :unavailable end)

      FakeCode.mode(context.fake, :ok)
      ManualClock.advance(context.clock, 30_000)
      assert_receive :ready
      assert {:ok, _base} = Bases.cached(@repository, "develop", context.name)
    end

    test "Code failing: unavailable, retried after 30 s with every notify kept", context do
      FakeCode.mode(context.fake, :failing)
      start_bases(context)
      :ok = Bases.request(@repository, "develop", {self(), :first}, context.name)

      settle(context, fn -> Bases.cached(@repository, "develop", context.name) == :unavailable end)

      calls = length(FakeCode.calls(context.fake))

      # A request while waiting for the retry only waits too: Code is not asked again.
      :ok = Bases.request(@repository, "develop", {self(), :second}, context.name)
      :sys.get_state(context.name)
      assert length(FakeCode.calls(context.fake)) == calls

      FakeCode.mode(context.fake, :ok)
      ManualClock.advance(context.clock, 29_999)
      :sys.get_state(context.name)
      assert length(FakeCode.calls(context.fake)) == calls
      refute_received :first

      ManualClock.advance(context.clock, 1)
      assert_receive :first
      assert_receive :second
      assert {:ok, _base} = Bases.cached(@repository, "develop", context.name)
    end

    test "with Bases not running: unavailable, and nothing raises", context do
      assert Bases.cached(@repository, "develop", context.name) == :unavailable
      assert Bases.request(@repository, "develop", {self(), :ready}, context.name) == :ok
      assert Bases.names(sha256("x"), context.name) == :not_found
      assert Bases.blob(sha256("x"), "sha256:" <> sha256("y"), context.name) == :unavailable
      refute_received :ready
    end
  end
end

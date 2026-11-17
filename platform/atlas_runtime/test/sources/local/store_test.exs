defmodule AtlasRuntime.Sources.Local.StoreTest do
  # M2 plan W7: the local work source's queue under <home>/local-source/ — persistence only.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  alias AtlasRuntime.Model.LocalSource.QueuedWork
  alias AtlasRuntime.Sources.Local.Store

  @t0 ~U[2026-11-17 09:00:00.000000Z]

  setup do
    home = Path.join(System.tmp_dir!(), "w7-local-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)
    %{home: home}
  end

  defp request(title \\ "t") do
    %{
      title: title,
      instructions: "i",
      profile: "p",
      cost_class: :standard,
      workspace: %{kind: :folder, path: "/w", permissions: :workspace_write}
    }
  end

  defp attrs(n, fields) do
    Map.merge(
      %{
        work_id: "work-#{n}",
        client: "local",
        client_key: "key-#{n}",
        request: request(),
        priority: 1,
        added_at: DateTime.add(@t0, n, :second)
      },
      Map.new(fields)
    )
  end

  defp add!(home, loaded, n, fields \\ []) do
    {:added, work, loaded} = Store.add!(home, loaded, attrs(n, fields))
    {work, loaded}
  end

  defp finish!(home, loaded, work, kind \\ :completed) do
    ended = %{
      work
      | state: :ended,
        lease_id: "lease-#{work.work_id}",
        result: %{kind: kind, attempt: 1, ended_at: @t0}
    }

    Store.put!(home, loaded, QueuedWork.new!(ended))
  end

  defp ids(works), do: Enum.map(works, & &1.work_id)

  test "an empty home loads as an empty store", %{home: home} do
    assert Store.load(home) == {:ok, Store.empty()}
  end

  test "a work added, leased and ended round-trips through local-source/", %{home: home} do
    {work, loaded} = add!(home, Store.empty(), 1)
    assert work.state == :queued
    leased = QueuedWork.new!(%{work | state: :leased, lease_id: "lease-1"})
    loaded = Store.put!(home, loaded, leased)
    assert {:ok, ^loaded} = Store.load(home)
    assert File.exists?(Path.join(home, "local-source/queue/work-1.json"))
    assert File.exists?(Path.join(home, "local-source/index.json"))

    loaded = finish!(home, loaded, leased, :failed)
    assert {:ok, reloaded} = Store.load(home)
    assert reloaded == loaded
    assert %{final_kind: :failed, pruned: false} = reloaded.index[{"local", "key-1"}]
  end

  test "priority before FIFO", %{home: home} do
    # Added in this order (and at these times): low, high, low, high.
    loaded =
      Enum.reduce([{1, 2}, {2, 1}, {3, 2}, {4, 1}], Store.empty(), fn {n, priority}, loaded ->
        add!(home, loaded, n, priority: priority) |> elem(1)
      end)

    assert ids(Store.queued(loaded)) == ["work-2", "work-4", "work-1", "work-3"]
    assert {:ok, reloaded} = Store.load(home)
    assert ids(Store.queued(reloaded)) == ["work-2", "work-4", "work-1", "work-3"]
  end

  test "FIFO follows the add order, not the clock", %{home: home} do
    {_, loaded} = add!(home, Store.empty(), 1, added_at: DateTime.add(@t0, 60, :second))
    {_, loaded} = add!(home, loaded, 2, added_at: @t0)
    assert ids(Store.queued(loaded)) == ["work-1", "work-2"]
  end

  test "only queued works wait; a leased or ended one keeps its place in ordered/1", %{home: home} do
    {w1, loaded} = add!(home, Store.empty(), 1)
    {_, loaded} = add!(home, loaded, 2)
    loaded = Store.put!(home, loaded, QueuedWork.new!(%{w1 | state: :leased, lease_id: "l"}))
    assert ids(Store.queued(loaded)) == ["work-2"]
    assert ids(Store.ordered(loaded)) == ["work-1", "work-2"]
  end

  test "I3: the same key gives existing, another request gives conflict", %{home: home} do
    {work, loaded} = add!(home, Store.empty(), 1)
    assert {:existing, ^work} = Store.add!(home, loaded, attrs(1, work_id: "work-9"))

    assert {:conflict, "work-1"} =
             Store.add!(home, loaded, attrs(1, work_id: "work-9", request: request("other")))

    # Another client may use the same key.
    assert {:added, _, _} = Store.add!(home, loaded, attrs(1, work_id: "work-9", client: "other"))
  end

  test "key reuse after prune is a conflict", %{home: home} do
    {work, loaded} = add!(home, Store.empty(), 1)
    loaded = finish!(home, loaded, work)
    loaded = Store.prune!(home, loaded, "work-1")
    refute File.exists?(Path.join(home, "local-source/queue/work-1.json"))

    assert {:ok, reloaded} = Store.load(home)
    assert reloaded == loaded
    assert reloaded.entries == %{}

    assert {:pruned, %{work_id: "work-1", final_kind: :completed, pruned: true}} =
             Store.find(reloaded, "local", "key-1")

    assert Store.tombstone(reloaded, "work-1").final_kind == :completed
    assert {:conflict, "work-1"} = Store.add!(home, reloaded, attrs(1, work_id: "work-2"))
    assert Store.find(reloaded, "local", "never") == :not_found
  end

  test "I7: a pruned key equal to its work_id stays a conflict after a restart", %{home: home} do
    {work, loaded} = add!(home, Store.empty(), 1, work_id: "w1", client_key: "w1")
    loaded = finish!(home, loaded, work)
    loaded = Store.prune!(home, loaded, "w1")
    assert {:conflict, "w1"} = Store.add!(home, loaded, attrs(2, client_key: "w1"))

    assert {:ok, reloaded} = Store.load(home)
    assert reloaded == loaded
    assert {:pruned, %{work_id: "w1", pruned: true}} = Store.find(reloaded, "local", "w1")
    assert {:conflict, "w1"} = Store.add!(home, reloaded, attrs(2, client_key: "w1"))
  end

  test "a pruned work without a key keeps a tombstone under its own id", %{home: home} do
    {work, loaded} = add!(home, Store.empty(), 1, client_key: nil)
    loaded = finish!(home, loaded, work, :cancelled)
    loaded = Store.prune!(home, loaded, "work-1")
    assert {:ok, ^loaded} = Store.load(home)
    reloaded = loaded

    assert %{pruned: true, final_kind: :cancelled, client_key: nil} =
             Store.tombstone(reloaded, "work-1")

    assert Store.find(reloaded, "local", "work-1") == :not_found
  end

  test "a work that has not ended is not pruned", %{home: home} do
    {_, loaded} = add!(home, Store.empty(), 1)
    assert_raise MatchError, fn -> Store.prune!(home, loaded, "work-1") end
    assert {:ok, %{entries: %{"work-1" => _}}} = Store.load(home)
  end

  test "positions keep growing after a prune and a reload", %{home: home} do
    {w1, loaded} = add!(home, Store.empty(), 1)
    {_, loaded} = add!(home, loaded, 2)
    loaded = finish!(home, loaded, w1)
    Store.prune!(home, loaded, "work-1")
    {:ok, loaded} = Store.load(home)
    {w3, _} = add!(home, loaded, 3, added_at: @t0)
    assert w3.position > loaded.entries["work-2"].position
  end

  describe "a load it cannot read is refused, never migrated" do
    setup %{home: home} do
      {_, loaded} = add!(home, Store.empty(), 1)
      %{loaded: loaded}
    end

    test "another format version names the file", %{home: home} do
      path = Path.join(home, "local-source/queue/work-1.json")

      File.write!(
        path,
        path |> File.read!() |> JSON.decode!() |> Map.put("format_version", 99) |> JSON.encode!()
      )

      assert {:error, why} = Store.load(home)
      assert why =~ "work-1.json"
    end

    test "a file that is not JSON, or names another work", %{home: home} do
      path = Path.join(home, "local-source/queue/work-1.json")
      body = File.read!(path)
      File.write!(path, "{")
      assert {:error, _} = Store.load(home)
      File.rm!(path)
      File.write!(Path.join(home, "local-source/queue/work-2.json"), body)
      assert {:error, why} = Store.load(home)
      assert why =~ "work-2.json"
    end

    test "an index with another format version, or a key listed twice", %{home: home} do
      path = Path.join(home, "local-source/index.json")
      map = path |> File.read!() |> JSON.decode!()
      File.write!(path, map |> Map.put("format_version", 2) |> JSON.encode!())
      assert {:error, why} = Store.load(home)
      assert why =~ "index.json"

      File.write!(path, map |> Map.update!("entries", &(&1 ++ &1)) |> JSON.encode!())
      assert {:error, _} = Store.load(home)
    end

    test "an index entry without a client key that is not pruned", %{home: home} do
      path = Path.join(home, "local-source/index.json")
      map = path |> File.read!() |> JSON.decode!()
      keyless = &Enum.map(&1, fn entry -> Map.delete(entry, "client_key") end)
      File.write!(path, map |> Map.update!("entries", keyless) |> JSON.encode!())
      assert {:error, why} = Store.load(home)
      assert why =~ "index.json"
    end
  end

  test "a lost index entry is repaired from its queued work", %{home: home} do
    {_, loaded} = add!(home, Store.empty(), 1)
    File.rm!(Path.join(home, "local-source/index.json"))
    assert {:ok, ^loaded} = Store.load(home)
  end

  test "an entry whose work is gone unpruned still answers for its key", %{home: home} do
    {_, loaded} = add!(home, Store.empty(), 1)
    File.rm!(Path.join(home, "local-source/queue/work-1.json"))

    log =
      capture_log(fn ->
        assert {:ok, reloaded} = Store.load(home)
        assert {:pruned, _} = Store.find(reloaded, "local", "key-1")
        assert {:conflict, "work-1"} = Store.add!(home, reloaded, attrs(1, work_id: "work-2"))
      end)

    assert log =~ "work-1"
    assert loaded.index[{"local", "key-1"}]
  end

  test "writes are atomic: a leftover temporary file is ignored and removed", %{home: home} do
    {_, loaded} = add!(home, Store.empty(), 1)
    tmp = Path.join(home, "local-source/queue/work-2.json.tmp")
    File.write!(tmp, "{")
    File.write!(Path.join(home, "local-source/index.json.tmp"), "{")
    assert {:ok, ^loaded} = Store.load(home)
    assert Path.wildcard(Path.join(home, "local-source/**/*.tmp")) == []
  end

  test "the store's folders are owner-only", %{home: home} do
    add!(home, Store.empty(), 1)

    for folder <- ["local-source", "local-source/queue"] do
      assert Bitwise.band(File.stat!(Path.join(home, folder)).mode, 0o777) == 0o700
    end
  end
end

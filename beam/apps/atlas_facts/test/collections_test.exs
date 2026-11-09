defmodule AtlasFacts.CollectionsTest do
  use ExUnit.Case, async: true
  alias AtlasFacts.{Collections, CountingRela, Rela}

  setup do
    {:ok, backend} = CountingRela.start_link(300)

    copy =
      Collections.open({CountingRela, backend},
        collection_clock: fn -> CountingRela.clock(backend) end
      )

    %{backend: backend, copy: copy}
  end

  test "copies are lazy; every write discards all collections without row refreshes",
       c do
    assert CountingRela.calls(c.backend) == %{}
    for plural <- ["jars", "beads"], do: assert({:ok, _} = Rela.list(c.copy, plural))
    assert {:ok, []} = Rela.change(c.copy, "jars", "jar-1", %{"phase" => "sealed"}, nil, %{})
    assert {:ok, rows} = Rela.list(c.copy, "jars")
    assert %{properties: %{"phase" => "sealed"}, version: nil} = hd(rows)
    assert {:ok, []} = Rela.create(c.copy, "jars", "jar-new", %{"phase" => "new"}, %{})
    assert {:ok, rows} = Rela.list(c.copy, "jars")
    assert List.last(rows).key == "jar-new"
    assert :ok = Rela.delete(c.copy, "jars", "jar-new", nil)
    assert {:ok, rows} = Rela.list(c.copy, "jars")
    refute Enum.any?(rows, &(&1.key == "jar-new"))
    assert {:ok, _} = Rela.list(c.copy, "beads")
    assert CountingRela.calls(c.backend)[{:list, "jars"}] == 4
    assert CountingRela.calls(c.backend)[{:list, "beads"}] == 2
    refute CountingRela.calls(c.backend)[:get]
  end

  test "point reads after a list use the fresh copy, including missing keys", c do
    assert {:ok, rows} = Rela.list(c.copy, "jars")
    CountingRela.reset(c.backend)
    CountingRela.advance(c.backend, 4_999)
    assert {:ok, hd(rows)} == Rela.get(c.copy, "jars", "jar-1")
    assert {:error, :not_found} = Rela.get(c.copy, "jars", "absent")
    assert CountingRela.calls(c.backend) == %{}
  end

  test "unloaded and expired point reads read through without loading a collection", c do
    assert {:ok, %{version: "v1"}} = Rela.get(c.copy, "jars", "jar-1")
    assert CountingRela.calls(c.backend) == %{get: 1}
    assert {:ok, _} = Rela.list(c.copy, "jars")
    CountingRela.advance(c.backend, 5_000)

    assert {:ok, []} =
             CountingRela.change(c.backend, "jars", "jar-1", %{"phase" => "outside"}, nil, %{})

    CountingRela.reset(c.backend)

    assert {:ok, %{properties: %{"phase" => "outside"}, version: "v1"}} =
             Rela.get(c.copy, "jars", "jar-1")

    assert CountingRela.calls(c.backend) == %{get: 1}
    Agent.update(c.backend, &%{&1 | down: true})
    assert {:error, :unavailable} = Rela.get(c.copy, "jars", "jar-1")
  end

  test "mutation checks use current backend rows and discard the shared copy", c do
    assert {:ok, _} = Rela.list(c.copy, "jars")
    write = Collections.uncached(c.copy)

    assert {:ok, []} =
             CountingRela.change(c.backend, "jars", "jar-1", %{"phase" => "outside"}, nil, %{})

    assert {:ok, %{properties: %{"phase" => "outside"}, version: "v1"}} =
             Rela.get(write, "jars", "jar-1")

    assert {:ok, rows} = Rela.list(write, "jars")
    assert hd(rows).properties["phase"] == "outside"

    assert {:ok, []} = Rela.change(write, "jars", "jar-1", %{"phase" => "local"}, "v1", %{})
    CountingRela.reset(c.backend)
    assert {:ok, %{properties: %{"phase" => "local"}}} = Rela.get(c.copy, "jars", "jar-1")
    assert CountingRela.calls(c.backend) == %{get: 1}
  end

  test "mutations release all copies on success or failure", c do
    Collections.mutation(c.copy, fn ->
      assert {:ok, _} = Rela.list(c.copy, "jars")
      assert {:ok, _} = Rela.list(c.copy, "jars")
    end)

    assert CountingRela.calls(c.backend)[{:list, "jars"}] == 1

    assert {:ok, []} =
             CountingRela.change(c.backend, "jars", "jar-1", %{"phase" => "outside"}, nil, %{})

    Collections.mutation(c.copy, fn ->
      assert {:ok, rows} = Rela.list(c.copy, "jars")
      assert hd(rows).properties["phase"] == "outside"
    end)

    assert CountingRela.calls(c.backend)[{:list, "jars"}] == 2

    assert_raise RuntimeError, "failed render", fn ->
      Collections.mutation(c.copy, fn ->
        Rela.list(c.copy, "jars")
        raise "failed render"
      end)
    end

    CountingRela.reset(c.backend)
    assert {:ok, %{version: "v1"}} = Rela.get(c.copy, "jars", "jar-1")
    assert CountingRela.calls(c.backend) == %{get: 1}
  end

  test "outside writes appear at the exact freshness bound", c do
    {:ok, _} = Rela.list(c.copy, "jars")
    CountingRela.advance(c.backend, 4_999)
    {:ok, []} = CountingRela.change(c.backend, "jars", "jar-2", %{"phase" => "outside"}, nil, %{})
    {:ok, rows} = Rela.list(c.copy, "jars")
    refute Enum.any?(rows, &(&1.properties["phase"] == "outside"))
    CountingRela.advance(c.backend, 1)
    {:ok, rows} = Rela.list(c.copy, "jars")
    assert Enum.any?(rows, &(&1.properties["phase"] == "outside"))
    assert CountingRela.calls(c.backend)[{:list, "jars"}] == 2
  end

  test "expired copies and failed mutations never mask backend errors", c do
    {:ok, _} = Rela.list(c.copy, "jars")
    Agent.update(c.backend, &%{&1 | down: true})
    assert {:error, :unavailable} = Rela.change(c.copy, "jars", "jar-1", %{}, nil, %{})
    assert {:error, :unavailable} = Rela.list(c.copy, "jars")
    Agent.update(c.backend, &%{&1 | down: false})
    assert {:ok, _} = Rela.list(c.copy, "jars")
    CountingRela.advance(c.backend, 5_000)
    Agent.update(c.backend, &%{&1 | down: true})
    assert {:error, :unavailable} = Rela.list(c.copy, "jars")
  end

  test "warnings and lost write responses evict every collection", c do
    {:ok, _} = Rela.list(c.copy, "jars")

    for reply <- [{:ok, ["stored with warnings"]}, {:error, :unavailable}] do
      Agent.update(c.backend, &Map.put(&1, :write_reply, reply))
      assert Rela.change(c.copy, "jars", "jar-1", %{"phase" => inspect(reply)}, nil, %{}) == reply
      {:ok, rows} = Rela.list(c.copy, "jars")
      assert hd(rows).properties["phase"] == inspect(reply)
    end

    assert CountingRela.calls(c.backend)[{:list, "jars"}] == 3
    refute CountingRela.calls(c.backend)[:get]
  end

  test "deletion evicts all collections including rows with incoming links", c do
    for plural <- ["stamps", "beads", "boxes"], do: assert({:ok, _} = Rela.list(c.copy, plural))
    assert :ok = Rela.delete(c.copy, "stamps", "stamp-1", nil)
    assert {:ok, rows} = Rela.list(c.copy, "beads")
    assert hd(rows).links["sealed_by"] == []
    assert {:ok, rows} = Rela.list(c.copy, "stamps")
    refute Enum.any?(rows, &(&1.key == "stamp-1"))

    assert {:ok, _} = Rela.list(c.copy, "boxes")

    for plural <- ["stamps", "beads", "boxes"],
        do: assert(CountingRela.calls(c.backend)[{:list, plural}] == 2)

    refute CountingRela.calls(c.backend)[:get]
  end
end

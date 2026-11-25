defmodule AtlasFacts.ReadWhileWritingTest do
  @moduledoc """
  Reads do not wait behind writes (IS-Atlas-85): the Bus answers them in the process that
  sends them, from the copy as Facts last published it, while Facts waits for rela. A
  sender still reads its own write, and no read sees a write half applied.
  """
  use ExUnit.Case, async: false
  alias AtlasBus.Envelope
  alias AtlasFacts.SlowRela
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    store = "while-writing-#{System.unique_integer([:positive])}"
    Application.put_env(:atlas_bus, :store, store)
    rela = SlowRela.start(60)

    start_supervised!(
      {AtlasFacts.Server, rela: {SlowRela, rela}, model: AtlasFacts.Counting, data_dir: dir}
    )

    :ok = AtlasBus.attach("control/session-reader-#{System.unique_integer([:positive])}")
    %{rela: rela, store: store}
  end

  defp request(class, kind, content) do
    e = Envelope.new(class, kind)
    :ok = AtlasBus.send(e, content)
    id = e.id
    assert_receive {:atlas_bus, %Envelope{id: ^id}, answer}, 2_000
    answer
  end

  defp point(kind, key), do: request("read", kind, %{"key" => key, "plain" => true})
  defp keys(kind), do: for(f <- request("read", kind, %{})["facts"], do: f["key"])

  # A write from another endpoint (Flow, say), that waits for its answer.
  defp writing(kind, content) do
    Task.async(fn ->
      :ok = AtlasBus.attach("flow-writer-#{System.unique_integer([:positive])}")
      request("fact", kind, content)
    end)
  end

  test "a read is answered while a slow write to rela is still pending", c do
    before = point("bead", "bead-1")
    SlowRela.hold(c.rela)

    writer =
      writing("bead", %{"op" => "change", "key" => "bead-1", "values" => %{"phase" => "sealed"}})

    assert_receive {:write_pending, _}, 2_000

    # rela has not answered the write: the read is answered all the same, as it was.
    during = point("bead", "bead-1")
    assert during["fact"]["values"]["phase"] == "packing"
    assert during["position"] == before["position"]
    assert Task.yield(writer, 0) == nil

    SlowRela.open(c.rela)
    assert %{"changes" => [_]} = Task.await(writer)
    later = point("bead", "bead-1")
    assert later["fact"]["values"]["phase"] == "sealed"
    assert later["position"] == before["position"] + 1
  end

  test "a sender's read waits for the fact it sent before", c do
    SlowRela.hold(c.rela)
    fact = Envelope.new("fact", "bead")

    :ok =
      AtlasBus.send(fact, %{"op" => "change", "key" => "bead-2", "values" => %{"phase" => "x"}})

    assert_receive {:write_pending, _}, 2_000

    read = Envelope.new("read", "bead")
    :ok = AtlasBus.send(read, %{"key" => "bead-2", "plain" => true})
    # Not answered where it was sent: it waits at Facts, after the fact.
    read_id = read.id
    refute_received {:atlas_bus, %Envelope{id: ^read_id}, _}
    assert AtlasBus.waiting(c.store) == 1

    SlowRela.open(c.rela)
    fact_id = fact.id
    assert_receive {:atlas_bus, %Envelope{id: ^fact_id, class: "stored"}, _}, 2_000
    assert_receive {:atlas_bus, %Envelope{id: ^read_id, class: "answer"}, answer}, 2_000
    assert answer["fact"]["values"]["phase"] == "x"

    # Answered: the next read is answered where it is sent again, at once.
    read = Envelope.new("read", "bead")
    :ok = AtlasBus.send(read, %{"key" => "bead-2", "plain" => true})
    read_id = read.id
    assert_received {:atlas_bus, %Envelope{id: ^read_id, class: "answer"}, _}
  end

  test "a read never sees a write half applied", c do
    SlowRela.hold(c.rela)
    writer = writing("box", %{"op" => "create", "key" => "box-new", "values" => %{}})

    # The box's component (its tag) is made in rela first, then the box.
    assert_receive {:write_pending, _}, 2_000
    SlowRela.release(c.rela)
    assert_receive {:write_pending, _}, 2_000

    # rela holds the tag, not the box yet: a read sees neither.
    assert point("tag", "T-box-new")["fact"] == nil
    assert point("box", "box-new")["fact"] == nil
    refute "T-box-new" in keys("tag")

    SlowRela.open(c.rela)
    assert %{"changes" => [_, _]} = Task.await(writer)
    assert point("box", "box-new")["fact"]["links"]["tagged"] == ["T-box-new"]
    assert point("tag", "T-box-new")["fact"]["key"] == "T-box-new"
  end
end

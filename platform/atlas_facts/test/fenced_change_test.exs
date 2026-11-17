defmodule AtlasFacts.FencedChangeTest do
  @moduledoc """
  A change with `version` and `was` is a compare-and-set on every field it sets, a field
  it sets to the value it read included: the fenced write a lease's writers rely on. A
  writer sets the fence field unchanged with its other fields; another writer moving the
  fence, or changing one of those fields, makes Facts refuse the change. Only the answer
  class, the facts in the test rela and their versions are asserted, never wording.
  """
  use ExUnit.Case, async: false

  alias AtlasBus.Envelope
  alias AtlasFacts.FakeRela

  @moduletag :tmp_dir

  defmodule Fenced do
    @moduledoc "The workshop, with a fence field and a counter on a widget."
    use AtlasFacts.TestModel,
      description:
        AtlasFacts.Workshop.Description.with(%{
          "entities" => %{
            "widget" => %{
              "properties" => %{
                "lease_id" => %{"type" => "string"},
                "x" => %{"type" => "integer"}
              }
            }
          }
        })
  end

  @key "W-1"
  @fence "L-1"

  setup %{tmp_dir: dir} do
    Application.put_env(:atlas_bus, :store, "fenced-#{System.unique_integer([:positive])}")
    rela = FakeRela.start(Fenced)
    start_supervised!({AtlasFacts.Server, rela: {FakeRela, rela}, data_dir: dir, model: Fenced})
    :ok = AtlasBus.attach("tester-#{System.unique_integer([:positive])}")

    assert {"stored", _} =
             send_fact(%{
               "op" => "create",
               "key" => @key,
               "values" => %{"title" => "One", "lease_id" => @fence, "x" => 0}
             })

    %{"fact" => %{"version" => version}} = read(@key)
    %{rela: rela, version: version}
  end

  # The change a fenced writer sends on lease `@fence`: the fence unchanged, `x` 0 → 1.
  defp fenced_change(version),
    do: %{
      "op" => "change",
      "key" => @key,
      "values" => %{"lease_id" => @fence, "x" => 1},
      "version" => version,
      "was" => %{"lease_id" => @fence, "x" => 0}
    }

  defp send_fact(content), do: send_fact(Envelope.new("fact", "widget"), content)

  defp send_fact(envelope, content) do
    :ok = AtlasBus.send(envelope, content)
    id = envelope.id
    assert_receive {:atlas_bus, %Envelope{id: ^id} = reply, answer}, 1_000
    {reply.class, answer}
  end

  defp read(key) do
    envelope = Envelope.new("read", "widget")
    :ok = AtlasBus.send(envelope, %{"key" => key})
    id = envelope.id
    assert_receive {:atlas_bus, %Envelope{id: ^id, class: "answer"}, answer}, 1_000
    answer
  end

  defp stored(rela), do: FakeRela.facts(rela)[@key]

  # Another writer changes `values` behind the sender's back, so its version is stale.
  defp meanwhile(rela, version, values) do
    FakeRela.poke(rela, @key, values)
    assert %{"fact" => %{"version" => current}} = read(@key)
    assert current != version
  end

  test "1. stored on a stale version while the fence and x are as read", %{
    rela: rela,
    version: version
  } do
    meanwhile(rela, version, %{"done" => true})

    assert {"stored", _} = send_fact(fenced_change(version))

    assert {%{"lease_id" => @fence, "x" => 1, "done" => true}, _} = stored(rela)
  end

  test "2. refused when another write moved the unchanged fence", %{
    rela: rela,
    version: version
  } do
    meanwhile(rela, version, %{"lease_id" => "L-2"})
    before = stored(rela)

    assert {"refused", %{"reasons" => [_ | _]}} = send_fact(fenced_change(version))

    assert {%{"lease_id" => "L-2", "x" => 0}, _} = stored(rela)
    assert stored(rela) == before
  end

  test "3. refused when another write changed x", %{rela: rela, version: version} do
    meanwhile(rela, version, %{"x" => 5})
    before = stored(rela)

    assert {"refused", %{"reasons" => [_ | _]}} = send_fact(fenced_change(version))

    assert {%{"lease_id" => @fence, "x" => 5}, _} = stored(rela)
    assert stored(rela) == before
  end

  test "4. an exact replay under a new message id is stored and changes nothing", %{
    rela: rela,
    version: version
  } do
    meanwhile(rela, version, %{"done" => true})
    first = Envelope.new("fact", "widget")
    assert {"stored", _} = send_fact(first, fenced_change(version))
    after_first = stored(rela)
    assert {%{"lease_id" => @fence, "x" => 1}, _} = after_first

    # The same stale version, values and was; a new id, so the ledger cannot answer it.
    replay = Envelope.new("fact", "widget")
    assert replay.id != first.id
    assert {"stored", _} = send_fact(replay, fenced_change(version))

    # Nothing changed: the same values, and no write reached rela (same version).
    assert stored(rela) == after_first
  end
end

defmodule AtlasFacts.CollectionReadsTest do
  use ExUnit.Case, async: false
  alias AtlasBus.Envelope
  alias AtlasFacts.CountingRela
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(
      :atlas_bus,
      :store,
      "collection-reads-#{System.unique_integer([:positive])}"
    )

    {:ok, backend} = CountingRela.start_link(300)

    start_supervised!(
      {AtlasFacts.Server,
       rela: {CountingRela, backend},
       data_dir: dir,
       collection_clock: fn -> CountingRela.clock(backend) end}
    )

    :ok = AtlasBus.attach("control/collection-reads-#{System.unique_integer([:positive])}")
    %{backend: backend}
  end

  defp request(class, kind, content) do
    envelope = Envelope.new(class, kind)
    :ok = AtlasBus.send(envelope, content)
    id = envelope.id
    assert_receive {:atlas_bus, %Envelope{id: ^id}, answer}, 1_000
    answer
  end

  defp read(kind, content \\ %{}), do: request("read", kind, content)

  test "independent sweeps share fresh collections across requests", c do
    for pass <- 1..2 do
      if pass == 2, do: CountingRela.reset(c.backend)

      for kind <- Map.keys(CountingRela.schema()["entities"]) do
        answer = read(kind)
        assert length(answer["facts"]) == 50

        for fact <- answer["facts"] do
          assert %{"fact" => %{"key" => key}} =
                   read(kind, %{"key" => fact["key"], "incoming" => false})

          assert key == fact["key"]
        end
      end

      calls = CountingRela.calls(c.backend)

      lists = for {{:list, _}, n} <- calls, do: n
      assert Enum.sum(lists) == if(pass == 1, do: 6, else: 0)
      refute calls[:get]
      assert Enum.sum(Map.values(calls)) == if(pass == 1, do: 7, else: 0)
    end
  end

  test "a write through Facts changes derived parent answers immediately", _c do
    assert hd(read("box")["facts"])["progress"]["value"] == "packing"

    answer =
      request("fact", "bead", %{
        "op" => "change",
        "key" => "bead-1",
        "values" => %{"phase" => "sealed"}
      })

    refute answer["reasons"]
    assert hd(read("box")["facts"])["progress"]["value"] == "sealed"
  end

  test "the owner header's collection plan costs at most six backend calls cold", c do
    # The same ordinary collections as Control's assigned plan: tags and the
    # three owner kinds. Progress adds the stamp collection; schema is one call.
    assert %{"answers" => answers} = read("_page", %{"kinds" => ["tag", "box", "jar", "bead"]})
    assert length(answers) == 4
    assert Enum.all?(answers, &is_list(&1["facts"]))
    assert Enum.sum(Map.values(CountingRela.calls(c.backend))) <= 6
    CountingRela.reset(c.backend)
    assert %{"answers" => ^answers} = read("_page", %{"kinds" => ["tag", "box", "jar", "bead"]})
    assert CountingRela.calls(c.backend) == %{}
  end

  test "nested linked reads reuse collections on the next request", c do
    content = %{"linked" => %{"in_box" => %{"tagged" => "tag-1"}}, "plain" => true}
    assert length(read("jar", content)["facts"]) == 1
    assert length(read("jar", content)["facts"]) == 1
    assert CountingRela.calls(c.backend)[{:list, "boxes"}] == 1
    assert CountingRela.calls(c.backend)[{:list, "jars"}] == 1
  end
end

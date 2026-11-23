defmodule AtlasFacts.CacheTest do
  use ExUnit.Case, async: false
  alias AtlasBus.Envelope
  alias AtlasFacts.CountingRela
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:atlas_bus, :store, "cache-#{System.unique_integer([:positive])}")
    {:ok, backend} = CountingRela.start_link(300)

    start_supervised!(
      {AtlasFacts.Server,
       model: AtlasFacts.Counting, rela: {CountingRela, backend}, data_dir: dir}
    )

    :ok = AtlasBus.attach("control/cache-#{System.unique_integer([:positive])}")
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

  test "every kind is listed once, at start; reads of all kinds then reach rela no more", c do
    lists = for {{:list, _}, n} <- CountingRela.calls(c.backend), do: n
    assert lists == List.duplicate(1, map_size(CountingRela.schema()["entities"]))
    CountingRela.reset(c.backend)

    for kind <- Map.keys(CountingRela.schema()["entities"]) do
      answer = read(kind)
      assert length(answer["facts"]) == 50

      for fact <- answer["facts"] do
        assert %{"fact" => %{"key" => key}} = read(kind, %{"key" => fact["key"]})
        assert key == fact["key"]
      end
    end

    assert length(read("jar", %{"linked" => %{"in_box" => %{"tagged" => "tag-1"}}})["facts"]) == 1
    assert %{"answers" => [_, _]} = read("_page", %{"reads" => [["tag", %{}], ["box", %{}]]})
    assert CountingRela.calls(c.backend) == %{}
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
end

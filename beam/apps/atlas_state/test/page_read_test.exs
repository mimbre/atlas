defmodule AtlasState.PageReadTest do
  use ExUnit.Case, async: false
  alias AtlasBus.Envelope

  defmodule Backend do
    def description(_) do
      {:ok,
       %{
         "entities" => %{
           "box" => %{
             "plural" => "boxes",
             "progress" => %{"over" => "in_box", "field" => "phase"}
           },
           "jar" => %{
             "plural" => "jars",
             "completion" => %{"by" => "signed_by"},
             "properties" => %{"phase" => %{"labels" => %{}}}
           },
           "execution" => %{"plural" => "executions"}
         },
         "relations" => %{
           "in_box" => %{"from" => ["jar"], "to" => ["box"]},
           "signed_by" => %{"from" => ["jar"], "to" => ["clerk"]}
         },
         "progress" => %{
           "order" => ["packing", "sealed", "check"],
           "to_test" => %{"value" => "check", "label" => "Check"}
         },
         "guidance" => %{"execution" => %{"kind" => "execution"}}
       }}
    end

    def list(agent, plural) do
      Agent.get_and_update(agent, fn state ->
        state = update_in(state.calls, &Map.update(&1, plural, 1, fn n -> n + 1 end))

        if state.unavailable or (plural == "jars" and state.fail_once) do
          {{:error, :unavailable}, %{state | fail_once: false}}
        else
          facts =
            case plural do
              "boxes" ->
                [%{key: "B-1", properties: %{}, links: %{}, version: nil}]

              "jars" ->
                [
                  %{
                    key: "J-1",
                    properties: %{"phase" => state.phase},
                    links: %{
                      "in_box" => ["B-1"],
                      "signed_by" => if(state.complete, do: ["K-1"], else: [])
                    },
                    version: nil
                  }
                ]
            end

          {{:ok, facts}, state}
        end
      end)
    end
  end

  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    Application.put_env(:atlas_bus, :store, "page-read-#{System.unique_integer([:positive])}")

    {:ok, backend} =
      Agent.start_link(fn ->
        %{calls: %{}, phase: "packing", fail_once: false, unavailable: false, complete: false}
      end)

    start_supervised!({AtlasState.Server, rela: {Backend, backend}, data_dir: dir})
    :ok = AtlasBus.attach("control/session-page-#{System.unique_integer([:positive])}")
    %{backend: backend}
  end

  defp read(kind, content \\ %{}) do
    envelope = Envelope.new("read", kind)
    :ok = AtlasBus.send(envelope, content)
    id = envelope.id
    assert_receive {:atlas_bus, %Envelope{id: ^id, class: "answer"}, answer}, 1_000
    answer
  end

  defp batch, do: read("_page", %{"kinds" => ["box", "jar"]})["answers"]

  test "complete enriched results match ordinary reads and later requests see fresh facts", c do
    ordinary = [read("box"), read("jar")]
    Agent.update(c.backend, &%{&1 | calls: %{}})
    assert batch() == ordinary
    assert Agent.get(c.backend, & &1.calls) == %{"boxes" => 1, "jars" => 1}

    Agent.update(c.backend, &%{&1 | phase: "sealed"})
    [boxes, jars] = batch()
    assert hd(boxes["facts"])["progress"]["value"] == "sealed"
    assert hd(jars["facts"])["values"]["phase"] == "sealed"
    Agent.update(c.backend, &%{&1 | phase: "packing"})
    assert hd(read("box")["facts"])["progress"]["value"] == "packing"
  end

  test "dependency failures remain visible and are not reused as successful data", c do
    Agent.update(c.backend, &%{&1 | fail_once: true})
    ordinary = [read("box"), read("jar")]
    Agent.update(c.backend, &%{&1 | fail_once: true, calls: %{}})
    assert batch() == ordinary
    assert hd(ordinary)["error_kind"] == "unreachable"
    assert Agent.get(c.backend, & &1.calls["jars"]) == 2
    assert hd(batch())["facts"] != nil
  end

  test "reused child lists retain completion evidence and parent progress", c do
    Agent.update(c.backend, &%{&1 | complete: true})
    ordinary = [read("box"), read("jar")]
    assert batch() == ordinary
    [boxes, jars] = ordinary
    assert hd(boxes["facts"])["progress"]["value"] == "check"

    assert hd(jars["facts"])["completion"] == %{
             "done" => true,
             "by" => "signed_by",
             "keys" => ["K-1"]
           }
  end

  test "backend loss does not return cached facts and recovery rereads them", c do
    batch()
    Agent.update(c.backend, &%{&1 | unavailable: true})
    assert Enum.all?(batch(), &(&1["error_kind"] == "unreachable"))
    Agent.update(c.backend, &%{&1 | unavailable: false, phase: "sealed"})
    [boxes, jars] = batch()
    assert hd(boxes["facts"])["progress"]["value"] == "sealed"
    assert hd(jars["facts"])["values"]["phase"] == "sealed"
  end

  test "batch entry cannot bypass restricted reads or accept another query context" do
    for content <- [
          %{"kinds" => ["execution"]},
          %{"kinds" => ["box"], "linked" => %{}},
          %{"kinds" => []}
        ] do
      assert %{"error" => _} = read("_page", content)
    end
  end

  test "only a Control endpoint may use the internal page read" do
    result =
      Task.async(fn ->
        :ok = AtlasBus.attach("other/page-#{System.unique_integer([:positive])}")
        read("_page", %{"kinds" => ["box"]})
      end)
      |> Task.await()

    assert result["code"] == "forbidden"
  end
end

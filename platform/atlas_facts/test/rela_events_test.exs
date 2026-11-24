defmodule AtlasFacts.RelaEventsTest do
  use ExUnit.Case, async: false

  alias AtlasBus.Envelope
  alias AtlasFacts.{FakeRela, Rela.Events, Workshops}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:atlas_bus, :store, "events-#{System.unique_integer([:positive])}")
    rela = FakeRela.start(Workshops.Synced)

    server =
      start_supervised!(
        {AtlasFacts.Server, rela: {FakeRela, rela}, data_dir: dir, model: Workshops.Synced}
      )

    :ok = AtlasBus.attach("tester-#{System.unique_integer([:positive])}")
    %{rela: rela, server: server}
  end

  defp send_and_wait(class, kind, content) do
    envelope = Envelope.new(class, kind)
    :ok = AtlasBus.send(envelope, content)
    id = envelope.id
    assert_receive {:atlas_bus, %Envelope{id: ^id}, answer}, 1_000
    answer
  end

  test "a kind written past Facts is read again when rela says it changed, and hinted", c do
    send_and_wait("fact", "widget", %{"op" => "create", "key" => "W-1", "values" => %{"title" => "One"}})
    :ok = AtlasBus.listen("widget")

    FakeRela.poke(c.rela, "W-1", %{"title" => "Synced"})
    send(c.server, {:rela_changed, ["widget"]})

    assert_receive {:atlas_bus, %Envelope{class: "stored", kind: "widget", position: 2},
                    %{"op" => "change", "key" => "W-1", "by" => "rela", "changes" => [change]}},
                   1_000

    assert change["fields"] == ["title"]
    assert %{"fact" => %{"values" => %{"title" => "Synced"}}} =
             send_and_wait("read", "widget", %{"key" => "W-1"})

    # Read again with nothing changed: no hint.
    send(c.server, {:rela_changed, :all})
    refute_receive {:atlas_bus, %Envelope{class: "stored"}, _}, 200
  end

  test "rela's events become the kinds that changed; a first frame that cannot resume, all" do
    {frames, rest} =
      Events.frames(
        "event: ready\nid: a\ndata: {\"conn\":\"c\"}\n\nevent: entity:changed\nid: b\ndata: {\"type\":\"widget\"}\n\nevent: pi"
      )

    assert [%{"event" => "ready", "id" => "a"}, %{"event" => "entity:changed", "data" => ~s({"type":"widget"})}] =
             frames

    assert rest == "event: pi"
  end
end

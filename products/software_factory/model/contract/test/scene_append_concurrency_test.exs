defmodule Model.SceneAppendConcurrencyTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  @moduletag :tmp_dir

  alias AtlasBus.Envelope
  alias AtlasControl.Answers
  alias AtlasFacts.FakeRela
  alias Model.AtlasEyra

  setup %{tmp_dir: dir} do
    environment = Application.get_env(:atlas_bus, :environment)
    store = Application.get_env(:atlas_bus, :store)
    Application.put_env(:atlas_bus, :environment, "test")
    Application.put_env(:atlas_bus, :store, "append-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      restore_env(:atlas_bus, :environment, environment)
      restore_env(:atlas_bus, :store, store)
    end)

    {:ok, _} = Application.ensure_all_started(:atlas_bus)
    rela = FakeRela.start(AtlasEyra)
    {:ok, _} = FakeRela.create(rela, "people", "melle", %{}, %{})

    for key <- ["SC-Atlas-91", "SC-Atlas-92"] do
      {:ok, _} =
        FakeRela.create(rela, "scenes", key, %{"title" => "A scene", "answers" => "Existing"}, %{
          "produced_by" => {"person", ["melle"]}
        })
    end

    start_supervised!(
      {AtlasFacts.Server, rela: {FakeRela, rela}, data_dir: dir, model: AtlasEyra}
    )

    :ok = AtlasBus.attach("control/session-append-#{System.unique_integer([:positive])}")
    :ok
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp send_and_wait(class, key, content) when is_binary(class) do
    send_and_wait(Envelope.new(class, "scene"), key, content)
  end

  defp send_and_wait(envelope, key, content) do
    :ok = AtlasBus.send(envelope, Map.put(content, "key", key))
    id = envelope.id
    assert_receive {:atlas_bus, %Envelope{id: ^id, class: reply}, answer}, 2_000
    {reply, answer}
  end

  defp read_scene(key) do
    {"answer", %{"fact" => fact}} = send_and_wait("read", key, %{})
    fact
  end

  defp append(fact, label, line, note, values) do
    answer = %{
      "label" => label,
      "note" => true,
      "values" => values,
      "append" => %{"answers" => line},
      "current" => %{"answers" => fact["values"]["answers"]}
    }

    {:ok, content, cause} =
      Answers.change(
        answer,
        fact["key"],
        "melle",
        note,
        ~U[2026-11-24 09:00:00Z],
        fact["version"]
      )

    Map.merge(content, %{"by" => "melle", "cause" => cause})
  end

  test "a stale suggestion or clarification is refused without losing the first write" do
    suggestion = {"Suggest", "Suggested use case: {note}", "See the page", %{}}
    clarification = {"Answer", "{note}", "For newcomers", %{"verdict" => "answered"}}

    for {key, first, second, expected} <- [
          {"SC-Atlas-91", suggestion, clarification,
           "Existing\nSuggested use case: See the page\nFor newcomers"},
          {"SC-Atlas-92", clarification, suggestion,
           "Existing\nFor newcomers\nSuggested use case: See the page"}
        ] do
      snapshot = read_scene(key)
      assert snapshot["version"] != nil
      {first_label, first_line, first_note, first_values} = first
      {second_label, second_line, second_note, second_values} = second
      first_write = append(snapshot, first_label, first_line, first_note, first_values)
      stale_write = append(snapshot, second_label, second_line, second_note, second_values)

      assert {"stored", _} = send_and_wait("fact", key, first_write)
      assert {"refused", %{"reasons" => [reason | _]}} = send_and_wait("fact", key, stale_write)
      assert reason =~ "changed meanwhile"

      current = read_scene(key)
      assert current["values"]["answers"] == first_write["values"]["answers"]
      retry = append(current, second_label, second_line, second_note, second_values)
      assert {"stored", _} = send_and_wait("fact", key, retry)
      assert read_scene(key)["values"]["answers"] == expected
    end
  end

  test "identical independent suggestions refuse stale while the same request replays" do
    key = "SC-Atlas-91"
    snapshot = read_scene(key)
    write = append(snapshot, "Suggest", "Suggested use case: {note}", "See the page", %{})
    first = Envelope.new("fact", "scene")
    second = Envelope.new("fact", "scene")
    assert first.id != second.id

    assert {"stored", _} = recorded = send_and_wait(first, key, write)
    assert send_and_wait(first, key, write) == recorded
    assert {"refused", %{"reasons" => [reason | _]}} = send_and_wait(second, key, write)
    assert reason =~ "changed meanwhile"
    assert read_scene(key)["values"]["answers"] == "Existing\nSuggested use case: See the page"

    retry = append(read_scene(key), "Suggest", "Suggested use case: {note}", "See the page", %{})
    assert {"stored", _} = send_and_wait("fact", key, retry)
    assert read_scene(key)["values"]["answers"] ==
             "Existing\nSuggested use case: See the page\nSuggested use case: See the page"
  end
end

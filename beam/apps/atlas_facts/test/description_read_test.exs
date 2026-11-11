defmodule AtlasFacts.DescriptionReadTest do
  use ExUnit.Case, async: false
  alias AtlasBus.Envelope

  defmodule CountingBackend do
    def description(counter) do
      Agent.get_and_update(counter, fn s ->
        description = Map.put(AtlasFacts.FakeRela.description(), "probe_revision", s.revision)
        result = if s.up, do: {:ok, description}, else: {:error, :unavailable}
        {result, %{s | calls: s.calls + 1}}
      end)
    end
  end

  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    Application.put_env(
      :atlas_bus,
      :store,
      "description-read-#{System.unique_integer([:positive])}"
    )

    {:ok, counter} = Agent.start_link(fn -> %{calls: 0, revision: "first", up: true} end)
    start_supervised!({AtlasFacts.Server, rela: {CountingBackend, counter}, data_dir: dir})
    :ok = AtlasBus.attach("description-reader-#{System.unique_integer([:positive])}")
    %{counter: counter}
  end

  defp answer do
    envelope = Envelope.new("read", "_description")
    :ok = AtlasBus.send(envelope, %{})
    id = envelope.id
    assert_receive {:atlas_bus, %Envelope{id: ^id, class: "answer"}, answer}, 1_000
    answer
  end

  defp description, do: answer()["description"]

  test "one description read fetches exactly one authoritative backend snapshot", ctx do
    assert description()["probe_revision"] == "first"
    assert Agent.get(ctx.counter, & &1.calls) == 1
  end

  test "a later read fetches fresh metadata rather than retaining the earlier snapshot", ctx do
    assert description()["probe_revision"] == "first"
    Agent.update(ctx.counter, &%{&1 | revision: "second"})
    assert description()["probe_revision"] == "second"
    assert Agent.get(ctx.counter, & &1.calls) == 2
  end

  test "an unavailable fresh description fails explicitly without returning the old snapshot",
       ctx do
    assert description()["probe_revision"] == "first"
    before = Agent.get(ctx.counter, & &1.calls)
    Agent.update(ctx.counter, &%{&1 | up: false})
    result = answer()
    assert is_binary(result["error"])
    refute Map.has_key?(result, "description")
    assert Agent.get(ctx.counter, & &1.calls) - before == 1
  end

  test "the metadata read exception does not allow a fact of the reserved kind" do
    envelope = Envelope.new("fact", "_description")
    :ok = AtlasBus.send(envelope, %{"op" => "create", "key" => "D-1", "values" => %{}})
    id = envelope.id

    assert_receive {:atlas_bus, %Envelope{id: ^id, class: "refused"}, answer}, 1_000
    assert Enum.any?(answer["reasons"], &String.contains?(&1, "_description"))
  end
end

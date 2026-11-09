defmodule AtlasE2E.RuntimeTeardownTest do
  use ExUnit.Case, async: false
  alias AtlasE2E.{Instance, Scenario}

  @tag timeout: 120_000
  test "ended Runtime fixture teardown does not grant Control fenced-turn authority" do
    i = Instance.start()

    on_exit(fn ->
      Instance.stop(i)
      # Instance is normally owned by the standalone e2e VM. This unit fixture must
      # also release its unlinked named stand-in before another fixture starts one.
      if pid = Process.whereis(AtlasE2E.GitHub), do: Agent.stop(pid)
    end)

    IO.puts("private teardown fixture retained: #{i.dir}")
    Scenario.atlas_json(i, ["put", "agent", "--name", "Runner"])
    Scenario.atlas_json(i, ["put", "agent", "--name", "Bystander"])
    {scene, _} = Scenario.atlas_json(i, ["put", "scene", "--title", "Private fenced teardown"])

    {uc, _} =
      Scenario.atlas_json(i, ["put", "use_case", "--in", scene["key"], "--title", "Private turn"])

    Scenario.atlas_json(i, ["set", uc["key"], "assigned_to=runner", "--cause", "private fixture"])
    turn = "TU-AS-#{uc["key"]}-1"
    await_state(i, turn, "Running")
    assert is_binary(Instance.rela_get(i, "/turns/#{turn}")["properties"]["attempt"])

    Scenario.atlas_json(i, [
      "set",
      uc["key"],
      "assigned_to=bystander",
      "--cause",
      "fixture finished"
    ])

    await_state(i, turn, "Ended")
    # The original Control request stays refused; the repair grants it no authority.
    {_, status, _} = Scenario.atlas(i, ["delete", turn])
    assert status != 0
    assert :ok = Instance.cleanup_turn_fixtures(i, [turn])
    {_, status, _} = Scenario.atlas(i, ["get", turn])
    assert status != 0
    Scenario.atlas_json(i, ["delete", uc["key"]])
    Scenario.atlas_json(i, ["delete", scene["key"]])
  end

  test "fixture cleanup rejects ordinary configured environments before stopping anything" do
    assert_raise ArgumentError, ~r/private test backend/, fn ->
      Instance.cleanup_turn_fixtures(
        %Instance{dir: "/not-a-private-run", settings: %{"env" => "prod"}},
        ["turn"]
      )
    end
  end

  defp await_state(i, key, expected, tries \\ 100)
  defp await_state(_, key, expected, 0), do: flunk("#{key} never became #{expected}")

  defp await_state(i, key, expected, tries) do
    {out, status, _} = Scenario.atlas(i, ["get", key, "--json"])
    fields = if status == 0, do: JSON.decode!(out)["fields"], else: []

    if ["State", expected] not in fields do
      Process.sleep(100)
      await_state(i, key, expected, tries - 1)
    end
  end
end

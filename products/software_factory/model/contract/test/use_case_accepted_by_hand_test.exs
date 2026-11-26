defmodule Model.UseCaseAcceptedByHandTest do
  @moduledoc """
  Flows are not magical: a use case accepted by hand (`phase: accepted`, which completes
  it) counts as accepted for its scene, as one its acceptance run accepted does. Run by
  `AtlasFlow.Runs.Store` with `AtlasFlow.FakeFacts`, each reconcile a restart over what
  Facts holds.
  """
  use ExUnit.Case, async: false

  alias AtlasFlow.FakeFacts
  alias AtlasFlow.Runs.Store

  @now ~U[2026-11-26 09:00:00Z]

  setup do
    Application.put_env(:atlas_bus, :store, "by-hand-#{System.unique_integer([:positive])}")
    environment = Application.get_env(:atlas_bus, :environment)
    Application.put_env(:atlas_bus, :environment, "test")

    on_exit(fn ->
      if environment,
        do: Application.put_env(:atlas_bus, :environment, environment),
        else: Application.delete_env(:atlas_bus, :environment)
    end)

    {:ok, _} = Application.ensure_all_started(:atlas_bus)
    start_supervised!(FakeFacts)
    :ok = AtlasBus.attach("flow")

    runner = AtlasFlow.Model.load(Model.AtlasEyra, :prod, %{"decider" => "someone"})
    assert runner.refusal == nil
    %{runner: runner}
  end

  test "a use case accepted by hand while its acceptance waits: its scene goes to Accept", c do
    FakeFacts.put("scene", %{"key" => "SC-1", "values" => %{"title" => "S", "phase" => "accept"}})
    use_case("UC-1", "accepted")
    use_case("UC-2", "accept")

    # Nothing under UC-2: its acceptance hands it back to its break-down and waits.
    reconcile(c)
    assert at(c, "accept_use_case", "use_case", "UC-2") == {"breaking_down", "active"}
    assert counts("SC-1") == %{"children" => 2, "open_children" => 1}
    assert at(c, "accept_scene", "scene", "SC-1") == {"building", "active"}

    # Accepted by hand, as `atlas set UC-2 phase=accepted` does: Facts derives it completed.
    use_case("UC-2", "accepted")
    reconcile(c)

    assert at(c, "accept_use_case", "use_case", "UC-2") == {"accepted", "completed"}
    assert counts("SC-1") == %{"children" => 2, "open_children" => 0}
    assert at(c, "accept_scene", "scene", "SC-1") == {"to_accept", "active"}
  end

  # A use case of SC-1 in `phase`; accepted, completed as Facts derives it (its completion).
  defp use_case(key, phase) do
    version = (FakeFacts.get("use_case", key) || %{})["version"] || 0

    fact = %{
      "key" => key,
      "version" => version + 1,
      "values" => %{"title" => key, "phase" => phase},
      "links" => %{"in_scene" => ["SC-1"]}
    }

    completion = %{"done" => true, "field" => "phase", "value" => "accepted"}

    FakeFacts.put(
      "use_case",
      if(phase == "accepted", do: Map.put(fact, "completion", completion), else: fact)
    )
  end

  defp reconcile(c) do
    for _ <- 1..3, do: assert({:ok, _} = Store.reconcile(c.runner.config, c.runner.flows, @now))
  end

  defp counts(key),
    do: Map.take(FakeFacts.get("scene", key)["values"], ~w(children open_children))

  defp at(c, flow, kind, key) do
    {:ok, run} = Store.latest(c.runner.config, flow, kind, key)
    {run["state"], run["status"]}
  end
end

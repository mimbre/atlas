defmodule Model.RuntimeUpgradeCreateTest do
  @moduledoc """
  UC-Atlas-50: its supervisor creates a Runtime upgrade as Control's create form makes it
  (what it asks and its defaults), and Facts takes it; its run starts at the first step,
  `requested`, from where Flow's work source moves it on. Structure, not wording.
  """
  use ExUnit.Case, async: false

  alias AtlasFlow.FakeFacts
  alias AtlasFlow.Runs.Store

  @now ~U[2026-11-26 09:00:00Z]

  defp lookup do
    %{
      "current" => fn -> nil end,
      "fact" => fn _, _ -> nil end,
      "list" => fn _ -> {:ok, []} end,
      "incoming" => fn _, _, _ -> [] end,
      "fingerprint" => &AtlasBus.SubjectFingerprint.of/2
    }
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  setup do
    Application.put_env(:atlas_bus, :store, "upgrade-#{System.unique_integer([:positive])}")
    environment = Application.get_env(:atlas_bus, :environment)
    Application.put_env(:atlas_bus, :environment, "test")
    on_exit(fn -> restore_env(:atlas_bus, :environment, environment) end)

    {:ok, _} = Application.ensure_all_started(:atlas_bus)
    start_supervised!(FakeFacts)
    :ok = AtlasBus.attach("flow")
    FakeFacts.put("person", %{"key" => "someone"})
    FakeFacts.put("machinery", %{"key" => "mini", "values" => %{"name" => "mini"}})
    :ok
  end

  test "its supervisor creates a runtime upgrade; its run starts at the first step" do
    form = Model.AtlasEyra.form("runtime_upgrade", :create)
    values = Map.new(form.defaults, fn {k, v} -> {to_string(k), to_string(v)} end)
    values = Map.put(values, "build", "b2")
    create = %{"op" => "create", "key" => "RU-01", "values" => values, "links" => %{}}

    assert Model.AtlasEyra.check("runtime_upgrade", create, %{"by" => "someone"}, lookup()) ==
             :ok

    FakeFacts.put("runtime_upgrade", %{
      "key" => "RU-01",
      "values" => values,
      "links" => %{"upgrade_of" => ["mini"]}
    })

    runner = AtlasFlow.Model.load(Model.AtlasEyra, :test, %{"decider" => "someone"})
    assert runner.refusal == nil
    {:ok, %{runs: known}} = Store.plan(runner.config, runner.flows)

    assert {:ok, runs} =
             Store.reconcile_subjects(runner.config, runner.flows, @now, known, [
               {"runtime_upgrade", "RU-01"}
             ])

    assert [%{"state" => "requested"}] = Enum.filter(runs, &(&1["flow"] == "runtime_upgrade"))
  end
end

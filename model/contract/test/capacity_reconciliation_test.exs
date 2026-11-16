defmodule Model.CapacityReconciliationTest do
  use ExUnit.Case, async: true
  alias AtlasFlow.Runs.Run

  @now ~U[2026-11-16 10:00:00Z]
  @previous %{
    "issue" => "6dcb5eefa0dd0aec97748b7280249678cb64d759808b81e2104b3992c7b38052",
    "pull_request" => "9e9822b579c9f85bd577c278b2c8a10ee7be7d04ee029e12ad8bf790cdc703de"
  }

  test "capacity cutover preserves current entries, frozen Code requests and restart inputs" do
    for env <- [:prod, :test], {name, digest} <- @previous do
      flow = Enum.find(Model.AtlasEyra.subflows(env), &(&1.name() == name))
      selection = Model.AtlasEyra.selection(name)
      subject = %{"key" => "work", "values" => %{}}
      run = Run.new(name, flow, subject, [], @now)

      for pending <- [
            run["pending"],
            Map.put(run["pending"], "restart", %{"id" => "restart-in-flight"}),
            Map.put(run["pending"], "effect", %{
              "id" => "approved-code-request",
              "request" => %{"revision" => "approved-revision", "fingerprint" => "approved"}
            })
          ] do
        old =
          run
          |> Map.put("definition_sha256", digest)
          |> Map.put("pending", pending)

        assert {:ok, moved} = Run.migrate(old, flow, selection["migrations"], @now)
        assert moved["definition_sha256"] == flow.digest()

        assert Map.drop(moved, ~w(definition_sha256 pending)) ==
                 Map.drop(old, ~w(definition_sha256 pending))

        assert Map.delete(moved["pending"], "migrations") == pending
        assert {:ok, ^moved} = Run.migrate(moved, flow, selection["migrations"], @now)
      end
    end
  end

  test "capacity changes ownership while current integration and different-vendor review remain" do
    for env <- [:prod, :test] do
      flow = Enum.find(Model.AtlasEyra.subflows(env), &(&1.name() == "pull_request"))
      assert {:effect, effect} = flow.mechanism("integrating")
      assert effect["service"] == "code" and effect["operation"] == "integrate"

      assert effect["approving"] == %{
               "review_outcome" => ["approved"],
               "test_outcome" => ["passed"]
             }

      assert flow.owner("checking")["capacity"]["differs_from"] == "author"
      assert flow.owner("checking")["default"] == nil
      assert "blocked" in flow.states()
    end

    for name <- ~w(design_and_accept test_and_accept_scene test_and_accept_use_case) do
      assert [_ | _] = Model.AtlasEyra.selection(name)["restart_by"]
    end

    assert Model.AtlasEyra.selection("to_do")["subject"] == "to_do"
  end
end

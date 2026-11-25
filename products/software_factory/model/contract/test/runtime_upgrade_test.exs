defmodule Model.RuntimeUpgradeTest do
  @moduledoc """
  IS-Atlas-26: a Runtime's upgrade is a fact under its machinery that its supervisor
  makes, naming the build. Facts refuses a second one under the same machinery while one
  is open, naming it; its steps are Flow's alone, written by the work source's receiver.
  """
  use ExUnit.Case, async: true

  alias Model.AtlasEyra

  @session %{"by" => "holder-1", "writer" => "holder-1", "sender" => "control/session-1"}
  @delivery %{"by" => "flow", "writer" => "flow", "sender" => "flow/delivery"}

  # Facts' lookup, with `upgrades` the runtime_upgrade facts it lists.
  defp lookup(upgrades) do
    %{
      "current" => fn -> nil end,
      "fact" => fn _, _ -> nil end,
      "list" => fn
        "runtime_upgrade" ->
          facts =
            for {key, state} <- upgrades,
                do: %{key: key, links: %{"upgrades" => ["mini"]}, properties: %{"state" => state}}

          {:ok, facts}

        _ ->
          {:ok, []}
      end,
      "incoming" => fn _, _, _ -> [] end,
      "fingerprint" => &AtlasBus.SubjectFingerprint.of/2
    }
  end

  # What Control's create sends: the build asked, the form's defaults, under the machinery.
  defp create(key) do
    %{"defaults" => defaults} =
      Map.new(AtlasEyra.form("runtime_upgrade", :create), fn {k, v} -> {to_string(k), v} end)

    %{
      "op" => "create",
      "key" => key,
      "values" => Map.merge(defaults, %{"build" => "b2"}),
      "links" => %{"upgrades" => ["mini"]}
    }
  end

  defp check(change, env, upgrades),
    do: AtlasEyra.check("runtime_upgrade", change, env, lookup(upgrades))

  test "its supervisor makes one under the machinery, open, asking only the build" do
    form = AtlasEyra.form("runtime_upgrade", :create)
    assert form.ask == ["build"]
    assert form.defaults == %{"state" => "open"}
    assert check(create("RU-01"), @session, []) == :ok
  end

  test "a second one while one is open is refused, naming it; once that ended it is not" do
    assert {:refuse, [reason]} = check(create("RU-02"), @session, [{"RU-01", "open"}])
    assert reason == "mini is being upgraded already: RU-01; start another once it ends"

    assert check(create("RU-02"), @session, [{"RU-01", "ended"}]) == :ok
  end

  test "its steps are Flow's, from the work source's receiver, never a person's" do
    step = %{
      "op" => "change",
      "key" => "RU-01",
      "values" => %{"step" => "draining", "busy" => "dev1"},
      "links" => %{}
    }

    assert check(step, @delivery, [{"RU-01", "open"}]) == :ok
    assert {:refuse, ["protected fields: " <> _]} = check(step, @session, [{"RU-01", "open"}])
  end

  test "its run follows the step to done or failed" do
    subflow = Enum.find(AtlasEyra.subflows(:prod), &(&1.name() == "runtime_upgrade"))
    assert subflow.subject() == "runtime_upgrade"
    assert subflow.initial() == "requested"
    assert subflow.final?("done") and subflow.final?("failed")
    refute subflow.final?("draining")
    assert subflow.next("requested", %{"step" => "draining"}, nil) == {:to, "draining"}
    assert subflow.next("draining", %{"step" => "updating"}, nil) == {:to, "updating"}
    assert subflow.next("updating", %{"step" => "done"}, nil) == {:to, "done"}
    assert subflow.next("draining", %{"step" => "draining"}, nil) == :stay
  end
end

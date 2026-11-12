defmodule AtlasFlow.Runs.Inputs do
  @moduledoc "Typed Facts operation records. Roles in subject snapshots are never authority."
  alias AtlasFlow.Runs.Conditions

  def eligible?(input, run, subject, branch) do
    {:ok, tree} = Conditions.compile(branch["when"])

    input["status"] == "applied" and input["run"] == run["key"] and
      input["entry"] == run["entry"] and input["position"] > run["input_cursor"] and
      input["subject_version"] == subject["version"] and
      Enum.any?(branch["roles"], &(&1 in input["roles"])) and
      Enum.any?(Conditions.fields(tree), &Map.has_key?(input["changed_fields"], &1)) and
      Conditions.matches?(branch["when"], Map.merge(subject["values"], input["changed_fields"]))
  end
end

defmodule AtlasFlow.Runs.Inputs do
  @moduledoc "Typed Facts operation records. Roles in subject snapshots are never authority."

  @doc """
  The state an applied input of this run's entry moves the run to, or nil: it came
  after the cursor, on the subject's current version, and a branch of one of its roles
  takes the fields it changed (the compiled subflow `flow` says which).
  """
  def choice(input, run, subject, flow) do
    if input["status"] == "applied" and input["run"] == run["key"] and
         input["entry"] == run["entry"] and input["position"] > run["input_cursor"] and
         input["subject_version"] == subject["version"] do
      changed = input["changed_fields"]
      values = Map.merge(subject["values"] || %{}, changed)

      case flow.next(run["state"], values, %{roles: input["roles"], changed: changed}) do
        {:to, to} -> to
        :stay -> nil
      end
    end
  end
end

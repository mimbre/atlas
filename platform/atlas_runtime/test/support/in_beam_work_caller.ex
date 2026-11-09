defmodule AtlasRuntime.Test.InBeamWorkCaller do
  @moduledoc """
  A co-located system calling the Runtime (design §13 case 11): it uses only the facade
  `AtlasRuntime.Boundary.Work`, never the core behind it.
  `AtlasRuntime.Boundary.InBeamCallerTest` checks its compiled calls.
  """
  alias AtlasRuntime.Boundary.Work

  @doc "Submits a folder work as `client`, then waits for its end; the ended work."
  def run(client, folder, instructions) do
    request = %{
      title: instructions,
      instructions: instructions,
      profile: "light_work",
      cost_class: "standard",
      workspace: %{kind: "folder", path: folder, permissions: "read-only"}
    }

    %Work.Outcome.Subscribed{} = Work.subscribe(client, %{})
    %Work.Outcome.Accepted{work: work} = Work.submit(client, request)
    await(client, work.work_id)
  end

  defp await(client, id) do
    case Work.get_work(client, %{work_id: id}) do
      %Work.Outcome.Found{work: %{state: state} = work}
      when state in [:completed, :failed, :crashed, :interrupted, :cancelled, :returned] ->
        work

      _ ->
        receive do
          {:atlas_runtime_work, %Work.WorkChanged{work_id: ^id}} -> :ok
        after
          1_000 -> :ok
        end

        await(client, id)
    end
  end
end

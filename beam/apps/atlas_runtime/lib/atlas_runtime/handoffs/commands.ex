defmodule AtlasRuntime.Handoffs.Commands do
  alias AtlasRuntime.HandoffRecords
  alias AtlasRuntime.Persistence.History
  import AtlasRuntime.Execution.Identity, only: [valid_id?: 1, valid_worker_id?: 1]

  def execute(%{"command" => "handoff"} = request, dir, events) do
    handoff_selectors!(request, [])
    record = owned_handoff!(dir, request) || raise("No handoff recorded for this turn")
    {HandoffRecords.public(record), events}
  end

  def execute(%{"command" => "submit-handoff"} = request, dir, events) do
    handoff_selectors!(request, ["handoff"])
    record = owned_handoff!(dir, request)

    run =
      if record do
        Map.take(record, ["worker_id", "turn_id"])
      else
        handoff_run!(dir, request)
      end

    {record, events} = HandoffRecords.submit(dir, events, run, request["handoff"])
    {HandoffRecords.public(record), events}
  end

  defp handoff_selectors!(request, extra) do
    fields = ["command", "worker_id", "turn_id"] ++ extra

    if Enum.sort(Map.keys(request)) != Enum.sort(fields),
      do:
        raise(
          "#{request["command"]} requires exactly worker_id, turn_id#{if extra == [], do: "", else: " and handoff"}"
        )

    if not valid_worker_id?(request["worker_id"]), do: raise("Invalid worker ID")
    if not valid_id?(request["turn_id"]), do: raise("Invalid turn ID")
  end

  defp owned_handoff!(dir, request) do
    record = HandoffRecords.load(dir, request["turn_id"])

    if record && record["worker_id"] != request["worker_id"],
      do: raise("Handoff belongs to worker #{record["worker_id"]}, not #{request["worker_id"]}")

    record
  end

  defp handoff_run!(dir, request) do
    run = History.owned_saved_turn!(dir, request["turn_id"], request["worker_id"])
    %{"worker_id" => run["worker_id"], "turn_id" => run["id"], "repository" => run["repository"]}
  end
end

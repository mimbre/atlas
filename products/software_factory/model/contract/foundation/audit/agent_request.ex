defmodule Model.AgentRequest do
  @moduledoc "What a person asked the agent on a page, and what became of it."
  use RelaDSL

  type(:agent_outcome,
    values: [
      :proposed,
      :running,
      :done,
      :done_without_asking,
      :stopped,
      :refused,
      :cancelled,
      :failed
    ],
    labels: [
      proposed: "Proposed",
      running: "Running",
      done: "Done",
      done_without_asking: "Done without asking",
      stopped: "Stopped",
      refused: "Refused",
      cancelled: "Cancelled",
      failed: "Failed"
    ]
  )

  entity :agent_request,
    label: "Agent request",
    plural: "agent_requests",
    aliases: ["rq"],
    id_type: :manual,
    id_prefix: "RQ-",
    description: """
    What Melle asked the agent on a page of the TUI (`:`), and what became of
    it: the plan's summary and its outcome. Its steps hang under it. The cause
    of every change the agent made (SC-Atlas-04, UC-Atlas-19).
    """ do
    field(:title, :string, required: true, description: "The request, in Melle's words")
    field(:page, :string, description: "The page it was asked on")
    field(:planner, :string, description: "Who planned it")
    field(:outcome, :agent_outcome, description: "What became of it")
    field(:summary, :string, description: "What the agent said about its plan", multiline: true)

    field(:before, :string,
      description: "What became of the previous plan, after a refusal",
      multiline: true
    )

    field(:overrules, :string,
      description: "The request this one overrules (d-0016)",
      cause: "Overruled by"
    )

    agent(:request)
    top(false)
    by_hand(false)
    order(:newest)
    create(ask: [:title, :page, :planner, :outcome, :summary, :before, :overrules])
  end
end

defmodule Model.Foundation.Audit do
  @moduledoc "Foundation's optional audit: what the agent was asked on a page, and its steps."
  use RelaDSL.Module,
    path: "modules/foundation/audit/schema.yaml",
    concepts: [Model.AgentRequest, Model.AgentStep]
end

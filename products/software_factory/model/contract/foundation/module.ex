defmodule Model.Foundation do
  @moduledoc """
  Foundation: the actors (people, agents and machinery), Assignments and turns, the
  tasks Flow defines and their attempts, guidance records,
  the decision ledger with its gate verdicts, To-Dos (work no flow covers), and the
  durable flow runs. Every
  composition selects it.
  """
  use RelaDSL.Module,
    path: "modules/foundation/schema.yaml",
    concepts: [
      Model.Person,
      Model.Agent,
      Model.Assignment,
      Model.Turn,
      Model.Machinery,
      Model.Task,
      Model.TaskAttempt,
      Model.Guidance,
      Model.Decision,
      Model.ToDo,
      Model.GateVerdict,
      Model.FlowRun
    ]
end

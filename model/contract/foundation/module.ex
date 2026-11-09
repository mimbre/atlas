defmodule Model.Foundation do
  @moduledoc """
  Foundation: the actors (people and agents), Assignments and turns, guidance records,
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
      Model.Guidance,
      Model.Decision,
      Model.ToDo,
      Model.GateVerdict,
      Model.FlowRun
    ]
end

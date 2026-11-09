defmodule AtlasRuntime.Model.Work do
  @moduledoc """
  The compile-time model target of the Runtime's private work model (design §1.7):
  `work_record` and `key_index_entry` with their structs, `new/1` and the persisted form
  (`encode`/`decode`). Only the work core (`AtlasRuntime.Work`) uses it; no caller sees it.
  """
  use AtlasRuntimeModel.Generator.Targets.Model, contract: AtlasRuntimeModel.Work
end

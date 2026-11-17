defmodule AtlasRuntime.Model.LocalSource do
  @moduledoc """
  The compile-time model target of the built-in local work source's queue (decision §5.4):
  `queued_work` and `queue_key_entry` with their structs, `new/1` and the persisted form
  under `local-source/` (`encode`/`decode`). Only `AtlasRuntime.Sources.Local.Store` uses
  it; no caller sees it.
  """
  use AtlasRuntimeModel.Generator.Targets.Model, contract: AtlasRuntimeModel.LocalSource
end

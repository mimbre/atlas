defmodule AtlasCode.Boundary do
  @moduledoc """
  The facade of Code's boundary contract (`AtlasCodeBoundary.Code`; ADR 0006): the way in
  for callers in the same BEAM, and for Code's own HTTP routes where the contract declares
  them. Generated: one function per capability, which checks the caller's right and the
  input before it calls `AtlasCode.Running`, and checks what that answers against the
  declared outcomes.

  A caller is `{id, rights}`. `:snapshot` lets it resolve references, create snapshots and
  read them (`get_manifest`, and `get_blob`, whose bytes come as a lazy stream); `:change`
  lets it create changes, put their blobs and seal them; `:review` lets it open a review of
  a sealed change and update an open one. Its calls act on the Code instance registered in
  this BEAM (`AtlasCode.settings/0`).
  """
  use AtlasCodeBoundary.Generator.Targets.Boundary,
    contract: AtlasCodeBoundary.Code,
    implementation: AtlasCode.Running
end

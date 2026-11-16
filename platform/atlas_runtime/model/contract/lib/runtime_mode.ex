defmodule AtlasRuntimeModel.RuntimeMode do
  @moduledoc """
  The Runtime's persisted mode (design §1.7, §3.4, §13.1 Q6): whether it takes new work,
  kept in `$ATLAS_RUNTIME_HOME/mode.json`, never seen by a caller.

  - `runtime_mode`: the mode an operator set last, when and by whom. `mode.json` has no
    `{field}`, so it is one file under `"entries"`; the Runtime keeps at most one entry.

  Rules kept by the hand-written loader, not declared here:
  - a missing file, or one without an entry, is `open`;
  - `stopping` is never persisted: `stop` does not change the mode, and a restart starts
    in the persisted mode.
  """
  use AtlasRuntimeModel.Generator.Schema

  version "0.1.0"

  defrecord :runtime_mode,
    # One file: the path has no {field}.
    persist: [form: :json_file, path: "mode.json", format_version: 1] do
    field :mode, {:enum, [:open, :paused, :draining]}, required: true
    field :changed_at, :datetime, required: true
    # Private: the caller that set it.
    field :changed_by, :string, required: true
  end
end

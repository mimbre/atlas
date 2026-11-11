defmodule AtlasBFFContract.Contract do
  @moduledoc """
  The contract, the single source of the spec, written in the generator's DSL
  (`AtlasBFF.Schema`). Control and the TUI read it at compile time
  (`AtlasControl.Blocks`, `AtlasTui.Blocks`); `mix atlas.gen` here writes
  `bff/targets/json/blocks.json` for clients in other languages.
  """
  use AtlasBFF.Schema
  models_from(AtlasBFFContract.Models.Presentation)
  protocol_from(AtlasBFFContract.Wire.Control.Discovery)
  protocol_from(AtlasBFFContract.Wire.Runtime)
  protocol_from(AtlasBFFContract.Wire.Control.Workers)
  protocol_from(AtlasBFFContract.Wire.Control.Session)

  # 0.7.0: markup names meaning; part (main, related) replaces border and columns.
  # 0.8.0: a pair may carry its origin: the fact that set it (since, by, cause).
  # 0.9.0: the pages Control serves (defpage); a path outside them is no page.
  # 0.10.0: the form submits Control takes (defendpoint, call :submit).
  # 0.11.0: a form's submit_to and a confirm's confirm_to name an endpoint and its params
  # (a `call`), no longer a path; the session's other calls; hello carries the version.
  # 0.12.0: a part of role todo (what its owner is to do); hello may say `as`, the fact an
  # agent client is.
  # 0.13.0: failure pages, in the test environment only (IS-Atlas-23): what can be made
  # to fail on a page, and a confirm that causes one.
  # 0.14.0: the current turn and its outcome, through Control (IS-Atlas-19).
  version "0.14.0"

  use AtlasBFFContract.Blocks
  use AtlasBFFContract.Pages
  use AtlasBFFContract.Endpoints
end

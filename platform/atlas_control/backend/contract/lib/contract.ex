defmodule AtlasBFFContract.Contract do
  @moduledoc """
  The contract, the single source of the spec, written in the generator's DSL
  (`AtlasBFF.Schema`). Control and the TUI read it at compile time
  (`AtlasControl.Blocks`, `AtlasTui.Blocks`); `mix atlas.gen` here writes
  `platform/atlas_control/backend/targets/json/blocks.json` for clients in other languages and `platform/atlas_control/backend/targets/swift/`,
  the Swift package `AtlasControlKit`, for clients on Apple's platforms.
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
  # 0.15.0: page freshness (docs/design/page-freshness.md §3): a row says the fact it
  # opens (`key`) and whether a write to it is still being processed (`pending`); Control
  # pushes pages for recently viewed paths too (`hint`), and marker overlays (`pending`);
  # `position` is the page's version per path, which a client caches pages by.
  # 0.16.0: a local Console operation, sections_toggle, folds and unfolds the page's
  # collapsible sections (the worker page's Details); a 0.15.0 client refuses actions with it.
  # 0.17.0: a projected action may invoke its declared submit call directly.
  # 0.18.0: supervision (work acquisition decision 2026-11-17, §5.8): the pages Open for
  # you and Supervised by you, and Pick up and Hand over… on a fact, with their submits.
  # 0.19.0: a page may declare the groups its items fall into (`groups`), each a filter of
  # the page; Open for you per group (`/_open/:subflow/:span`).
  # 0.20.0: each shell tab names its icon (a semantic name, `icon`) and its groups
  # (`groups`: label and `to`); Supervised by you and what is assigned have groups too
  # (`/_supervised/:subflow/:span`, `/_assigned/:kind`).
  # 0.21.0: boot's tabs with groups carry their counts (`count` on the tab, its All, and on
  # each group), so a client shows them before the tab is opened.
  # 0.22.0: a fact's page offers the flow's next step and one More… action, which opens
  # the fact's secondary menu (`/k/:kind/:key/more`) with everything else.
  # 0.23.0: each shell tab names its `section` ("work" or "browse"); a browse tab may have
  # its own `key`, a two-key sequence ("g s"), which a console action opens it with. A
  # client cycles through the work tabs only. Older clients refuse sequence keys.
  # 0.24.0: an action may be the page's rather than its block's (`page`): a client shows it
  # with the page's title (the window's toolbar, an item page's header), not under the block.
  # 0.25.0: a list row may say where its work stands (`tone`) and since when (`since`); a
  # client shows a coloured mark and an age beside the row's own words.
  # 0.27.0: a to-do's instructions step by step (`steps`, with `instruction_step`), and
  # the submit that sets the step its owner is at (`step`).
  # 0.28.0: a page where its owner decides may show it as a `panel` (to accept, to merge,
  # a decision on stuck work): a heading and title, a byline, the items or checks or box
  # it is judged on, and its answers (a choice when `choose`).
  version "0.28.0"

  use AtlasBFFContract.Blocks
  use AtlasBFFContract.Markup
  use AtlasBFFContract.Pages
  use AtlasBFFContract.Endpoints
end

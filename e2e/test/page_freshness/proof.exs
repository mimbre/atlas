# The page freshness proof (docs/design/page-freshness.md §5, slice F8), run inside the
# core's own node: `mix run` boots the core as `atlas-ops up` does, on the private
# instance e2e/test/page_freshness_test.exs prepared, then runs this. Two real TUIs in tmux
# are sessions of that core. Waits are for screen text or a session's state, each with a
# ceiling; between Facts' stored hint and Flow's settle, time is held, so the marker shows
# for as long as the proof looks at it (§2.1, §2.2).
#
# The core's node has no e2e modules on its code path: this file only loads the helpers,
# then steps.exs, which is compiled once they exist.
root = Path.expand("../../..", __DIR__)

for file <- ~w(github instance tui scenario),
    do: Code.require_file("e2e/lib/atlas_e2e/#{file}.ex", root)

for file <- ~w(held_time sessions steps), do: Code.require_file("#{file}.exs", __DIR__)

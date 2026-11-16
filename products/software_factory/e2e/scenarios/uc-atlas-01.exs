# UC-Atlas-01: manage scenes (docs/guides/uc-atlas-01.md).
import AtlasE2E.Scenario

scenario "UC-Atlas-01: Manage scenes", fn %{t1: t1, t2: t2, instance: instance} ->
  step "List", fn ->
    for t <- [t1, t2], do: see(t, ~r/Scenes.*\n(.*\n)*.*● connected/)
  end

  step "Create asks only a title and a description; the code is made", fn ->
    press(t1, "c")
    form = see(t1, ~r/^ Create scene$/m)
    for field <- ["Title *", "Description"], do: form =~ field || raise("no #{field}")
    for field <- ["Id", "Flux group", "Status", "Completed", "Flux id"], do: refute_see(t1, field)

    type(t1, "Write the first scene")
    press(t1, "Down")
    type(t1, "A scene made by the end-to-end test.")
    at = press(t1, "C-s")

    stored(t1, ~r/✓ Stored as SC-Atlas-\d+/, at)
    stored(t1, ~r/Scene SC-Atlas-\d+: Write the first scene/, at)
    by_hint(t2, "Write the first scene", at)
  end

  step "Open: defaults, no Flux id", fn ->
    press(t1, "Escape")
    see(t1, ~r/› SC-Atlas-\d+  Write the first scene/)
    open_row(t1, "Write the first scene")
    see(t1, ~r/Flux group\s+Refine/)
    refute_see(t1, "Flux id")
    open_row(t2, "Write the first scene")
    see(t2, ~r/Scene SC-Atlas-\d+: Write the first scene/)
  end

  step "Update: the code is read-only; TUI 2 follows by hint", fn ->
    press(t1, "u")
    see(t1, ~r/Update SC-Atlas-\d+/)
    see(t1, ~r/Id\s+SC-Atlas-\d+/)
    type(t1, " (changed)")
    at = press(t1, "C-s")
    stored(t1, ~r/Scene SC-Atlas-\d+: Write the first scene \(changed\)/, at)
    by_hint(t2, "Write the first scene (changed)", at)
  end

  step "A refusal: an empty title", fn ->
    press(t1, "Escape")
    see(t1, ~r/› SC-Atlas-\d+  Write the first scene \(changed\)/)
    press(t1, "c")
    see(t1, ~r/^ Create scene$/m)
    at = press(t1, "C-s")
    stored(t1, "title is required", at)
    see(t1, ~r/^ Create scene$/m)
    press(t1, "Escape")
    see(t1, ~r/› SC-Atlas-\d+  Write the first scene \(changed\)/)
  end

  step "Delete; TUI 2 follows by hint", fn ->
    press(t2, "Escape")
    see(t2, ~r/› SC-Atlas-\d+  Write the first scene \(changed\)/)
    press(t1, "c")
    see(t1, ~r/^ Create scene$/m)
    type(t1, "To be deleted")
    at = press(t1, "C-s")
    stored(t1, ~r/Scene SC-Atlas-\d+: To be deleted/, at)
    by_hint(t2, "To be deleted", at)

    press(t1, "d")
    see(t1, ~r/Delete scene SC-Atlas-\d+\?/)
    at = press(t1, "y")
    stored(t1, "✓ Stored", at)
    see(t1, ~r/› SC-Atlas-\d+  Write the first scene \(changed\)/)
    gone(t1, "To be deleted", 1_000)
    by_hint(t2, "To be deleted", at, gone: true)
  end

  step "Losing Control and coming back", fn ->
    AtlasE2E.Instance.stop_core(instance)
    for t <- [t1, t2], do: see(t, "Not connected to Control. Retrying…")
    for t <- [t1, t2], do: refute_see(t, "Write the first scene")
    AtlasE2E.Instance.start_core(instance)
    for t <- [t1, t2], do: see(t, ~r/› SC-Atlas-\d+  Write the first scene \(changed\)/, 30_000)
  end
end

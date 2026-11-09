# UC-Atlas-28: My work on the front page. IS-Atlas-55: the TUI's user is a person, so
# Control opens on what is assigned to them (start.assigned in rela/atlas.json): their
# Assignments (IS-Atlas-78), each as the open fact it belongs to, newest move first, with
# what its flow expects and since when and why; the header counts them on every page; a
# hint updates it in every TUI. The scenes are one key away (s).
import AtlasE2E.Scenario

scenario "UC-Atlas-28: My work on the front page", fn %{t1: t1, t2: t2, instance: i} ->
  row = fn key, title -> ~r/#{key}\s+#{Regex.escape(title)}/ end
  # The header's count, this many more than when the scenario started.
  count = fn more -> ~r/Atlas Console · test · #{Process.get(:uc28_n) + more} assigned to you/ end

  start = fn t ->
    start_page(t)
    see_list(t, "Assigned to you")
  end

  step "The TUI's user is a person: the start page is what is assigned to them", fn ->
    # UC-Atlas-32 makes melle too: the same name is the same key.
    atlas(i, ["put", "person", "--name", "Melle"])
    atlas(i, ["put", "agent", "--name", "Coordinator"])

    # Flow assigns melle what earlier scenarios left to test (IS-Atlas-75), so the counts
    # below are from where this scenario starts.
    for t <- [t1, t2] do
      start.(t)
      see_action(t, "s", "Scenes")
    end

    n = capture(t1, ~r/Atlas Console · test · (\d+) assigned to you/) |> String.to_integer()
    Process.put(:uc28_n, n)
    see(t2, ~r/Atlas Console · test · #{n} assigned to you/)

    # Empty, the page says what fills it.
    if n == 0 do
      see(t1, "Nothing is assigned to you now.")
      see(t1, "s opens the scenes.")
    end
  end

  step "A fact assigned to you shows in both TUIs by hint, with why; the header counts it", fn ->
    {scene, _} = atlas_json(i, ["put", "scene", "--title", "A scene for you"])

    {use_case, _} =
      atlas_json(i, ["put", "use_case", "--in", scene["key"], "--title", "A use case for you"])

    Process.put(:uc28, %{scene: scene["key"], use_case: use_case["key"]})

    {_, at} =
      atlas_json(i, [
        "set",
        use_case["key"],
        "assigned_to=melle",
        "--cause",
        "all its issues are completed"
      ])

    for t <- [t1, t2], do: by_hint(t, row.(use_case["key"], "A use case for you"), at)
    see(t1, count.(1))
    # What its flow expects, once Flow has written it: the row's summary (UC-Atlas-44).
    see(t1, ~r/#{use_case["key"]}\s+A use case for you\s+Build it\s/, 10_000)
    # Why, and since when, are on its page: first what to do, for its owner. Room for its parts.
    resize(t1, 100, 40)
    open_row(t1, "A use case for you")
    see(t1, ~r/Why\s+all its issues are completed[\s│]*\n[\s│]+since \d+ \w+ \d\d:\d\d · by /u)
    resize(t1, 100, 30)
    start.(t1)
  end

  step "Newest move first", fn ->
    %{scene: scene, use_case: use_case} = Process.get(:uc28)

    {_, at} =
      atlas_json(i, ["set", scene, "assigned_to=melle", "--cause", "a second one for you"])

    screen = by_hint(t1, row.(scene, "A scene for you"), at)
    {first, _} = :binary.match(screen, scene)
    {second, _} = :binary.match(screen, use_case)
    first < second || raise "not newest first:\n#{screen}"
    see(t1, count.(2))
  end

  step "Moved away: gone by hint in both TUIs, and the count goes down", fn ->
    %{use_case: use_case} = Process.get(:uc28)

    {_, at} =
      atlas_json(i, ["set", use_case, "assigned_to=coordinator", "--cause", "back to building"])

    for t <- [t1, t2], do: by_hint(t, row.(use_case, "A use case for you"), at, gone: true)
    see(t1, count.(1))
  end

  step "s opens the scenes, with the count; esc comes back; enter opens a fact", fn ->
    %{scene: scene} = Process.get(:uc28)
    press(t1, "s")
    see_list(t1, "Scenes")
    see(t1, count.(1))
    press(t1, "Escape")
    see_list(t1, "Assigned to you")
    open_row(t1, "A scene for you")
    see(t1, "Scene #{scene}: A scene for you")
  end

  # IS-Atlas-78: what is assigned is an Assignment; the list shows the fact it belongs to,
  # while that fact is open. Once it is done, Flow takes the owner off (IS-Atlas-75).
  step "Done: an accepted use case leaves the list; Flow takes its owner off", fn ->
    %{scene: scene} = Process.get(:uc28)

    {done, _} =
      atlas_json(i, ["put", "use_case", "--in", scene, "--title", "A use case to accept"])

    atlas_json(i, ["set", done["key"], "assigned_to=melle", "--cause", "ready to accept"])
    start.(t1)
    see(t1, count.(2))
    open_row(t1, "A use case to accept")
    see(t1, "Use case #{done["key"]}: A use case to accept")
    press(t1, "a")
    see(t1, "will be accepted by melle")
    at = press(t1, "y")
    stored(t1, ~r/Accepted by ─+(.|\n)*melle  Person/, at)

    start.(t1)
    see(t1, count.(1))
    refute_see(t1, "A use case to accept")

    {part, _} = atlas_json(i, ["get", "AS-" <> done["key"]])
    ["Assigned to", "—"] in part["fields"] || raise inspect(part["fields"])
    part["origins"]["Assigned to"]["by"] == "flow" || raise inspect(part["origins"])
  end
end

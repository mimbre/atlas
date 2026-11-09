# UC-Atlas-25: see how far a scene and its use cases are (docs/guides/uc-atlas-25.md).
import AtlasE2E.Scenario

scenario "UC-Atlas-25: See how far a scene and its use cases are", fn %{
                                                                        t1: t1,
                                                                        t2: t2,
                                                                        instance: i
                                                                      } ->
  key = fn args -> atlas_json(i, args) |> elem(0) |> Map.fetch!("key") end
  keys = fn -> Process.get(:uc25) end
  # Console lists show one line per item: id, title, then the summary (UC-Atlas-44).
  row = fn key, detail ->
    ~r/#{Regex.escape(key)}  [^\n]*  #{Regex.escape(detail)}\s*(│|$)/mu
  end

  step "Lists show progress from the children: TUI 1 on a scene, TUI 2 on the scenes", fn ->
    scene = key.(["put", "scene", "--title", "A scene to follow"])
    built = key.(["put", "use_case", "--in", scene, "--title", "A use case with issues"])
    empty = key.(["put", "use_case", "--in", scene, "--title", "A use case without issues"])
    one = key.(["put", "issue", "--in", built, "--title", "The first issue"])
    two = key.(["put", "issue", "--in", built, "--title", "The second issue"])
    Process.put(:uc25, %{scene: scene, built: built, empty: empty, one: one, two: two})

    open_row(t1, "A scene to follow")
    see(t1, "Scene #{scene}: A scene to follow")
    # Both issues are new, so in Specification; a use case without issues shows its group.
    see(t1, row.(built, "Specification · 2/2"))
    see(t1, row.(empty, "Refine"))
    refute_see(t1, ~r/#{Regex.escape(empty)}  [^\n]*Refine ·/u)
    # The least far use case wins: the one still in Refine.
    press(t2, "End")
    see(t2, row.(scene, "Refine · 1/2"))
  end

  step "An issue's stage changes its use case's row in both TUIs within 1 s", fn ->
    %{built: built, one: one, two: two} = keys.()
    {_, at} = atlas_json(i, ["set", one, "stage=development"])
    by_hint(t1, row.(built, "Specification · 1/2"), at)

    {_, at} = atlas_json(i, ["set", two, "stage=development"])
    by_hint(t1, row.(built, "Development · 2/2"), at)

    {_, at} = atlas_json(i, ["set", one, "stage=design"])
    by_hint(t1, row.(built, "Design · 1/2"), at)
  end

  step "Two levels up: an issue changes its scene's row", fn ->
    %{scene: scene, built: built, empty: empty, one: one} = keys.()
    {_, at} = atlas_json(i, ["set", one, "stage=development"])
    by_hint(t1, row.(built, "Development · 2/2"), at)

    {third, at} = atlas_json(i, ["put", "issue", "--in", empty, "--title", "The third issue"])
    by_hint(t1, row.(empty, "Specification · 1/1"), at)
    by_hint(t2, row.(scene, "Specification · 1/2"), at)

    {_, at} = atlas_json(i, ["set", third["key"], "stage=development"])
    by_hint(t2, row.(scene, "Development · 2/2"), at)
    Process.put(:uc25, Map.put(keys.(), :third, third["key"]))
  end

  step "The item page shows Flux's status as its Flux group", fn ->
    open_row(t1, "A use case without issues")
    see(t1, ~r/Use case UC-Atlas-\d+: A use case without issues/)
    see(t1, ~r/Flux group\s+Refine/)
    refute_see(t1, ~r/Status\s+Refine/)
  end
end

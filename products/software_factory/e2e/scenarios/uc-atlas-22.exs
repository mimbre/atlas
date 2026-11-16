# UC-Atlas-22: create and change items from the command line, with the TUIs open.
import AtlasE2E.Scenario

scenario "UC-Atlas-22: Create and change items from the command line", fn %{
                                                                            t1: t1,
                                                                            t2: t2,
                                                                            instance: i
                                                                          } ->
  title = "A scene from the command line"

  step "atlas put: the stored item has its code and can be opened in TUI 2", fn ->
    {scene, _} =
      atlas_json(i, ["put", "scene", "--title", title, "--description", "Made by an agent."])

    scene["key"] =~ ~r/^SC-Atlas-\d+$/ || raise "no code: #{inspect(scene)}"
    scene["values"]["title"] == title || raise inspect(scene)
    open_row(t2, title)
    Process.put(:uc22_scene, scene["key"])
  end

  step "atlas put --in, the description of several lines from stdin; TUI 1 on the scene", fn ->
    scene = Process.get(:uc22_scene)
    open_row(t1, title)
    see(t1, "Scene #{scene}: #{title}")
    text = "First line\n\n## A section\n- a point"

    args = ["put", "use_case", "--in", scene, "--title", "Its lines", "--description", "-"]
    {use_case, at} = atlas_json(i, args, 0, text <> "\n")

    use_case["values"]["description"] == text || raise inspect(use_case)
    ["In scene", scene] in use_case["fields"] || raise inspect(use_case["fields"])
    by_hint(t1, "Its lines", at)
  end

  step "atlas set: a change shows in both TUIs by hint", fn ->
    scene = Process.get(:uc22_scene)

    {changed, at} =
      atlas_json(i, ["set", scene, "title=#{title} (changed)", "status=ready_to_pick_up"])

    changed["values"]["status"] == "ready_to_pick_up" || raise inspect(changed)
    by_hint(t1, "#{title} (changed)", at)
    see(t1, ~r/Flux group\s+Ready to pick up/)
    by_hint(t2, "#{title} (changed)", at)
  end

  step "Refused: the reasons, exit 1, nothing stored; a wrong field: exit 2", fn ->
    {answer, _} = atlas_json(i, ["put", "use_case", "--in", "UC-Atlas-99", "--title", "Lost"], 1)
    answer == %{"refused" => ["UC-Atlas-99 does not exist"]} || raise inspect(answer)

    {answer, _} = atlas_json(i, ["set", Process.get(:uc22_scene), "status=done"], 1)
    hd(answer["refused"]) =~ "status must be one of" || raise inspect(answer)

    {answer, _} = atlas_json(i, ["put", "scene", "--colour", "red"], 2)

    answer["error"] =~ "does not ask for colour; it asks for title, description" ||
      raise inspect(answer)

    refute_see(t1, "Lost")
  end
end

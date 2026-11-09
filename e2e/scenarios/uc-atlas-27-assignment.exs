# UC-Atlas-27, IS-Atlas-78 (d-0022): every assignable thing has an Assignment. A new fact
# gets its Assignment in the same write; the fact's page and `atlas get` show the
# Assignment's fields (Assigned to, Expected) as its own, with since, by and why; enter on
# it opens the Assignment's own page; deleting the fact deletes it, and it is never
# deleted alone.
import AtlasE2E.Scenario

scenario "UC-Atlas-27: Every assignable thing has an Assignment", fn %{
                                                                       t1: t1,
                                                                       t2: t2,
                                                                       instance: i
                                                                     } ->
  step "A new use case gets its Assignment at once", fn ->
    atlas_json(i, ["put", "person", "--name", "Bea"])
    {scene, _} = atlas_json(i, ["put", "scene", "--title", "A scene with assignments"])

    {use_case, _} =
      atlas_json(i, ["put", "use_case", "--in", scene["key"], "--title", "An assigned use case"])

    key = use_case["key"]
    Process.put(:uc78, key)
    {part, _} = atlas_json(i, ["get", "AS-" <> key])
    part["title"] == "Assignment AS-#{key}: #{key}" || raise inspect(part)

    {listed, _} = atlas_json(i, ["list", "assignment"])
    # Since IS-Atlas-85 the list of Assignments is Open work: one row per open fact.
    Enum.any?(listed, &(&1["key"] == key)) || raise inspect(listed)
  end

  step "Its page shows the Assignment's owner as its own, set on the fact; both TUIs by hint",
       fn ->
         key = Process.get(:uc78)

         for t <- [t1, t2] do
           # Room for the References part to show the owner's list when it arrives: paging
           # stops at a part's current end, so it cannot wait below it in advance.
           resize(t, 100, 40)
           home(t)
           open_row(t, "A scene with assignments")
           open_row(t, "An assigned use case")
           see(t, "Use case #{key}: An assigned use case")
         end

         {got, at} = atlas_json(i, ["set", key, "assigned_to=bea", "--cause", "Bea builds it"])
         ["Assigned to", "bea"] in got["fields"] || raise inspect(got["fields"])

         got["origins"]["Assigned to"]["cause"] == "Bea builds it" ||
           raise inspect(got["origins"])

         # The link is the Assignment's, not the use case's own.
         Enum.any?(got["fields"], &match?(["Assignment", _], &1)) && raise inspect(got["fields"])

         # The owner's list arrives by hint in the References part.
         for t <- [t1, t2], do: by_hint(t, ~r/Assigned to ─/, at)
         for t <- [t1, t2], do: resize(t, 100, 30)

         # Flow writes what is expected on the Assignment; the use case shows it as its own.
         expected =
           Enum.find_value(1..20, fn _ ->
             {got, _} = atlas_json(i, ["get", key])

             found =
               Enum.find_value(got["fields"], fn [label, value] ->
                 label == "Expected" && value
               end)

             found || (Process.sleep(500) && nil)
           end)

         expected == "Build it" || raise "Expected is #{inspect(expected)}"
       end

  step "enter on the Assignment opens its own page", fn ->
    key = Process.get(:uc78)
    open_row(t1, "AS-#{key}")
    see(t1, "Assignment AS-#{key}: #{key}")
    see(t1, ~r/Assigned to\s+bea/)
    see(t1, "Assignment of: Use cases")
  end

  step "Deleted with its use case, never alone", fn ->
    key = Process.get(:uc78)
    {%{"refused" => [why]}, _} = atlas_json(i, ["delete", "AS-" <> key], 1)
    why == "AS-#{key} goes with #{key}; delete that instead." || raise why

    atlas_json(i, ["delete", key])
    {%{"error" => error}, _} = atlas_json(i, ["get", "AS-" <> key], 2)
    error =~ "does not exist" || raise error
  end
end

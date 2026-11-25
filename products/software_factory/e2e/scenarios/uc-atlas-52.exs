# UC-Atlas-52: the decider files a scene under a product and sees each product's work
# apart (SC-Atlas-20). The product Atlas (PD-01, code Atlas) is there from the start, as
# the migration makes it; a second product is made by hand from the products list.
import AtlasE2E.Scenario

# The keys of a list's rows, as `atlas list --json` gives them.
keys = fn rows ->
  Enum.map(rows, &(&1["key"] || &1["path"] |> String.split("/") |> List.last()))
end

scenario "UC-Atlas-52: Scenes under products", fn %{t1: t1, t2: t2, instance: i} ->
  step "An Atlas scene, as every scene that exists is", fn ->
    {scene, _} =
      atlas_json(i, ["put", "scene", "--in", "PD-01", "--title", "Atlas's own scene"])

    scene["key"] =~ ~r/^SC-Atlas-\d+$/ || raise "not Atlas's: #{inspect(scene)}"
  end

  step "The products list: Atlas, and a second made by hand, with its name and code", fn ->
    press(t1, "g")
    press(t1, "p")
    see_list(t1, "Products")
    see(t1, "Atlas")
    press(t1, "c")
    form = see(t1, ~r/^ Create product$/m)
    for field <- ["Name *", "Code *", "Description"], do: form =~ field || raise("no #{field}")
    type(t1, "Second product")
    press(t1, "Tab")
    type(t1, "Beta")
    at = press(t1, "C-s")
    stored(t1, ~r/✓ Stored as PD-02/, at)
    stored(t1, "Product PD-02: Second product", at)
  end

  step "A scene created on the second's page gets the second's code", fn ->
    press(t1, "c")
    see(t1, ~r/Create scene in PD-02/)
    type(t1, "Beta's first scene")
    at = press(t1, "C-s")
    stored(t1, ~r/✓ Stored as SC-Beta-01/, at)
    stored(t1, "Scene SC-Beta-01: Beta's first scene", at)
  end

  step "It shows under the second and not under the first", fn ->
    press(t1, "Escape")
    see(t1, "Product PD-02: Second product")
    see(t1, "Beta's first scene")

    press(t2, "g")
    press(t2, "p")
    see_list(t2, "Products")
    open_row(t2, "Atlas")
    see(t2, "Product PD-01: Atlas")
    see(t2, "Atlas's own scene")
    refute_see(t2, "Beta's first scene")

    {beta, _} = atlas_json(i, ["list", "scene", "--in", "PD-02"])
    keys.(beta) == ["SC-Beta-01"] || raise inspect(beta)
  end

  step "Every other scene reads as Atlas's, its key unchanged", fn ->
    {all, _} = atlas_json(i, ["list", "scene"])
    {atlas, _} = atlas_json(i, ["list", "scene", "--in", "PD-01"])

    Enum.sort(keys.(all)) == Enum.sort(keys.(atlas) ++ ["SC-Beta-01"]) ||
      raise "not every scene is a product's: #{inspect(all)}"

    Enum.all?(keys.(atlas), &(&1 =~ ~r/^SC-Atlas-\d+$/)) || raise inspect(atlas)
  end
end

# Run from products/software_factory, with MIX_ENV=test and --no-start.
Code.require_file("scenarios.exs", __DIR__)
Code.require_file("product_pages.exs", __DIR__)

[path] = System.argv()
tabs = ControlFixtures.Scenarios.definitions()
spec = AtlasControl.Blocks.version()

boots =
  Map.new(~w(decision scene todo lists empty), fn scenario ->
    target = ControlFixtures.Scenarios.initial(scenario)
    active = Enum.find(tabs, fn tab ->
      target == tab["to"] or
        (String.starts_with?(tab["to"], "/k/") and String.starts_with?(target, tab["to"] <> "/"))
    end)

    {scenario, %{"op" => "boot", "title" => "Atlas Console fixtures", "env" => "test",
      "spec" => spec, "revision" => "shared-fixtures", "tabs" => tabs,
      "initial_to" => target, "active_tab" => active && active["id"]}}
  end)

fixture = %{"spec" => spec, "tabs" => tabs, "boots" => boots, "pages" => ControlFixtures.ProductPages.build!()}
File.mkdir_p!(Path.dirname(path))
File.write!(path, JSON.encode!(fixture) <> "\n")
IO.puts("wrote #{path}")

defmodule AtlasBFFContract.FixturesTargetTest do
  use ExUnit.Case, async: true

  test "the fixture target follows the full contract, including boot and page wire messages" do
    schema = AtlasBFFContract.Contract.__schema__()
    [{"fixtures.json", json}] = AtlasBFF.Targets.Fixtures.files(schema)
    fixtures = JSON.decode!(json)["fixtures"]

    assert Enum.map(fixtures["blocks"], & &1["name"]) ==
             Enum.map(schema.blocks, &to_string(&1.name))

    control = Enum.find(fixtures["channels"], &(&1["channel"] == "control"))
    assert Enum.any?(control["messages"], &(&1["sample"]["op"] == "boot"))
    assert Enum.any?(control["messages"], &(&1["sample"]["op"] == "page"))
    models = Map.new(schema.models, &{&1.name, &1.fields})

    for {kind, definitions} <- [
          {"blocks", schema.blocks},
          {"markup", schema.markup},
          {"models", schema.models}
        ],
        {entry, definition} <- Enum.zip(fixtures[kind], definitions),
        variant <- entry["variants"] do
      props = if kind == "models", do: variant["props"], else: variant["sample"]["props"]

      for field <- definition.fields do
        name = to_string(field.name)
        if field.required, do: assert(Map.has_key?(props, name), "#{entry["name"]}: #{name}")

        if Map.has_key?(props, name) do
          assert :ok = AtlasBFF.Targets.Protocol.validate_value!(models, field.type, props[name])
        end
      end
    end

    for {kind, definitions} <- [
          {"blocks", schema.blocks},
          {"markup", schema.markup},
          {"models", schema.models}
        ],
        {entry, definition} <- Enum.zip(fixtures[kind], definitions),
        field <- Enum.reject(definition.fields, & &1.required) do
      cases =
        Map.new(entry["variants"], fn variant ->
          props = if kind == "models", do: variant["props"], else: variant["sample"]["props"]
          {variant["case"], props}
        end)

      assert Map.has_key?(cases["only:#{field.name}"], to_string(field.name))
      refute Map.has_key?(cases["without:#{field.name}"], to_string(field.name))
    end

    for {kind, definitions} <- [
          {"blocks", schema.blocks},
          {"markup", schema.markup},
          {"models", schema.models}
        ],
        {entry, definition} <- Enum.zip(fixtures[kind], definitions),
        field <- definition.fields,
        match?({:list, _}, field.type) do
      cases =
        Map.new(entry["variants"], fn variant ->
          props = if kind == "models", do: variant["props"], else: variant["sample"]["props"]
          {variant["case"], props}
        end)

      name = to_string(field.name)

      assert Enum.map(~w(empty one many), &length(cases["value:#{name}:#{&1}"][name])) == [
               0,
               1,
               3
             ]
    end

    text = Enum.find(fixtures["blocks"], &(&1["name"] == "text"))
    cases = Map.new(text["variants"], &{&1["case"], &1["sample"]["props"]})
    refute Map.has_key?(cases["required"], "syntax")
    assert cases["full"]["syntax"] == "markdown"

    sizes =
      for size <- ~w(short normal long), do: String.length(cases["value:text:#{size}"]["text"])

    assert sizes == Enum.sort(sizes) and length(Enum.uniq(sizes)) == 3
    assert cases["value:text:long"]["text"] =~ "# "
  end
end

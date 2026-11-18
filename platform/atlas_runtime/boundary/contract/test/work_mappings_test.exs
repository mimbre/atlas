defmodule AtlasRuntimeBoundary.WorkMappingsTest do
  # The mappings are checked against the model where it is at hand, in the Boundary
  # target inside atlas_runtime. Here: their own side, and that they stay private.
  use ExUnit.Case, async: true

  alias AtlasRuntimeBoundary.{Work, WorkMappings}

  @work_json Path.expand("../../targets/json/work.json", __DIR__)
  @mix_exs Path.expand("../mix.exs", __DIR__)

  defp mappings, do: WorkMappings.__mappings__()

  defp models,
    do: Map.new(Work.__schema__().models, &{&1.name, Enum.map(&1.fields, fn f -> f.name end)})

  test "S1: work_record both ways with work, key_index_entry one way to pruned" do
    by_model = Map.new(mappings(), &{&1.model, &1})

    assert %{boundary: :work, direction: :both, supply: [:state], rename: []} =
             by_model.work_record

    # S5a's pinned source and M2 A3's imported input are private.
    assert by_model.work_record.drop == [:source, :imported]

    assert %{
             boundary: :pruned,
             direction: :from_model,
             rename: [final_kind: :kind],
             drop: [:client, :client_key, :pruned]
           } = by_model.key_index_entry

    assert %{drop: [:turn_folder, :stop_latch | _]} = by_model.attempt
  end

  test "an attempt's provenance is translated, with its selection, options and skips" do
    by_model = Map.new(mappings(), &{&1.model, &1})

    assert %{drop: [:turn_folder, :stop_latch, :released_by, :released_at | _], supply: []} =
             by_model.attempt

    for {model, boundary} <- [
          provenance: :provenance,
          selection: :selection,
          option: :option,
          skipped_option: :skipped_option
        ],
        do: assert(%{boundary: ^boundary, direction: :both} = by_model[model], "#{model}")
  end

  # S5a (I-B5): what the core keeps for itself is dropped, never renamed onto a public field.
  @private_s5a [:checking, :check_pgid, :folder, :preparing, :prepare_pid]

  test "S5a: the private additions are dropped, and the new entities are mapped one to one" do
    by_model = Map.new(mappings(), &{&1.model, &1})

    assert :source in by_model.work_record.drop

    # M2 (plan C3) adds the private lease hold, dropped as well.
    assert by_model.attempt.drop -- [:turn_folder, :stop_latch, :released_by, :released_at] ==
             @private_s5a ++ [:lease_hold]

    for {model, boundary} <- [
          base: :base,
          from_work: :from_work,
          after_check: :after_check,
          frozen_ref: :frozen_ref,
          root_fingerprint: :root_fingerprint,
          based_on: :based_on,
          check_result: :check_result,
          check_output: :check_output
        ] do
      assert %{boundary: ^boundary, direction: :both, rename: [], drop: [], supply: []} =
               by_model[model],
             "#{model}"
    end

    for model <- [:base, :from_work],
        do:
          assert(
            by_model[model].values == [
              permissions: [read_only: :"read-only", workspace_write: :"workspace-write"]
            ]
          )

    # The frozen result's own record is another model's; the core translates it.
    refute Map.has_key?(by_model, :frozen_result)

    names = for {_m, fields} <- models(), name <- fields, uniq: true, do: name

    for name <- [:source, :imported | @private_s5a],
        do: refute(name in names, "#{name} is public")
  end

  test "renames and drops only: every name is an atom" do
    for mapping <- mappings(), {key, value} <- Map.delete(mapping, :line) do
      assert atoms?(value), "#{mapping.model}.#{key}: #{inspect(value)}"
    end
  end

  test "every boundary name a mapping uses is the contract's" do
    models = models()

    for mapping <- mappings() do
      fields = Map.fetch!(models, mapping.boundary)
      for name <- Keyword.values(mapping.rename) ++ mapping.supply, do: assert(name in fields)
    end
  end

  test "no model name reaches the contract's schema or its JSON file" do
    schema = inspect(Work.__schema__())
    json = File.read!(@work_json)
    refute Map.has_key?(Work.__schema__(), :mappings)

    model_only =
      for mapping <- mappings(),
          name <- [mapping.model | mapping.drop ++ Keyword.keys(mapping.rename)],
          name not in Map.keys(models()),
          name not in Enum.flat_map(models(), &elem(&1, 1)),
          uniq: true,
          do: Atom.to_string(name)

    assert "work_record" in model_only and "turn_folder" in model_only

    for name <- model_only ++ ["WorkMappings", "defmapping"] do
      # As a whole name: product_workspace is no part of work_product_workspace.
      whole = ~r/(^|[^A-Za-z0-9_])#{name}([^A-Za-z0-9_]|$)/
      refute schema =~ whole, "#{name} in __schema__/0"
      refute json =~ whole, "#{name} in work.json"
    end
  end

  test "the contract project depends on no model" do
    refute File.read!(@mix_exs) =~ "model"
    refute Enum.any?(Mix.Project.deps_paths(), fn {_app, path} -> path =~ "model" end)
  end

  defp atoms?(value) when is_list(value), do: Enum.all?(value, &atoms?/1)
  defp atoms?({key, value}), do: atoms?(key) and atoms?(value)
  defp atoms?(value), do: is_atom(value)
end

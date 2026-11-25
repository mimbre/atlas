defmodule Model.FlowsTest do
  use ExUnit.Case, async: true

  alias Model.AtlasEyra
  alias RelaDSL.{Atlas, Project, Rela}

  defp resolved,
    do: RelaDSL.Limits.resolve(AtlasEyra.__flows__(), AtlasEyra.__rela__(:gates), :prod)

  defp generated, do: Rela.flows_yaml(resolved())

  # The pinned rela parses no `!` in a condition (CI run 44037654839 refused `!=`): a
  # negation is `not (…)`. Checked here, as the `:rela` test needs the binary.
  test "no condition in the flows.yaml carries a `!`, which the pinned rela refuses" do
    conditions = Regex.scan(~r/when: "([^"]*)"/, generated(), capture: :all_but_first)
    assert conditions != []
    assert for([c] <- conditions, String.contains?(c, "!"), do: c) == []
    # No subflow negates a condition since the package's retired (IS-Atlas-100); none may
    # use `!` once one does.
  end

  test "flows.json holds the compiled composition, and Flow loads it" do
    compiled = AtlasEyra.composition()

    written =
      JSON.decode!(
        Atlas.flows_json(resolved(), AtlasEyra.__rela__(:gates), AtlasEyra.__composition__())
      )

    no_nil = &Enum.map(&1, fn x -> Map.reject(x, fn {_, v} -> v == nil end) end)
    assert written["composition"] == Map.update!(compiled, "links", no_nil)
    assert compiled["version"] == 1

    for env <- [:prod, :test] do
      assert AtlasFlow.Model.load(AtlasEyra, env, %{"decider" => "someone"}).refusal == nil
    end
  end

  # As `mix model.gen` checks it in a fresh checkout: the Rela project holds only its
  # hand-written data-entry.yaml, and the description the model generates is laid over it.
  @tag :rela
  @tag :tmp_dir
  test "the pinned rela finds the flows.yaml valid in the generated description",
       %{tmp_dir: dir} do
    bin = Path.join(System.fetch_env!("ATLAS_RELA_BIN"), "rela")
    data_entry = File.read!("../targets/rela/data-entry.yaml")
    File.write!(Path.join(dir, "data-entry.yaml"), data_entry)

    files =
      for {path, body} <-
            Project.files(AtlasEyra.__rela__(:description), data_entry, generated()),
          path != "flows.yaml",
          do: {path, body}

    assert {:ok, _shown} = Rela.check(bin, generated(), resolved(), project: dir, files: files)
  end
end

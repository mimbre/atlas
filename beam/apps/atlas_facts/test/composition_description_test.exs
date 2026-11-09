defmodule AtlasFacts.CompositionDescriptionTest do
  use ExUnit.Case, async: false
  alias AtlasBus.Envelope

  defmodule Backend do
    def description(description), do: {:ok, description}
  end

  @tag :integration
  @tag :tmp_dir
  test "Facts starts and serves the foundation-only description with an unselected runtime", %{
    tmp_dir: dir
  } do
    root = Path.expand("../../../..", __DIR__)
    schema_root = Path.join(dir, "composition")
    File.mkdir_p!(Path.join(schema_root, "modules"))

    File.cp_r!(
      Path.join(root, "rela/modules/foundation"),
      Path.join(schema_root, "modules/foundation")
    )

    File.write!(
      Path.join(schema_root, "schema.yaml"),
      JSON.encode!(%{
        "version" => "1.0",
        "includes" => ["modules/foundation/schema.yaml"]
      })
    )

    python = System.get_env("ATLAS_CONFIG_PYTHON") || System.find_executable("python3")

    {json, status} =
      System.cmd(
        python,
        [Path.join(root, "rela/scripts/config.py"), "resolved", "--root", schema_root],
        stderr_to_stdout: true
      )

    assert status == 0, json
    description = JSON.decode!(json)

    # The foundation-only extension: the committed atlas.json scoped to what this
    # description holds (its kinds and relations, and the root rules foundation owns).
    full = JSON.decode!(File.read!(Path.join(root, "rela/atlas.json")))

    extra =
      full
      |> Map.take(~w(todo runtime start guidance))
      |> Map.put("entities", Map.take(full["entities"], Map.keys(description["entities"])))
      |> Map.put("relations", Map.take(full["relations"], Map.keys(description["relations"])))

    extra_path = Path.join(dir, "extra.json")
    File.write!(extra_path, JSON.encode!(extra))

    # The committed sidecar, selecting no generated runs (as for a composition without subflows).
    fragment =
      JSON.decode!(File.read!(Path.join(root, "rela/flow-runtime.json")))
      |> put_in(["flow_runtime", "selection"], %{})

    sidecar = Path.join(dir, "flow-runtime.json")
    File.write!(sidecar, JSON.encode!(fragment))
    Application.put_env(:atlas_bus, :store, "composition-#{System.unique_integer([:positive])}")

    facts =
      start_supervised!(
        {AtlasFacts.Server,
         rela: {Backend, description},
         data_dir: Path.join(dir, "facts"),
         description_extra: extra_path,
         flow_runtime: sidecar}
      )

    :ok = AtlasBus.attach("composition-reader")
    envelope = Envelope.new("read", "_description")
    :ok = AtlasBus.send(envelope, %{})
    id = envelope.id
    assert_receive {:atlas_bus, %Envelope{id: ^id, class: "answer"}, answer}, 1_000
    assert %{"description" => served} = answer
    assert map_size(served["entities"]) > 0

    assert Map.keys(served["entities"]) |> Enum.sort() ==
             Map.keys(description["entities"]) |> Enum.sort()

    assert served["flow_runtime"]["selection"] == %{}
    assert served["flow_runtime"]["reviews"] == %{}
    assert Process.alive?(facts)
  end
end

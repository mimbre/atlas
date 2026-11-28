defmodule Model.DescriptionTest do
  use ExUnit.Case, async: true

  alias Model.AtlasEyra
  alias RelaDSL.{Project, Rela}

  defp description, do: AtlasEyra.__rela__(:description)

  defp flows_yaml,
    do:
      Rela.flows_yaml(
        RelaDSL.Limits.resolve(AtlasEyra.__flows__(), AtlasEyra.__rela__(:gates), :prod)
      )

  # The Rela project as the model describes it, with the hand-written data-entry.yaml.
  defp files do
    data_entry = File.read!("../targets/rela/data-entry.yaml")

    Map.new([
      {"data-entry.yaml", data_entry} | Project.files(description(), data_entry, flows_yaml())
    ])
  end

  test "the Rela project holds the root, module and bindings files, the additions and the manifest" do
    assert Enum.map(Project.files(description(), "", flows_yaml()), &elem(&1, 0)) == [
             "schema.yaml",
             "modules/foundation/schema.yaml",
             "modules/foundation/audit/schema.yaml",
             "modules/software/schema.yaml",
             "modules/eyra/schema.yaml",
             "compositions/atlas-eyra/bindings.yaml",
             "acl.yaml",
             "atlas.json",
             "flow-runtime.json",
             "flows.yaml",
             "atlas.manifest.json"
           ]
  end

  test "the manifest names every input that is packaged, and none that is gone" do
    files = files()
    manifest = JSON.decode!(files["atlas.manifest.json"])
    sha = &(:crypto.hash(:sha256, &1) |> Base.encode16(case: :lower))
    for {path, digest} <- manifest["inputs"], do: assert(sha.(files[path]) == digest, path)

    assert Map.has_key?(manifest["inputs"], "data-entry.yaml")
    # atlas.json is a proof only: nothing checks or reads it where Atlas runs.
    refute Map.has_key?(manifest, "output_sha256")
    assert manifest["flows"] == %{"source" => "flows.yaml", "sha256" => sha.(flows_yaml())}

    refute Enum.any?(
             Map.keys(manifest["inputs"]),
             &String.ends_with?(&1, ["atlas.json", "sources.json"])
           )
  end

  test "each kind's and relation's introspection is its part of atlas.json" do
    extension = JSON.decode!(files()["atlas.json"])

    for kind <- Map.keys(description().schema["entities"]) do
      part = AtlasEyra.__rela__({:entity, kind})
      assert part.extension == extension["entities"][kind], kind
      assert part.schema == description().schema["entities"][kind]
    end

    for name <- Map.keys(description().schema["relations"]),
        do:
          assert(
            AtlasEyra.__rela__({:relation, name}).extension == extension["relations"][name],
            name
          )

    # Every kind of the extension is a kind of the schema.
    assert Map.keys(extension["entities"]) -- Map.keys(description().schema["entities"]) == []
  end

  test "only scene, use case and issue descriptions declare markdown" do
    kinds = AtlasEyra.kinds()

    marked =
      for kind <- kinds,
          field <- kind.fields,
          field.syntax == "markdown",
          do: {kind.name, field.name}

    assert Enum.sort(marked) ==
             [{"issue", "description"}, {"scene", "description"}, {"use_case", "description"}]

    for kind <- kinds, field <- kind.fields, field.syntax != "markdown" do
      assert field.syntax == nil
    end
  end

  describe "the profiles (private dependency proofs)" do
    test "foundation alone has no software or product plan, and binds verdicts to decisions only" do
      d = Model.Profiles.Foundation.__rela__(:description)

      for kind <- ~w(scene use_case issue pull_request agent_request),
          do: refute(Map.has_key?(d.schema["entities"], kind), kind)

      refute Map.has_key?(d.schema["relations"], "accepted_by")
      assert d.schema["relations"]["about"]["to"] == ["decision"]
      assert d.extension["entities"]["decision"]["authority"]["decider"]["relation"] == "about"
      refute Map.has_key?(d.extension, "flows")
      runtime = RelaDSL.Description.Plain.unorder(d.flow_runtime)["flow_runtime"]
      assert runtime["selection"] == %{}
      assert runtime["inputs"]["roles"] == %{}
    end

    test "incident reuses foundation, audit and software, with its own kind and no product plan" do
      d = Model.Profiles.Incident.__rela__(:description)
      assert Map.has_key?(d.schema["entities"], "incident")
      refute Map.has_key?(d.schema["entities"], "scene")
      refute Map.has_key?(d.schema["relations"], "accepted_by")

      assert d.extension["entities"]["issue"]["create"]["id"]["prefix"] == "IS-Maint-"
      refute Map.has_key?(d.extension, "flows")

      # Its own subflows build an issue, owned by the runner, and merge its pull request,
      # which reports the merge to its issue.
      runtime = RelaDSL.Description.Plain.unorder(d.flow_runtime)["flow_runtime"]

      assert Enum.sort(Map.keys(runtime["selection"])) ==
               ~w(incident_issue incident_pull_request)

      [issue] =
        for f <- Model.Profiles.Incident.subflows(:test), f.name() == "incident_issue", do: f

      assert issue.owner(issue.initial())["default"] == %{"kind" => "agent", "key" => "runner"}

      assert [%{"child" => "incident_pull_request", "parent_subject" => "issue"}] =
               Model.Profiles.Incident.composition()["links"]

      assert AtlasFlow.Model.load(Model.Profiles.Incident, :test, %{}).refusal == nil

      # The pull request ends merged or closed; its merge, through the link, ends the issue.
      [pr] =
        for f <- Model.Profiles.Incident.subflows(:test),
            f.name() == "incident_pull_request",
            do: f

      assert pr.next("open", %{"state" => "merged"}, nil) == {:to, "merged"}
      assert pr.next("open", %{"state" => "closed"}, nil) == {:to, "closed"}
      assert pr.next("open", %{"state" => "open"}, nil) == :stay

      merged = %{roles: ["atlas-flow"], changed: %{"pr_outcome" => "integrated"}}
      assert issue.next("building", %{"pr_outcome" => "integrated"}, merged) == {:to, "done"}
      assert issue.next("building", %{"pr_outcome" => "integrated"}, nil) == :stay
    end
  end

  # What test_assembly.py proved about the images: each Dockerfile's COPY products/software_factory/model/targets/rela/... lines
  # carry every packaged input, so verify.py passes in the image. The core copies no
  # generated JSON (D-0083): the model is compiled in.
  test "both image recipes copy every input the manifest names and the manifest" do
    manifest = JSON.decode!(files()["atlas.manifest.json"])
    needed = Map.keys(manifest["inputs"]) ++ ["atlas.manifest.json"]

    copies =
      for line <- String.split(File.read!("../../../../platform/ops/core.Dockerfile"), "\n"),
          String.starts_with?(line, "COPY "),
          do: line

    for proof <- ["atlas.json", "flow-runtime.json", "flows.json"],
        do: refute(Enum.any?(copies, &(&1 =~ proof)), "core.Dockerfile copies #{proof}")

    for recipe <- ["core", "rela"] do
      # Each source of a COPY of the Rela project, below it: a file, or a folder (`x/`).
      sources =
        for line <-
              String.split(File.read!("../../../../platform/ops/#{recipe}.Dockerfile"), "\n"),
            String.starts_with?(line, "COPY products/software_factory/model/targets/rela/"),
            [_ | args] = String.split(line),
            {sources, [_target]} = Enum.split(args, -1),
            source <- sources,
            do:
              source
              |> String.replace_prefix("products/software_factory/model/targets/rela/", "")
              |> String.trim_trailing("/")

      copied? = fn path ->
        Enum.any?(sources, &(&1 == path or String.starts_with?(path, &1 <> "/")))
      end

      missed = Enum.reject(needed, copied?)
      assert missed == [], "#{recipe}.Dockerfile misses #{inspect(missed)}"
    end
  end
end

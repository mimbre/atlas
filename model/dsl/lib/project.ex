defmodule RelaDSL.Project do
  @moduledoc """
  The Rela project of a composition (`RelaDSL.Composition`), as files: what Rela
  serves and checks, and the proofs of what the model adds to it.

    * `schema.yaml`, which includes each module's file and the composition's bindings
      file, in that order; each file holds `types`, `entities` and `relations`
      (`RelaDSL.Description.Yaml`);
    * `acl.yaml`, the roles the flows name, when the composition has an `acl`;
    * `atlas.json`, Atlas's additions, keys sorted (`RelaDSL.Description.Json`): a proof
      only, no component reads it (the model compiles them in);
    * `flow-runtime.json`, the run mapping, when a concept declares `flow_runtime`: a
      proof only, as `atlas.json`;
    * `flows.yaml`, when given (the subflows, with its generated header);
    * `atlas.manifest.json`: the SHA-256 of every file of the selected closure and of
      `data-entry.yaml` (`inputs`) and of `flows.yaml` (`flows`). Packaging and startup check it (`rela/scripts/verify.py`).

  `data-entry.yaml` is rela-server's setting and stays hand-written: its bytes are
  given, to be hashed. Every path is relative to the project's folder.
  """

  alias RelaDSL.Description.{Json, Yaml}

  @module_comment "Complete definitions; included paths are relative to the selected root."

  @doc "`[{path, bytes}]` of `description`'s project, given `data_entry` bytes and `flows_yaml` (or nil)."
  def files(description, data_entry, flows_yaml \\ nil) do
    root = {description.root.path, Yaml.document(description.root.doc, description.root.comment)}

    included =
      for f <- description.files, do: {f.path, Yaml.document(f.doc, f.comment || @module_comment)}

    acl =
      case description.acl do
        nil ->
          []

        acl ->
          roles = Enum.map(acl.order, &acl.roles[&1])
          [{"acl.yaml", Yaml.acl(acl.comment, roles, acl.assignment_order)}]
      end

    extension = Json.write(description.extension)

    runtime =
      case description.flow_runtime do
        nil -> []
        value -> [{"flow-runtime.json", Json.write(value, &Json.flow_runtime_layout/1)}]
      end

    flows = if flows_yaml, do: [{"flows.yaml", flows_yaml}], else: []

    inputs =
      ([root | included] ++ [{"data-entry.yaml", data_entry}])
      |> Enum.map(fn {path, bytes} -> {path, sha256(bytes)} end)
      |> Enum.sort()

    manifest =
      {:ordered,
       [{"inputs", {:ordered, inputs}}] ++
         if(flows_yaml,
           do: [{"flows", {:ordered, [{"source", "flows.yaml"}, {"sha256", sha256(flows_yaml)}]}}],
           else: []
         )}

    [root | included] ++
      acl ++
      [{"atlas.json", extension}] ++
      runtime ++ flows ++ [{"atlas.manifest.json", Json.write(manifest)}]
  end

  @doc "The folders of a project whose every file the generator writes: a file there it does not write is left over."
  def owned_folders, do: ["modules", "compositions"]

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end

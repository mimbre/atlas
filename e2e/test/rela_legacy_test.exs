defmodule AtlasE2E.RelaLegacyTest do
  use ExUnit.Case, async: true
  @root Path.expand("../..", __DIR__)
  @bin AtlasE2E.Instance.rela_bin!()
  @moduletag :tmp_dir

  @schema """
  version: '1.0'
  namespace: https://example.invalid/legacy#
  entities:
    note:
      label: Note
      plural: notes
      id_type: manual
      properties:
        title: {type: string}
  relations: {}
  """

  setup %{tmp_dir: dir} do
    proposed = Path.join(dir, "proposed")
    data = Path.join(dir, "source")
    tools = Path.join(dir, "tools")
    bin = Path.join(dir, "bin")
    File.mkdir_p!(Path.join(proposed, "scripts"))
    File.mkdir_p!(Path.join(data, "entities/notes"))
    File.mkdir_p!(tools)
    File.mkdir_p!(bin)
    File.cp!(Path.join(@bin, "rela"), Path.join(bin, "rela"))
    File.chmod!(Path.join(bin, "rela"), 0o755)
    File.write!(Path.join(proposed, "schema.yaml"), @schema)
    File.write!(Path.join(proposed, "data-entry.yaml"), "app:\n  name: Legacy preflight\n")

    for name <- ["data.sh", "fits.sh"] do
      File.cp!(Path.join(@root, "rela/scripts/#{name}"), Path.join(proposed, "scripts/#{name}"))
    end

    File.cp!(
      Path.join(@root, "fly/check-fits.sh"),
      Path.join(proposed, "scripts/description.sh")
    )

    # Reproduce a first-upgrade old image: no sqlite3 or rela-sqlite is reachable.
    for name <- ~w(dirname mktemp rm bash tar mkdir cp find sed basename grep sort) do
      File.ln_s!(System.find_executable(name), Path.join(tools, name))
    end

    %{dir: dir, proposed: proposed, data: data, tools: tools, bin: bin}
  end

  defp check(c) do
    System.cmd("/bin/bash", [Path.join(c.proposed, "scripts/description.sh"), "fits"],
      env: [
        {"ATLAS_RELA_DATA", c.data},
        {"ATLAS_RELA_BIN", c.bin},
        {"PATH", c.tools}
      ],
      stderr_to_stdout: true
    )
  end

  test "legacy old-image preflight succeeds without either SQLite tool", c do
    file = Path.join(c.data, "entities/notes/one.md")
    contents = "---\nid: one\ntype: note\ntitle: Kept\n---\n"
    File.write!(file, contents)
    assert {_, 0} = check(c)
    assert File.read!(file) == contents
  end

  for {kind, declaration} <- [
        canonical: "  note:\n    label: Note link\n    from: [note]\n    to: [note]\n",
        inverse:
          "  paired:\n    label: Paired\n    from: [note]\n    to: [note]\n    inverse:\n      id: note\n      label: Note link\n"
      ] do
    test "removing a populated #{kind} relation sharing an entity name refuses", c do
      files = %{
        "entities/notes/one.md" => "---\nid: one\ntype: note\ntitle: First kept\n---\n",
        "entities/notes/two.md" => "---\nid: two\ntype: note\ntitle: Second kept\n---\n",
        "relations/one--note--two.md" => "---\nfrom: one\nrelation: note\nto: two\n---\n"
      }

      for {name, contents} <- files do
        file = Path.join(c.data, name)
        File.mkdir_p!(Path.dirname(file))
        File.write!(file, contents)
      end

      # Keep a real relations block, followed by the same-named entity namespace.
      kept = "relations:\n  kept:\n    label: Kept\n    from: [note]\n    to: [note]\n"
      base = String.replace(@schema, "relations: {}\n", "")
      valid = String.replace(base, "entities:\n", kept <> unquote(declaration) <> "entities:\n")
      File.write!(Path.join(c.proposed, "schema.yaml"), valid)
      assert {_, 0} = check(c)

      for {name, contents} <- files, do: assert(File.read!(Path.join(c.data, name)) == contents)

      removed = String.replace(base, "entities:\n", kept <> "entities:\n")
      File.write!(Path.join(c.proposed, "schema.yaml"), removed)
      {out, status} = check(c)
      assert status != 0, out
      assert out =~ "note (a relation this build has no more)"
      for {name, contents} <- files, do: assert(File.read!(Path.join(c.data, name)) == contents)
    end
  end

  test "removed populated fields, kinds and relations refuse without changing legacy bytes", c do
    files = %{
      "entities/notes/one.md" =>
        "---\nid: one\ntype: note\ntitle: Kept\nretired: Still here\n---\n",
      "entities/gones/G-1.md" => "---\nid: G-1\ntype: gone\ntitle: Kept too\n---\n",
      "relations/one--removed_link--G-1.md" =>
        "---\nfrom: one\nrelation: removed_link\nto: G-1\n---\n"
    }

    for {name, contents} <- files do
      path = Path.join(c.data, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
    end

    {out, status} = check(c)
    assert status != 0, out
    assert out =~ "retired"
    assert out =~ "gones"
    assert out =~ "removed_link"
    for {name, contents} <- files, do: assert(File.read!(Path.join(c.data, name)) == contents)
  end

  test "SQLite source refuses missing tools instead of scanning stale markdown", c do
    File.mkdir_p!(Path.join(c.data, ".rela"))
    File.write!(Path.join(c.data, ".rela/rela.db"), "tool check marker, never opened")
    {out, status} = check(c)
    assert status != 0, out
    assert out =~ "sqlite3 is required"
    refute File.exists?(Path.join(c.bin, "rela-sqlite"))
  end
end

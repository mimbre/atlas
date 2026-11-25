Code.require_file("spec_rows.exs", __DIR__)

defmodule AtlasRuntime.Sandbox.SpecParityTest do
  # S6 package A2e: AtlasRuntime.Sandbox.Spec decides every row of test/fixtures/s6/spec/ as
  # the checked-in expect says (B2), which the Go test asserts against the legacy decision
  # (TestS6RenderParity). Facts come from the real helper under the row's environment, so the
  # tests change the process environment and are not async. Legacy-only rows
  # ("elixir": "skip:…", B9) are skipped with their reason.
  use ExUnit.Case, async: false

  alias AtlasRuntime.SpecRows
  alias AtlasRuntime.Sandbox.{Facts, HomeLayout, Spec}

  for path <- SpecRows.table_paths(), do: @external_resource(path)

  for {table, row} <- SpecRows.rows() do
    @row row
    if reason = row["elixir"], do: @tag(skip: reason)

    test "#{table} #{row["id"]}" do
      got = SpecRows.run(@row).got
      want = SpecRows.want(@row)
      assert Map.keys(want) != [], "row has neither expect.spec nor expect.error"
      assert got == want
    end
  end

  test "every decision table row is asserted here or skipped as legacy-only" do
    rows = SpecRows.rows()
    skipped = for {_, row} <- rows, Map.has_key?(row, "elixir"), do: row["elixir"]
    # S5b B2: the two legacy-only review-packet rows left with the profile. IS-Atlas-20 added
    # the two read-only folder rows (codex.folder-read-only, claude.folder-read-only).
    assert length(rows) == 74
    assert skipped == []
  end

  describe "the Runtime home" do
    test "without a scope home, the spec denies the helper's own resolved home (row 2a)" do
      root = AtlasRuntime.S6Fixture.new_root!()
      home = Path.join(root, "home")
      File.mkdir_p!(home)
      link = Path.join(root, "home-link")
      File.ln_s!(home, link)
      workspace = Path.join(root, "proj")
      File.mkdir_p!(workspace)

      request = %{
        "decision" => "agent",
        "harness" => "codex",
        "sandbox" => "read-only",
        "workspace" => workspace,
        "origin" => "client_named"
      }

      facts =
        SpecRows.with_env(%{"ATLAS_RUNTIME_HOME" => link}, fn ->
          Facts.fetch("launch", [], Spec.facts_input(request))
        end)

      assert {:ok, spec} = Spec.build(request, facts)
      assert facts["own_home"] == %{"home" => home}
      assert spec["runtime_home"] == facts["own_home"]["home"]
      assert spec["env"]["unset"] == ["ATLAS_RUNTIME_HOME"]
    end

    test "a refused own home refuses the spec with the helper's text" do
      request = %{
        "harness" => "claude",
        "sandbox" => "read-only",
        "workspace" => "/w",
        "origin" => "client_named"
      }

      assert Spec.build(request, %{
               "own_home" => %{"error" => "ATLAS_RUNTIME_HOME must be an absolute path"}
             }) ==
               {:error, "ATLAS_RUNTIME_HOME must be an absolute path"}
    end
  end

  describe "the launch facts (kind launch, R4)" do
    test "resolve exactly the names passed in, not a list of their own" do
      root = AtlasRuntime.S6Fixture.new_root!()
      user = Path.join(root, "user")
      File.mkdir_p!(Path.join(user, ".ssh"))
      File.mkdir_p!(Path.join(root, "elsewhere"))
      File.ln_s!(Path.join(root, "elsewhere"), Path.join(user, ".s6-extra-name"))

      input = %{
        "user_names" => %{
          "credential" => [".s6-extra-name", ".ssh"],
          "other" => [".s6-only-here"]
        },
        "home_names" => ["s6-extra-home-name"],
        "homes" => [Path.join(root, "home")]
      }

      facts = SpecRows.with_env(%{"HOME" => user}, fn -> Facts.fetch("launch", [], input) end)

      assert facts["user_names"] == %{
               "credential" => [
                 %{
                   "name" => ".s6-extra-name",
                   "path" => Path.join(user, ".s6-extra-name"),
                   "resolved" => Path.join(root, "elsewhere")
                 },
                 %{
                   "name" => ".ssh",
                   "path" => Path.join(user, ".ssh"),
                   "resolved" => Path.join(user, ".ssh")
                 }
               ],
               "other" => [
                 %{
                   "name" => ".s6-only-here",
                   "path" => Path.join(user, ".s6-only-here"),
                   "resolved" => Path.join(user, ".s6-only-here")
                 }
               ]
             }

      assert facts["homes"][Path.join(root, "home")]["names"] == %{
               "s6-extra-home-name" => "absent"
             }
    end

    test "report code.json as written and leave its refusal to the decision" do
      root = AtlasRuntime.S6Fixture.new_root!()

      for {name, content} <- [
            {"absent", nil},
            {"relative", ~s({"token_file": "token"})},
            {"absolute", ~s({"token_file": "#{root}/t/token", "other": 1})},
            {"bad", ~s({"token_file": 7})}
          ] do
        home = Path.join(root, name)
        File.mkdir_p!(home)
        if content, do: File.write!(Path.join(home, "code.json"), content)
      end

      homes = Enum.map(["absent", "relative", "absolute", "bad"], &Path.join(root, &1))

      request = fn home ->
        %{
          "harness" => "codex",
          "scope" => folder_scope(home),
          "folder" => "#{home}/turns/t1",
          "inspector" => "/x/atlas-runtime",
          "origin" => "client_named"
        }
      end

      input = Map.put(Spec.facts_input(request.(Path.join(root, "relative"))), "homes", homes)
      facts = Facts.fetch("launch", [], input)

      assert Enum.map(homes, &facts["homes"][&1]["code_json"]) == [
               "absent",
               %{"token_file" => "token"},
               %{
                 "token_file" => "#{root}/t/token",
                 "token" => %{"resolved" => "#{root}/t/token"}
               },
               %{"error" => "decode"}
             ]

      assert {:error, "Runtime code.json must name an absolute token_file"} =
               Spec.build(request.(Path.join(root, "relative")), facts)
    end

    test "name the folder markers where the Go snapshot package puts them" do
      root = AtlasRuntime.S6Fixture.new_root!()
      home = Path.join(root, "home")
      dest = Path.join(root, "dest")
      marker = SpecRows.marker_path("rebind", home, dest)
      File.mkdir_p!(Path.dirname(marker))
      File.write!(marker, "{}\n")

      facts = Facts.fetch("launch", [], %{"markers" => [%{"home" => home, "root" => dest}]})

      assert facts["markers"] == [
               %{
                 "home" => home,
                 "root" => dest,
                 "rebind" => %{"path" => marker, "present" => true},
                 "preparation" => %{
                   "path" => SpecRows.marker_path("preparation", home, dest),
                   "present" => false
                 }
               }
             ]
    end

    test "list every ancestor of root and nothing else" do
      root = AtlasRuntime.S6Fixture.new_root!()
      File.mkdir_p!(Path.join([root, "a", "b", "c"]))
      File.write!(Path.join([root, "a", "x"]), "")
      facts = Facts.fetch("launch", [], %{"root" => Path.join([root, "a", "b", "c"])})

      assert facts["listings"][Path.join(root, "a")] == %{"entries" => ["b", "x"]}
      assert facts["listings"][Path.join([root, "a", "b"])] == %{"entries" => ["c"]}
      refute Map.has_key?(facts["listings"], Path.join([root, "a", "b", "c"]))
      assert Map.has_key?(facts["listings"], "/")
    end

    test "refuse unknown input fields and arguments" do
      assert_raise RuntimeError,
                   ~r/^workspace facts launch input: json: unknown field "nope"/,
                   fn ->
                     Facts.fetch("launch", [], %{"nope" => 1})
                   end

      assert_raise RuntimeError,
                   "workspace facts launch takes no arguments; its input is JSON on stdin",
                   fn -> Facts.fetch("launch", ["x"], %{}) end
    end
  end

  test "the facts input carries the Elixir name lists" do
    input =
      Spec.facts_input(%{
        "harness" => "codex",
        "scope" => %{"profile" => "dedicated-repository", "root" => "/r/./p"}
      })

    assert input["user_names"]["credential"] == Spec.credential_paths()
    assert input["user_names"]["read"] == Spec.home_read_names()
    assert input["home_names"] == HomeLayout.names()
    assert input["root"] == "/r/p"
  end

  defp folder_scope(home) do
    %{
      "profile" => "materialized-folder",
      "home" => home,
      "root" => "/dest",
      "record" => "#{home}/materializations/m.json",
      "baseline" => "#{home}/snapshots/s/baseline.json",
      "repositories" => ["."]
    }
  end
end

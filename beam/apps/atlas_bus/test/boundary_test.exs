defmodule AtlasBus.BoundaryTest do
  @moduledoc """
  The boundaries of the platform, checked on every test run (here, at the Bus, because
  every layer talks only to it):

  1. Layers talk only over the Bus: no layer depends on, calls or names another layer.
     Checked three ways: the umbrella dependencies in each layer's mix.exs, the remote
     calls in each layer's compiled code, and the module names in its source.
  2. Nothing outside rela's description knows an entity: no source of the Bus, State,
     Control or a client (the TUI, the agents' command line) names one. Entities live in
     `rela/schema.yaml` only.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  @layers %{
    atlas_bus: "AtlasBus",
    atlas_state: "AtlasState",
    atlas_flow: "AtlasFlow",
    atlas_runtime: "AtlasRuntime",
    atlas_control: "AtlasControl"
  }
  # Learn reads the layers through their own read surfaces (a socket, records, the `atlas`
  # client), never over the Bus or by calling them: it depends on no app, names no layer
  # and knows no entity.
  @readers [{"beam/apps/atlas_learn", "AtlasLearn"}]
  # Clients of Control: the TUI, and the command line agents drive Atlas with.
  @clients [{"clients/tui", "AtlasTui"}, {"clients/agent", "AtlasAgent"}]

  # Names of the entities rela describes today. Extend it when rela describes more.
  @entities ~r/\b(scenes?|use[ _-]?cases?|issues?|pull[ _-]?requests?|persons?|people)\b/i

  # GitHub's own words in Runtime's coordinator handoff protocol, not rela's entities: the
  # fixed handoff kind `pull_request` declares a GitHub pull request URL for a worker's branch,
  # and a GitHub issues URL is refused as one (tools/runtime/README.md, "Explicit completion
  # and PR handoff"). Runtime keeps the record in its own home; it never becomes a fact.
  @protocol_names %{
    "beam/apps/atlas_runtime/lib/atlas_runtime/handoffs/handoff_records.ex" => ["pull_request"],
    "beam/apps/atlas_runtime/test/handoff_records_test.exs" => ["pull_request", "issues"],
    "beam/apps/atlas_runtime/test/handoff_service_test.exs" => ["pull_request"]
  }

  # Checks, as functions of source text, so they can be tested on purpose-made violations.

  @doc "Other layers' namespaces that `source` of layer `own` names."
  def foreign_names(source, own) do
    allowed = [own, "AtlasBus"]

    for {_app, namespace} <- @layers,
        namespace not in allowed,
        Regex.match?(~r/\b#{namespace}\b/, code_only(source)),
        do: namespace
  end

  @doc "Entity names in `source`."
  def entity_names(source),
    do: @entities |> Regex.scan(source) |> Enum.map(&hd/1) |> Enum.uniq()

  defp code_only(source),
    do:
      source
      |> String.split("\n")
      |> Enum.reject(&String.match?(&1, ~r/^\s*#/))
      |> Enum.join("\n")

  defp sources(dir) do
    Path.wildcard(Path.join([@root, dir, "{lib,test}", "**", "*.{ex,exs}"]))
    |> Enum.reject(&(&1 == __ENV__.file))
  end

  # Control's contract and its generator, which Control and the TUI compile.
  defp sources(dir, "AtlasControl"),
    do:
      sources(dir) ++
        Path.wildcard(
          Path.join([@root, "bff/{contract,generator}", "{lib,test}", "**", "*.{ex,exs}"])
        )

  defp sources(dir, _own), do: sources(dir)

  describe "the checks catch violations" do
    test "a layer that names another layer" do
      assert foreign_names("AtlasState.Server.handle(x)", "AtlasControl") == ["AtlasState"]

      assert foreign_names("GenServer.call(AtlasControl.Session, :x)", "AtlasState") == [
               "AtlasControl"
             ]

      assert foreign_names("AtlasBus.send(envelope, content)", "AtlasState") == []
      assert foreign_names("# Generated from AtlasControl.Spec", "AtlasTui") == []
    end

    test "a source that names an entity" do
      assert entity_names(~s|defp title("scene"), do: "Scenes"|) == ["scene", "Scenes"]

      assert entity_names("Use case · use_cases · pull request · issues") == [
               "Use case",
               "use_cases",
               "pull request",
               "issues"
             ]

      assert entity_names("a kind of fact") == []
    end
  end

  describe "the platform keeps them" do
    test "each layer depends on the Bus only" do
      for {app, _} <- @layers do
        mix = File.read!(Path.join([@root, "beam/apps", Atom.to_string(app), "mix.exs"]))
        deps = Regex.scan(~r/\{:(\w+), in_umbrella: true\}/, mix) |> Enum.map(&List.last/1)
        expected = if app == :atlas_bus, do: [], else: ["atlas_bus"]

        assert deps == expected,
               "#{app} depends on #{inspect(deps)}; layers may depend on the Bus only"
      end
    end

    test "a reader depends on no other app" do
      for {dir, _} <- @readers do
        mix = File.read!(Path.join([@root, dir, "mix.exs"]))
        deps = Regex.scan(~r/\{:(\w+), in_umbrella: true\}/, mix) |> Enum.map(&List.last/1)
        assert deps == [], "#{dir} depends on #{inspect(deps)}; a reader depends on no app"
      end
    end

    test "no layer's compiled code calls another layer" do
      for {app, own} <- @layers do
        beams =
          Path.wildcard(
            Path.join([Mix.Project.build_path(), "lib", Atom.to_string(app), "ebin", "*.beam"])
          )

        assert beams != [], "#{app} is not compiled"

        for beam <- beams,
            {:ok, {module, [imports: imports]}} =
              :beam_lib.chunks(String.to_charlist(beam), [:imports]),
            {called, _f, _a} <- imports,
            namespace = namespace(called),
            namespace in Map.values(@layers),
            namespace not in [own, "AtlasBus"] do
          flunk("#{inspect(module)} (#{app}) calls #{inspect(called)} directly; use the Bus")
        end
      end
    end

    test "no layer or client names another layer in its source" do
      dirs =
        Enum.map(@layers, fn {app, ns} -> {"beam/apps/#{app}", ns} end) ++ @clients ++ @readers

      for {dir, own} <- dirs, file <- sources(dir, own) do
        names = foreign_names(File.read!(file), own)

        assert names == [],
               "#{Path.relative_to(file, @root)} names #{inspect(names)}; layers talk only over the Bus"
      end
    end

    test "nothing on the BEAM side or in a client names an entity" do
      dirs =
        Enum.map(@layers, fn {app, ns} -> {"beam/apps/#{app}", ns} end) ++ @clients ++ @readers

      files = Enum.flat_map(dirs, fn {dir, own} -> sources(dir, own) end)
      assert Path.join(@root, "bff/contract/lib/blocks.ex") in files
      assert length(files) > 20

      for file <- files do
        relative = Path.relative_to(file, @root)
        names = entity_names(File.read!(file)) -- Map.get(@protocol_names, relative, [])

        assert names == [],
               "#{relative} names #{inspect(names)}; entities belong in rela's description"
      end

      for {relative, _} <- @protocol_names,
          do:
            assert(Path.join(@root, relative) in files, "#{relative} is gone; drop its exemption")
    end
  end

  # The first part of an Elixir module name; nil for Erlang modules (:gen_server, …).
  defp namespace(module) do
    case Atom.to_string(module) do
      "Elixir." <> name -> name |> String.split(".") |> hd()
      _ -> nil
    end
  end
end

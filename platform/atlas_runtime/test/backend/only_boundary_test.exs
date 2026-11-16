defmodule AtlasRuntime.BackendTest.OnlyBoundary do
  @moduledoc """
  The backend reaches the Runtime only through its boundary (design §1.3, §8): the
  compiled code of `AtlasRuntime.Backend.*` calls the facades
  (`AtlasRuntime.Boundary.{Work,Operations,History}` and their structs), Plug, Bandit and
  the standard library,
  plus its own modules and the generated router's support module in the backend
  generator. Checked on the remote calls in each module's BEAM (`:imports`), like
  `AtlasBus.BoundaryTest` checks the layers.
  """
  use ExUnit.Case, async: true

  @facades [
    AtlasRuntime.Boundary.Work,
    AtlasRuntime.Boundary.Operations,
    AtlasRuntime.Boundary.History
  ]
  @libraries [:elixir, :logger, :stdlib, :kernel, :erts, :plug, :bandit]

  @doc "The modules `beam` (a path or a binary) calls that the backend may not, with `facades`."
  def violations(beam, facades) do
    {:ok, {_module, [imports: imports]}} = :beam_lib.chunks(beam, [:imports])

    imports
    |> Enum.map(fn {module, _f, _a} -> module end)
    |> Enum.uniq()
    |> Enum.reject(&allowed?(&1, facades))
    |> Enum.sort()
  end

  defp allowed?(module, facades) do
    name = Atom.to_string(module)

    Enum.any?(facades, fn facade ->
      facade = Atom.to_string(facade)
      name == facade or String.starts_with?(name, facade <> ".")
    end) or
      String.starts_with?(name, "Elixir.AtlasRuntime.Backend.") or
      String.starts_with?(name, "Elixir.AtlasRuntimeBackend.Generator.") or
      library(module) in @libraries
  end

  # The application a module belongs to (consolidated protocols, such as String.Chars, are
  # compiled into the build, but still listed by their application), else where it is.
  defp library(module) do
    case :application.get_application(module) do
      {:ok, app} -> app
      :undefined -> library_by_path(module)
    end
  end

  defp library_by_path(module) do
    case :code.which(module) do
      :preloaded ->
        :erts

      path when is_list(path) ->
        path = List.to_string(path)

        Enum.find(@libraries, fn app ->
          case :code.lib_dir(app) do
            {:error, _} -> false
            dir -> String.starts_with?(path, List.to_string(dir) <> "/")
          end
        end)

      _non_existing ->
        nil
    end
  end

  defp backend_modules do
    {:ok, modules} = :application.get_key(:atlas_runtime, :modules)

    for m <- modules,
        String.starts_with?(Atom.to_string(m), "Elixir.AtlasRuntime.Backend."),
        do: m
  end

  test "AtlasRuntime.Backend.* calls only the facades, Plug, Bandit and the standard library" do
    modules = backend_modules()

    for module <- modules do
      assert violations(:code.which(module), @facades) == [],
             "#{inspect(module)} calls #{inspect(violations(:code.which(module), @facades))}"
    end

    # The Runtime's own router, generated on the facades, is one of them.
    for module <- [
          AtlasRuntime.Backend.Events,
          AtlasRuntime.Backend.Listener,
          AtlasRuntime.Backend.Rest
        ],
        do: assert(module in modules)
  end

  test "the router generated on the test facades calls only those facades" do
    beam = :code.which(AtlasRuntime.Test.WorkRest)

    facades = [
      AtlasRuntime.Test.WorkFacade,
      AtlasRuntime.Test.OperationsFacade,
      AtlasRuntime.Test.HistoryFacade
    ]

    assert violations(beam, facades) == []
    # Each is called; none alone covers the router.
    {:ok, {_, [imports: imports]}} = :beam_lib.chunks(beam, [:imports])
    assert {AtlasRuntime.Test.WorkFacade, :submit, 2} in imports
    assert {AtlasRuntime.Test.OperationsFacade, :pause, 1} in imports
    assert {AtlasRuntime.Test.HistoryFacade, :get_turn, 2} in imports
    for facade <- facades, do: assert(violations(beam, [facade]) != [])
  end

  test "a planted call into the core, the model or another layer is caught" do
    # The planted calls name modules that do not exist; their warnings are not this test's.
    {[{_module, beam}], _warnings} =
      Code.with_diagnostics(fn ->
        Code.compile_string("""
        defmodule AtlasRuntime.Backend.PlantedForTheXrefTest do
          def capacity(client), do: AtlasRuntime.Work.capacity(client)
          def service, do: AtlasRuntime.Service.status()
          def model(map), do: AtlasRuntimeModel.Work.new(map)
          def bus, do: AtlasBus.Link.status()
          def pause(client), do: AtlasRuntime.Operations.pause(client)
          def turns(client), do: AtlasRuntime.History.list_turns(client, %{})
          def fine(conn), do: {AtlasRuntime.Boundary.Work.capacity({"x", []}), Plug.Conn.halt(conn), Enum.count([])}
          def also_fine(c), do: {AtlasRuntime.Boundary.Operations.pause(c), AtlasRuntime.Boundary.History.list_turns(c, %{})}
        end
        """)
      end)

    :code.purge(AtlasRuntime.Backend.PlantedForTheXrefTest)
    :code.delete(AtlasRuntime.Backend.PlantedForTheXrefTest)

    assert violations(beam, @facades) ==
             Enum.sort([
               AtlasBus.Link,
               AtlasRuntime.History,
               AtlasRuntime.Operations,
               AtlasRuntime.Service,
               AtlasRuntime.Work,
               AtlasRuntimeModel.Work
             ])
  end

  # Not calling the core, `AtlasRuntime.Backend.Events` receives notifications under a
  # literal tag; it must stay the one the core sends them with.
  test "the core sends notifications under the tag the backend receives" do
    assert AtlasRuntime.Work.Notifications.tag() == :atlas_runtime_work
  end

  test "no source of the backend names the model or the core behind a facade" do
    for path <- Path.wildcard(Path.expand("../../lib/atlas_runtime/backend/**/*.ex", __DIR__)) do
      code = path |> File.read!() |> String.replace(~r/@(module)?doc\s+"""(?s:.*?)"""/, "")

      refute code =~
               ~r/AtlasRuntime\.Model|AtlasRuntimeModel|AtlasRuntime\.(Work|Operations|History)\b/,
             path
    end
  end
end

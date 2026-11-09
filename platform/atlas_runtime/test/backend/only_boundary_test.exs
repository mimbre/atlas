defmodule AtlasRuntime.BackendTest.OnlyBoundary do
  @moduledoc """
  The backend reaches the Runtime only through its boundary (design §1.3, §8): the
  compiled code of `AtlasRuntime.Backend.*` calls the work facade
  (`AtlasRuntime.Boundary.Work` and its structs), Plug, Bandit and the standard library,
  plus its own modules and the generated router's support module in the backend
  generator. Checked on the remote calls in each module's BEAM (`:imports`), like
  `AtlasBus.BoundaryTest` checks the layers.
  """
  use ExUnit.Case, async: true

  @facade AtlasRuntime.Boundary.Work
  @libraries [:elixir, :logger, :stdlib, :kernel, :erts, :plug, :bandit]

  @doc "The modules `beam` (a path or a binary) calls that the backend may not, with `facade`."
  def violations(beam, facade) do
    {:ok, {_module, [imports: imports]}} = :beam_lib.chunks(beam, [:imports])

    imports
    |> Enum.map(fn {module, _f, _a} -> module end)
    |> Enum.uniq()
    |> Enum.reject(&allowed?(&1, facade))
    |> Enum.sort()
  end

  defp allowed?(module, facade) do
    name = Atom.to_string(module)
    facade = Atom.to_string(facade)

    name == facade or String.starts_with?(name, facade <> ".") or
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

  test "AtlasRuntime.Backend.* calls only the facade, Plug, Bandit and the standard library" do
    modules = backend_modules()

    for module <- modules do
      assert violations(:code.which(module), @facade) == [],
             "#{inspect(module)} calls #{inspect(violations(:code.which(module), @facade))}"
    end

    # AtlasRuntime.Backend.Rest joins in S1d, with the facade it is generated on.
    for module <- [AtlasRuntime.Backend.Events, AtlasRuntime.Backend.Listener],
        do: assert(module in modules)
  end

  test "the router generated on the test facade calls only that facade" do
    beam = :code.which(AtlasRuntime.Test.WorkRest)
    assert violations(beam, AtlasRuntime.Test.WorkFacade) == []
    # And the facade it was given is what it calls.
    {:ok, {_, [imports: imports]}} = :beam_lib.chunks(beam, [:imports])
    assert {AtlasRuntime.Test.WorkFacade, :submit, 2} in imports
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
          def fine(conn), do: {AtlasRuntime.Boundary.Work.capacity({"x", []}), Plug.Conn.halt(conn), Enum.count([])}
        end
        """)
      end)

    :code.purge(AtlasRuntime.Backend.PlantedForTheXrefTest)
    :code.delete(AtlasRuntime.Backend.PlantedForTheXrefTest)

    assert violations(beam, @facade) ==
             Enum.sort([
               AtlasBus.Link,
               AtlasRuntime.Service,
               AtlasRuntime.Work,
               AtlasRuntimeModel.Work
             ])
  end

  test "no source of the backend names the model or the work core" do
    for path <- Path.wildcard(Path.expand("../../lib/atlas_runtime/backend/**/*.ex", __DIR__)) do
      code = path |> File.read!() |> String.replace(~r/@(module)?doc\s+"""(?s:.*?)"""/, "")
      refute code =~ ~r/AtlasRuntime\.Model|AtlasRuntimeModel|AtlasRuntime\.Work\b/, path
    end
  end
end

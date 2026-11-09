defmodule AtlasRuntime.Boundary.InBeamCallerTest do
  # Design §13 case 11: an in-BEAM caller works through AtlasRuntime.Boundary.Work alone.
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness
  alias AtlasRuntime.Test.InBeamWorkCaller

  @moduletag capture_log: true

  test "a co-located caller runs work through the facade alone" do
    bench = start!()
    folder = Path.join(bench.workspace, "in-beam")
    File.mkdir_p!(folder)

    work = InBeamWorkCaller.run(client(), folder, "complete in the BEAM")
    assert work.state == :completed
    assert hd(work.attempts).result.answer == "done: complete in the BEAM"
  end

  test "its compiled code calls no Runtime module but the facade (xref over its imports)" do
    beam = :code.which(InBeamWorkCaller)
    assert is_list(beam)
    {:ok, {_, [imports: imports]}} = :beam_lib.chunks(beam, [:imports])
    called = imports |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    runtime =
      for module <- called,
          name = Atom.to_string(module),
          String.starts_with?(name, [
            "Elixir.AtlasRuntime.",
            "Elixir.AtlasRuntimeModel",
            "Elixir.AtlasRuntimeBoundary"
          ]),
          do: module

    assert AtlasRuntime.Boundary.Work in runtime
    assert runtime -- [AtlasRuntime.Boundary.Work] == []
  end

  test "the check catches a caller that reaches past the facade" do
    {:ok, _module, binary} =
      """
      defmodule AtlasRuntime.Test.PlantedCaller do
        def run(client), do: AtlasRuntime.Work.capacity(client)
      end
      """
      |> Code.string_to_quoted!()
      |> then(&:elixir_compiler.quoted(&1, "planted.ex", fn _, _ -> :ok end))
      |> then(fn [{module, binary}] -> {:ok, module, binary} end)

    {:ok, {_, [imports: imports]}} = :beam_lib.chunks(binary, [:imports])
    assert {AtlasRuntime.Work, :capacity, 1} in imports
  end
end

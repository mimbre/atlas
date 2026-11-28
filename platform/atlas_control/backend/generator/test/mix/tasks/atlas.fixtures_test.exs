defmodule Mix.Tasks.Atlas.FixturesTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  setup do
    previous = Application.get_env(:atlas_bff, :contract)
    Application.put_env(:atlas_bff, :contract, AtlasBFF.Example)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:atlas_bff, :contract, previous),
        else: Application.delete_env(:atlas_bff, :contract)
    end)
  end

  test "streams the requested page of JSON specimens" do
    lines =
      capture_io(fn ->
        Mix.Tasks.Atlas.Fixtures.run(~w(--kind block --name card --offset 1 --limit 2))
      end)
      |> String.split("\n", trim: true)

    assert length(lines) == 2
    assert Enum.all?(lines, &(JSON.decode!(&1)["type"] == "card"))
  end

  test "rejects invalid paging" do
    assert_raise Mix.Error, fn ->
      Mix.Tasks.Atlas.Fixtures.run(~w(--kind block --name card --limit 0))
    end
  end
end

defmodule AtlasGates.EvaluateTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  test "--from-subject derives its request through Control, including with --no-record" do
    {name, gate} =
      Enum.find(AtlasGates.Definitions.gates(), fn {_, gate} -> gate["purpose"] == "decider" end)

    values = Map.new(gate["fingerprint"]["fields"], &{&1, "sample"})
    subject = %{"key" => "C-7", "values" => values, "links" => %{}}
    path = Path.join(System.tmp_dir!(), "gates-subject-#{System.unique_integer([:positive])}")
    # The executable answers only the read command. A write would fail the test.
    File.write!(
      path,
      "#!/bin/sh\n[ \"$1\" = facts ] || exit 77\nif [ \"$2\" = _ ]; then\ncat <<'FACT'\n#{JSON.encode!(%{"fact" => subject})}\nFACT\nelse\nprintf '%s\\n' '{\"facts\":[]}'\nfi\n"
    )

    File.chmod!(path, 0o700)
    on_exit(fn -> File.rm!(path) end)

    output =
      capture_io(fn ->
        Mix.Tasks.Atlas.Gates.Evaluate.run([
          "--gate",
          name,
          "--from-subject",
          "C-7",
          "--env",
          "test",
          "--atlas",
          path,
          "--json",
          "--no-record"
        ])
      end)

    result = output |> String.split("\n", trim: true) |> List.last() |> JSON.decode!()
    assert result["verdict"] == gate["decide"]["advise"]
    assert result["unsettled"] == nil
    assert result["recorded"] == nil
  end

  test "recording still requires an explicit environment when no dry option is given" do
    assert_raise Mix.Error, ~r/Give --env/, fn ->
      Mix.Tasks.Atlas.Gates.Evaluate.run([])
    end
  end

  test "--no-record settles and prints locally, without an environment or a client" do
    {name, gate} =
      Enum.find(AtlasGates.Definitions.gates(), fn {_, g} ->
        match?(%{"all" => _}, g["rule"])
      end)

    evidence =
      Enum.reduce(gate["rule"]["all"], %{}, fn
        ["equals", key, value], acc -> Map.put(acc, key, value)
        ["same", a, b], acc -> acc |> Map.put(a, "same") |> Map.put(b, "same")
      end)

    path = Path.join(System.tmp_dir!(), "gates-dry-#{System.unique_integer([:positive])}.json")
    File.write!(path, JSON.encode!(evidence))
    on_exit(fn -> File.rm!(path) end)

    output =
      capture_io(fn ->
        Mix.Tasks.Atlas.Gates.Evaluate.run([
          "--gate",
          name,
          "--subject",
          "C-7",
          "--fingerprint",
          "f-1",
          "--evidence-file",
          path,
          "--json",
          "--no-record",
          "--atlas",
          "/must-never-be-called"
        ])
      end)

    result = output |> String.split("\n", trim: true) |> List.last() |> JSON.decode!()
    assert result["verdict"] == gate["decide"]["pass"]
    assert result["rule_outcome"] == "pass"
    assert result["unsettled"] == nil
    assert result["recorded"] == nil
    assert result["recorded_as"] == nil
  end
end

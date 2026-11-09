defmodule AtlasFlowGenerator.RuntimeTest do
  use ExUnit.Case, async: true

  alias AtlasFlowGenerator.{Atlas, Example, Header, Rela}

  defmodule Target do
    use AtlasFlowGenerator.Runtime, target: "golden/example.flows.json"
  end

  test "a component reads the subflows, gates and hash of the target it was compiled with" do
    assert Map.keys(Target.flows()) == ["letter"]

    assert %{"kind" => "gate", "spec" => %{"gate" => "proofread"}} =
             Target.flows()["letter"]["states"]["proofread"]

    assert Target.gates()["size_limit"]["flavor"] == "rule"
    assert Target.rela_flows_sha256() == Atlas.sha256(Rela.flows_yaml(Example.__flows__()))
  end

  test "it accepts the flows.yaml of the same run and refuses any other" do
    yaml = Rela.flows_yaml(Example.__flows__())
    assert Target.check_rela_flows(yaml) == :ok

    assert {:error, "flows.yaml (sha256 " <> why} =
             Target.check_rela_flows(String.replace(yaml, "label: Letter", ~s(label: "Letter")))

    assert why =~ "is not the one generated with flows.json"
  end

  @tag :tmp_dir
  test "the header key is not part of the data", %{tmp_dir: dir} do
    path = Path.join(dir, "flows.json")
    File.write!(path, Header.put(".json", "x.ex", File.read!("test/golden/example.flows.json")))
    assert {:ok, data} = AtlasFlowGenerator.Runtime.read(path)
    refute Map.has_key?(data, "_generated")
    assert Map.keys(data) == ~w(flows format gates rela_flows_sha256 writer)
  end

  @tag :tmp_dir
  test "a target of another format, not JSON, or missing fails the compile", %{tmp_dir: dir} do
    other = Path.join(dir, "other.json")
    golden = File.read!("test/golden/example.flows.json")
    File.write!(other, String.replace(golden, ~s("format": 2), ~s("format": 1)))
    broken = Path.join(dir, "broken.json")
    File.write!(broken, "{")

    for {path, message} <- [
          {other, "is not a flows.json of format 2 by system:atlas-flow"},
          {broken, "is not a flows.json of format 2"},
          {Path.join(dir, "none.json"), "cannot read it (no such file or directory)"}
        ] do
      src =
        "defmodule #{inspect(:"Elixir.T#{System.unique_integer([:positive])}")} do " <>
          "use AtlasFlowGenerator.Runtime, target: #{inspect(path)}\nend\n"

      error = assert_raise CompileError, fn -> Code.compile_string(src, "runtime_fixture.ex") end
      assert error.description =~ message
      assert error.file =~ "runtime_fixture.ex"
    end
  end
end

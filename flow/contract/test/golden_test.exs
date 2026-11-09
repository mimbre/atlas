defmodule AtlasFlowContract.GoldenTest do
  use ExUnit.Case, async: true

  alias AtlasFlowGenerator.Rela

  # test/golden/issue.flows.yaml is the approved Issue flow (the design's
  # input-definitions/issue.flows.yaml, copied unchanged). Rela gives it this version;
  # a run keeps the version it started with, so the generated file must keep it too.
  @version "5e2320f6db243534"

  defp below_header(text),
    do: text |> String.split("\n") |> Enum.drop_while(&(&1 =~ ~r/^#/)) |> Enum.join("\n")

  defp generated, do: Rela.flows_yaml(AtlasFlowContract.Issue.__flows__())

  test "Issue's flows.yaml is byte-identical to the approved file below the header" do
    assert generated() == below_header(File.read!("test/golden/issue.flows.yaml"))
  end

  test "the committed target holds it, and its diagram shows the same version" do
    assert below_header(File.read!("../targets/rela/flows.yaml")) == generated()
    assert File.read!("../targets/diagrams/issue.md") =~ "Rela flow version: `#{@version}`"
  end

  @tag :rela
  test "the pinned rela finds it valid, with the approved version" do
    bin = Path.join(System.fetch_env!("ATLAS_RELA_BIN"), "rela")
    flows = AtlasFlowContract.Issue.__flows__()
    yaml = File.read!("../targets/rela/flows.yaml")
    assert {:ok, [%{"name" => "issue", "version" => @version}]} = Rela.check(bin, yaml, flows)
  end
end

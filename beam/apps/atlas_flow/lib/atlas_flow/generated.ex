defmodule AtlasFlow.Generated do
  @moduledoc "The executable target, embedded with the release."
  defmodule Prod do
    use RelaDSL.Runtime, target: "../../../../../model/targets/atlas/flows.json"
  end

  defmodule Test do
    use RelaDSL.Runtime, target: "../../../../../model/targets/test/atlas/flows.json"
  end

  defp target, do: if(AtlasBus.environment() == "test", do: Test, else: Prod)
  def flows, do: target().flows()
  def gates, do: target().gates()
  def rela_flows_sha256, do: target().rela_flows_sha256()
  def check_rela_flows(bytes), do: target().check_rela_flows(bytes)
end

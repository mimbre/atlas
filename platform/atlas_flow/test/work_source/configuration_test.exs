defmodule AtlasFlow.WorkSource.ConfigurationTest do
  # IS-Atlas-27: the Runtime's configuration on its machinery fact, served in a poll answer
  # while the Runtime runs another version, and what the Runtime did with it written back.
  # Through AtlasFlow.WorkSource on FakeFacts, as the Delivery tests are.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias AtlasFlow.{FakeFacts, WorkSource}
  alias AtlasFlow.FakeFacts.Leasing, as: L
  alias AtlasFlow.WorkSource.Configuration

  @mini {"mini", "ada"}

  setup do
    dir = Path.join(System.tmp_dir!(), "configuration-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    L.start(dir)
  end

  defp machinery(values),
    do:
      FakeFacts.put(Configuration.kind(), %{"key" => "mini", "values" => values, "version" => 1})

  defp values, do: FakeFacts.get(Configuration.kind(), "mini")["values"]

  defp document(version), do: JSON.encode!(%{"version" => version, "profiles" => %{}})

  defp poll(policy_version, refused \\ nil) do
    input = %{L.poll_input("mini") | policy_version: policy_version}
    input = if refused, do: Map.put(input, :configuration_refused, refused), else: input
    {:polled, polled} = WorkSource.poll(@mini, input)
    polled
  end

  test "served while the Runtime runs another version; its applied version is recorded" do
    machinery(%{"name" => "mini", "configuration" => document(2)})

    assert poll(1).configuration == document(2)
    assert values()["applied_version"] == 1

    refute Map.has_key?(poll(2), :configuration)
    assert values()["applied_version"] == 2
  end

  test "a refusal is recorded, and the refused version is not served again" do
    machinery(%{"name" => "mini", "configuration" => document(3)})
    assert poll(1).configuration == document(3)

    refute Map.has_key?(poll(1, %{version: 3, reason: "invalid: slots"}), :configuration)

    assert %{"refused_version" => 3, "refused_reason" => "invalid: slots", "applied_version" => 1} =
             values()

    refute Map.has_key?(poll(1), :configuration)

    # The supervisor raises the version: served again.
    FakeFacts.put(Configuration.kind(), %{
      "key" => "mini",
      "values" => Map.put(values(), "configuration", document(4)),
      "version" => 2
    })

    assert poll(1, %{version: 3, reason: "invalid: slots"}).configuration == document(4)
  end

  test "a document without a version is never served, and shown refused by Flow" do
    machinery(%{"name" => "mini", "configuration" => "{\"profiles\": {}}"})

    refute Map.has_key?(poll(1), :configuration)
    assert values()["refused_version"] == 0
    assert values()["refused_reason"] =~ "positive integer version"
  end

  test "no machinery fact, or none with a configuration: the poll is answered as before" do
    refute Map.has_key?(poll(1), :configuration)
    machinery(%{"name" => "mini"})
    refute Map.has_key?(poll(1), :configuration)
    assert values()["applied_version"] == 1
  end
end

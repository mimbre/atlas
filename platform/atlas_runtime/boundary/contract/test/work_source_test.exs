defmodule AtlasRuntimeBoundary.WorkSourceTest do
  use ExUnit.Case, async: true

  alias AtlasRuntimeBoundary.WorkSource

  # Decision 2026-11-17-work-acquisition §5.1, §5.2, written out by hand: a change to the
  # contract's capabilities or outcomes must change this file too.

  @schema WorkSource.__schema__()
  @json Path.expand("../../targets/json/work_source.json", __DIR__)

  defp model(name), do: Enum.find(@schema.models, &(&1.name == name))
  defp fields(name), do: for(f <- model(name).fields, do: f.name)
  defp field(model, name), do: Enum.find(model(model).fields, &(&1.name == name))

  test "§5.2: four capabilities, the Runtime's right lease, and their outcomes" do
    assert for(
             c <- @schema.capabilities,
             do: {c.name, c.input, c.right, Enum.map(c.outcomes, &{&1.name, &1.model})}
           ) ==
             [
               {:poll, :poll_input, :lease, [polled: :polled, rejected: :rejected]},
               {:report, :report_input, :lease,
                [recorded: :recorded, lease_lost: nil, rejected: :rejected]},
               {:get_blob, :get_blob_input, :lease,
                [blob: :blob, not_found: nil, rejected: :rejected]},
               {:put_blob, :put_blob_input, :lease,
                [
                  stored: nil,
                  lease_lost: nil,
                  too_large: nil,
                  not_referenced: nil,
                  rejected: :rejected
                ]}
             ]

    assert field(:client, :rights).type == {:list, {:enum, [:lease]}}

    assert @schema.invalid_input == %{
             outcome: :rejected,
             set: [reason: :invalid],
             detail: :detail
           }
  end

  test "§5.2 poll: offer, holdings and the answer's leases, cancels, lost leases and timing" do
    assert fields(:poll_input) ==
             [:runtime_id, :incarnation, :build, :policy_version, :offer, :holdings]

    assert field(:poll_input, :offer).type == {:map, :integer}
    assert fields(:holding) == [:lease_id, :state, :last_progress_at]
    assert fields(:polled) == [:leases, :cancel, :lease_lost, :timing]
    assert fields(:lease) == [:lease_id, :expires_at, :work]
    assert field(:timing, :poll_max).range == {1, 25}
  end

  test "§5.1: work as offered has no slot, folder, resume_from or repository; its input is a base" do
    for name <- [:offered_work, :work_input, :base_ref, :change_set_ref],
        forbidden <- [:slot, :folder, :resume_from, :repository, :workspace, :path] do
      refute forbidden in fields(name), "#{name}.#{forbidden}"
    end

    assert fields(:work_input) == [:base, :change_set, :permissions]
    assert field(:work_input, :base).required
    refute field(:work_input, :change_set).required
  end

  test "§5.1 report: accepted, refused, started, ended, by revision" do
    assert field(:report_input, :report).type ==
             {:one_of, [:accepted, :refused, :started, :ended], tag: :state}

    assert field(:report_input, :revision).range == {1, 2_147_483_647}
    assert fields(:ended) == [:result, :provenance, :change_set]
    assert fields(:recorded) == [:missing]
  end

  test "§5.2 blobs: a download and an upload, each a :stream" do
    assert field(:blob, :content) == %{name: :content, type: :stream, required: true}
    assert field(:put_blob_input, :content) == %{name: :content, type: :stream, required: true}
    assert fields(:put_blob_input) == [:lease_id, :sha256, :size, :content]
  end

  test "the JSON target is what the contract generates (mix runtime_boundary.gen --check)" do
    json = @json |> File.read!() |> JSON.decode!()
    assert json["$comment"] =~ "boundary/contract/lib/work_source.ex"

    assert Enum.map(json["capabilities"], & &1["name"]) == [
             "poll",
             "report",
             "get_blob",
             "put_blob"
           ]
  end
end

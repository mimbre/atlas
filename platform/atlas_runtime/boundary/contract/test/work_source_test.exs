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
             [
               :runtime_id,
               :incarnation,
               :build,
               :policy_version,
               :offer,
               :holdings,
               :configuration_refused,
               :upgrade
             ]

    assert field(:poll_input, :offer).type == {:map, :integer}
    assert fields(:holding) == [:lease_id, :state, :last_progress_at]
    assert fields(:polled) == [:leases, :cancel, :lease_lost, :timing, :configuration, :upgrade]
    assert fields(:lease) == [:lease_id, :expires_at, :work]
    assert field(:timing, :poll_max).range == {1, 25}
  end

  test "IS-Atlas-27: the Runtime's configuration rides the poll, optional both ways" do
    refute field(:poll_input, :configuration_refused).required
    assert field(:poll_input, :configuration_refused).type == :configuration_refusal
    assert fields(:configuration_refusal) == [:version, :reason]
    assert field(:configuration_refusal, :version).required
    assert field(:configuration_refusal, :reason).required
    refute field(:polled, :configuration).required
    assert field(:polled, :configuration).type == :string
  end

  test "IS-Atlas-26: a Runtime's upgrade rides the poll, optional both ways" do
    refute field(:polled, :upgrade).required
    assert field(:polled, :upgrade).type == :upgrade_order
    assert fields(:upgrade_order) == [:id, :build]
    refute field(:poll_input, :upgrade).required
    assert field(:poll_input, :upgrade).type == :upgrade_report
    assert fields(:upgrade_report) == [:id, :step, :busy, :mode, :failed_step, :reason]

    assert field(:upgrade_report, :step).type ==
             {:enum, [:draining, :updating, :restarted, :failed]}

    refute field(:upgrade_report, :failed_step).required
  end

  test "§5.1: work as offered has no slot, folder, resume_from or repository; its input is a base" do
    for name <- [:offered_work, :work_input, :base_ref, :change_set_ref],
        forbidden <- [:slot, :folder, :resume_from, :repository, :workspace, :path] do
      refute forbidden in fields(name), "#{name}.#{forbidden}"
    end

    assert fields(:work_input) == [:base, :change_set, :permissions, :result_ref]
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

  test "K1: the ended change set declares its base, as the Runtime freezes and imports it" do
    assert fields(:change_set) == [:base, :roots]
    assert field(:change_set, :base) == %{name: :base, type: :string, required: true}

    # The same type and requiredness as the Work contract's frozen result, which
    # Sources.Upload sends as the change set (base + roots).
    frozen = Enum.find(AtlasRuntimeBoundary.Work.__schema__().models, &(&1.name == :frozen))
    assert Enum.find(frozen.fields, &(&1.name == :base)) == field(:change_set, :base)
  end

  test "K1: the JSON target's change_set takes a change set with base and refuses one without" do
    models = @json |> File.read!() |> JSON.decode!() |> Map.fetch!("models")

    entry = %{
      "path" => "a.txt",
      "op" => "write",
      "kind" => "file",
      "mode" => "100644",
      "size" => 2,
      "sha256" => String.duplicate("a", 64)
    }

    set = %{
      "base" => "sha256:" <> String.duplicate("b", 64),
      "roots" => [%{"root" => "atlas", "fingerprint" => "csf_x", "entries" => [entry]}]
    }

    assert conform(models, "change_set", set) == []
    assert conform(models, "change_set", Map.delete(set, "base")) == [{:missing, ["base"]}]
    assert conform(models, "change_set", %{set | "base" => 1}) == [{:type, ["base"]}]
  end

  # Problems of `value` against the JSON target's model `name`: missing required fields,
  # undeclared keys, and scalar type mismatches, each with its path.
  defp conform(models, name, value, at \\ []) do
    model = Enum.find(models, &(&1["name"] == name)) || flunk("no model #{name}")
    declared = Map.new(model["fields"], &{&1["name"], &1})

    missing =
      for %{"name" => f, "required" => true} <- model["fields"],
          not Map.has_key?(value, f),
          do: {:missing, at ++ [f]}

    unknown = for k <- Map.keys(value), not Map.has_key?(declared, k), do: {:unknown, at ++ [k]}

    typed =
      for {k, v} <- value, f = declared[k], problem <- typed(models, f, v, at ++ [k]), do: problem

    missing ++ unknown ++ typed
  end

  defp typed(models, %{"type" => "list of " <> inner} = f, v, at) when is_list(v),
    do: Enum.flat_map(v, &typed(models, %{f | "type" => inner}, &1, at))

  defp typed(_models, %{"type" => "string"}, v, _at) when is_binary(v), do: []
  defp typed(_models, %{"type" => "integer"}, v, _at) when is_integer(v), do: []
  defp typed(_models, %{"type" => "boolean"}, v, _at) when is_boolean(v), do: []

  defp typed(_models, %{"type" => "enum", "values" => vs}, v, at) when is_binary(v),
    do: if(v in vs, do: [], else: [{:enum, at}])

  defp typed(models, %{"type" => model}, v, at) when is_map(v) and not is_struct(v) do
    if Enum.any?(models, &(&1["name"] == model)),
      do: conform(models, model, v, at),
      else: [{:type, at}]
  end

  defp typed(_models, _f, _v, at), do: [{:type, at}]

  test "§5.2 blobs: a download and an upload, each a :stream" do
    assert field(:blob, :content) == %{name: :content, type: :stream, required: true}
    assert field(:put_blob_input, :content) == %{name: :content, type: :stream, required: true}
    assert fields(:put_blob_input) == [:lease_id, :sha256, :size, :content]
  end

  test "the JSON target carries the contract's capabilities (mix runtime_boundary.gen)" do
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

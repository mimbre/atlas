defmodule AtlasRuntime.Operations.PolicyViewTest do
  # The policy view through the facade (design §13.1 Q7): only the operations contract's
  # policy fields, at every depth, never the file or the quota evidence, read again on
  # every call.
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness
  alias AtlasRuntime.{Availability, Policy}
  alias AtlasRuntime.Boundary.Operations, as: F
  alias AtlasRuntimeBoundary.Generator.NotPermitted

  @moduletag capture_log: true
  @operator {"local:test", [:inspect, :operate]}
  @now 1_794_050_000
  @claude %{"provider" => "anthropic", "harness" => "claude", "model" => "claude-opus-5-5"}
  @codex %{"provider" => "openai", "harness" => "codex", "model" => "gpt-6.1-sol"}
  @policy %{
    "version" => 3,
    "changed_by" => "operator",
    "changed_at" => "2026-11-16T09:00:00Z",
    "buffer_size" => 4,
    "slots" => ["dev1", "dev2"],
    "independence" => %{"different_from" => "model"},
    "profiles" => %{
      "independent_review" => %{
        "permissions" => ["review-packet", "read-only"],
        "cost_classes" => ["low", "standard"],
        "options" => [@codex, @claude]
      },
      "deep_coding" => %{
        "permissions" => ["dedicated-repository", "workspace-write"],
        "cost_classes" => ["standard", "high"],
        "options" => [@claude, @codex],
        "limits" => %{"max_duration" => 7_200}
      }
    }
  }
  @weekly Path.join(__DIR__, "../fixtures/claude_weekly_quota.json")
          |> File.read!()
          |> JSON.decode!()
          |> Map.fetch!("rate_limit_info")
  # 2100-01-01: still ahead.
  @reset 4_102_444_800

  # The real Service and work core on a home with this policy; Codex and Claude installed.
  setup do
    bench = start!()
    File.write!(Policy.path(bench.dir), JSON.encode!(@policy))
    %{bench: bench, tmp_dir: bench.dir}
  end

  defp claude_out(dir, reset) do
    Availability.persist(
      dir,
      put_in(Availability.empty(), ["quota", "claude"], %{
        "evidence" => Map.put(@weekly, "resetsAt", reset),
        "turn_id" => "turn-00000000000000aa",
        "observed_at" => @now,
        "reenabled_at" => nil
      })
    )
  end

  # Every key at every depth is a field of the contract's model there.
  defp only_contract_fields(value, model) do
    models = Map.new(AtlasRuntimeBoundary.Operations.__schema__().models, &{&1.name, &1})
    walk(value, model, models)
  end

  defp walk(map, model, models) when is_map(map) do
    fields = Map.new(models[model].fields, &{Atom.to_string(&1.name), &1.type})

    for {key, value} <- map do
      key = to_string(key)
      assert Map.has_key?(fields, key), "#{key} is not a field of #{model}"
      walk_type(value, fields[key], models)
    end
  end

  defp walk_type(values, {:list, inner}, models),
    do: Enum.each(values, &walk_type(&1, inner, models))

  defp walk_type(value, type, models)
       when is_atom(type) and is_map(value) and not is_struct(value),
       do: if(Map.has_key?(models, type), do: walk(value, type, models))

  defp walk_type(_value, _type, _models), do: :ok

  test "only the contract's fields, at every depth, also when a harness is out", %{tmp_dir: dir} do
    claude_out(dir, @reset)
    view = F.policy(@operator)
    assert %F.Outcome.Policy{} = view

    dumped = F.Outcome.Policy.dump(view)
    only_contract_fields(dumped, :policy)
    # The evidence and the file's own fields stay out.
    text = JSON.encode!(dumped)
    refute text =~ "seven_day"
    refute text =~ "turn-00000000000000aa"
    refute Map.has_key?(dumped, "slots")

    # I-PV itself, before any struct: the same holds.
    Policy.load(dir)
    |> Policy.view(Availability.load(dir), ["claude", "codex"], @now)
    |> only_contract_fields(:policy)
  end

  test "shows each profile's options in order, with their availability now", %{tmp_dir: dir} do
    claude_out(dir, @reset)
    File.rm!(Path.join([dir, "bin", "codex"]))

    assert %F.Outcome.Policy{
             version: 3,
             changed_by: "operator",
             changed_at: ~U[2026-11-16 09:00:00Z],
             buffer_size: 4,
             independence: %F.Independence{different_from: :model},
             profiles: [deep, review]
           } = F.policy(@operator)

    assert %F.ProfilePolicy{
             profile: "deep_coding",
             permissions: [:"dedicated-repository", :"workspace-write"],
             cost_classes: [:standard, :high],
             limits: %F.ProfileLimits{max_duration: 7_200},
             options: [claude, codex]
           } = deep

    assert %F.PolicyOption{harness: "claude", model: "claude-opus-5-5", provider: "anthropic"} =
             claude

    until = DateTime.from_unix!(@reset)

    assert %F.OptionAvailability{available: false, reason: :quota, until: ^until} =
             claude.availability

    assert %F.OptionAvailability{available: false, reason: :not_installed} = codex.availability

    # A profile without limits shows the default that applies.
    assert %F.ProfilePolicy{profile: "independent_review", limits: %{max_duration: 3_600}} =
             review
  end

  test "a quota mark without a known return is out with no until", %{tmp_dir: dir} do
    claude_out(dir, nil)
    %{profiles: [%{options: [claude, codex]} | _]} = F.policy(@operator)

    assert %F.OptionAvailability{available: false, reason: :quota, until: nil} =
             claude.availability

    assert %F.OptionAvailability{available: true, reason: nil} = codex.availability
  end

  test "the version follows a hand edit of policy.json", %{tmp_dir: dir} do
    assert %{version: 3} = F.policy(@operator)
    File.write!(Policy.path(dir), JSON.encode!(%{@policy | "version" => 4}))
    assert %{version: 4} = F.policy(@operator)
    # The core reads the same file: runtime info shows the same version.
    assert %{policy_version: 4} = F.runtime_info(@operator)
  end

  test "without a valid policy nothing is permitted", %{tmp_dir: dir} do
    File.rm!(Policy.path(dir))
    assert %F.Outcome.Policy{version: 0, profiles: [], buffer_size: 1} = F.policy(@operator)

    File.write!(Policy.path(dir), "{")
    assert %F.Outcome.Policy{version: 0, profiles: []} = F.policy(@operator)
  end

  test "inspect is the right it needs" do
    assert %F.Outcome.Policy{} = F.policy({"remote:x", [:inspect]})
    assert %NotPermitted{capability: :policy, right: :inspect} = F.policy({"x", [:operate]})
  end
end

defmodule AtlasRuntime.BackendPolicyTest do
  use ExUnit.Case, async: true
  alias AtlasRuntime.BackendPolicy, as: Policy
  @now 1_794_050_000
  @preferred %{"backend" => "claude", "model" => "claude-opus-5-5[1m]"}
  @fallback %{"backend" => "codex", "model" => "gpt-6.1-sol"}

  defp configured, do: Policy.configure(Policy.empty(), @preferred, @fallback)

  defp evidence do
    Path.join(__DIR__, "fixtures/claude_weekly_quota.json")
    |> File.read!()
    |> JSON.decode!()
    |> Map.fetch!("rate_limit_info")
  end

  defp blocked, do: Policy.record_quota(configured(), evidence(), "native-quota-turn", @now)

  @tag :tmp_dir
  test "policy owns atomic persistence and validates saved preferences", %{tmp_dir: dir} do
    assert Policy.load(dir) == Policy.empty()
    policy = blocked()
    assert :ok = Policy.persist(dir, policy)
    assert Policy.load(dir) == policy
    refute File.exists?(Path.join(dir, "backends.json.tmp"))
    File.write!(Path.join(dir, "backends.json"), JSON.encode!(%{"unexpected" => true}))
    assert_raise RuntimeError, "Unknown backend policy fields", fn -> Policy.load(dir) end
  end

  test "default, preferred and explicit selection retain the requested model without claiming native identity" do
    assert Policy.select(Policy.empty(), nil, %{}, @now) == %{
             "requested" => %{"backend" => "codex", "model" => nil},
             "selected" => %{"backend" => "codex", "model" => nil},
             "reason" => "default"
           }

    assert Policy.select(configured(), nil, %{}, @now)["selected"] == @preferred
    explicit = Policy.select(blocked(), "claude", %{}, @now)
    assert explicit["selected"] == @preferred
    assert explicit["reason"] == "explicit"
    refute Map.has_key?(explicit, "quota")
  end

  test "exact native weekly rejection survives serialization and routes only the next assignment" do
    policy = blocked() |> JSON.encode!() |> JSON.decode!() |> Policy.validate!()
    selected = Policy.select(policy, nil, %{}, @now)
    assert selected["requested"] == @preferred
    assert selected["selected"] == @fallback
    assert selected["reason"] == "confirmed_weekly_quota"
    assert selected["quota"]["evidence"] == evidence()
    assert selected["quota"]["turn_id"] == "native-quota-turn"
    refute Policy.view(policy, @now)["claude_eligible"]

    assert Policy.configure(policy, @preferred, @fallback)["claude_quota"] ==
             policy["claude_quota"]
  end

  test "structured reset boundary and explicit reenable restore preference while preserving evidence" do
    policy = blocked()
    reset = evidence()["resetsAt"]
    assert Policy.select(policy, nil, %{}, reset - 1)["selected"] == @fallback
    assert Policy.select(policy, nil, %{}, reset)["selected"] == @preferred

    enabled =
      Policy.reenable(policy, "claude", @now)
      |> JSON.encode!()
      |> JSON.decode!()
      |> Policy.validate!()

    assert Policy.select(enabled, nil, %{}, @now)["selected"] == @preferred
    assert enabled["claude_quota"]["evidence"] == evidence()

    assert Policy.record_quota(enabled, evidence(), "new-rejection", @now + 1)
           |> Policy.eligible?(@now + 1) == false
  end

  test "localized or missing resets remain unknown until explicit reenable" do
    for reset <- [nil, "1pm", -1] do
      policy =
        Policy.record_quota(configured(), Map.put(evidence(), "resetsAt", reset), "quota", @now)

      assert policy["claude_quota"]["evidence"]["resetsAt"] == nil
      assert Policy.select(policy, nil, %{}, @now + 99_999_999)["selected"] == @fallback
      assert Policy.reenable(policy, "claude", @now) |> Policy.eligible?(@now)
    end
  end

  test "authentication, network, other windows and usable overage never poison eligibility" do
    for event <- [
          %{"type" => "error", "message" => "weekly limit authentication network"},
          Map.put(evidence(), "rateLimitType", "five_hour"),
          Map.put(evidence(), "status", "allowed"),
          Map.put(evidence(), "overageStatus", "allowed"),
          Map.put(evidence(), "isUsingOverage", true)
        ] do
      policy = Policy.record_quota(configured(), event, "not-weekly-quota", @now)
      assert Policy.select(policy, nil, %{}, @now)["selected"] == @preferred
      assert policy["claude_quota"] == nil
    end
  end

  test "capability failures never change backend or downgrade permissions" do
    assert_raise RuntimeError, ~r/Selected claude/, fn ->
      Policy.select(configured(), nil, %{"sandbox" => "workspace-write"}, @now)
    end

    assert_raise RuntimeError, ~r/Selected codex/, fn ->
      Policy.select(blocked(), nil, %{"permissions" => "unrestricted"}, @now)
    end

    assert_raise RuntimeError, ~r/Selected codex/, fn ->
      Policy.select(
        blocked(),
        nil,
        %{"permissions" => "dedicated-repository", "sandbox" => "read-only"},
        @now
      )
    end

    assert Policy.select(
             blocked(),
             nil,
             %{
               "permissions" => "dedicated-repository",
               "repository" => "https://github.com/eyra/atlas.git"
             },
             @now
           )["selected"] == @fallback
  end

  test "Claude provisioning requires explicit scope and preserves provider selection" do
    request = %{
      "permissions" => "dedicated-repository",
      "repository" => "https://github.com/eyra/atlas.git"
    }
    assert Policy.select(configured(), nil, request, @now)["selected"] == @preferred
    assert Policy.select(blocked(), "claude", request, @now)["selected"] == @preferred
    assert Policy.select(blocked(), nil, request, @now)["selected"] == @fallback

    for unsupported <- [
          Map.delete(request, "permissions"),
          Map.put(request, "sandbox", "read-only")
        ] do
      assert_raise RuntimeError, ~r/Selected claude/, fn ->
        Policy.select(configured(), nil, unsupported, @now)
      end
    end
  end

  test "materialized-folder is a Claude capability without sandbox or provisioning" do
    request = %{"permissions" => "materialized-folder"}
    assert Policy.select(configured(), nil, request, @now)["selected"] == @preferred
    assert Policy.select(blocked(), nil, request, @now)["selected"] == @fallback

    for unsupported <- [
          Map.put(request, "sandbox", "read-only"),
          Map.put(request, "repository", "https://github.com/eyra/atlas.git")
        ] do
      assert_raise RuntimeError, ~r/Selected claude/, fn ->
        Policy.select(configured(), nil, unsupported, @now)
      end
    end
  end

  test "invalid configuration refuses rather than selecting a different provider" do
    for target <- [
          %{"backend" => "unknown", "model" => nil},
          %{"backend" => "claude", "model" => ""},
          %{"backend" => "claude", "model" => "--unsafe"}
        ] do
      assert_raise RuntimeError, fn -> Policy.configure(Policy.empty(), target, @fallback) end
    end

    assert_raise RuntimeError, fn -> Policy.configure(Policy.empty(), @fallback, @preferred) end

    assert_raise RuntimeError, fn ->
      Policy.validate!(%{"claude_quota" => %{"evidence" => %{"message" => "quota"}}})
    end
  end
end

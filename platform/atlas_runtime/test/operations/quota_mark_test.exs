defmodule AtlasRuntime.Operations.QuotaMarkTest do
  # clear_quota_mark through the facade (design §13.1 Q7, O1 8): the mark leaves
  # availability.json, so the harness is available again, to the policy view and to the
  # work core; an unmarked known harness is cleared too; an unknown one is not found.
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness
  alias AtlasRuntime.{Availability, Policy}
  alias AtlasRuntime.Boundary.Operations, as: F
  alias AtlasRuntime.Boundary.Work, as: W
  alias AtlasRuntimeBoundary.Generator.NotPermitted

  @moduletag capture_log: true
  @operator {"local:test", [:inspect, :operate]}
  @claude %{"provider" => "anthropic", "harness" => "claude", "model" => "claude-opus-5-5"}
  @codex %{"provider" => "openai", "harness" => "codex", "model" => "gpt-6.1-sol"}

  setup do
    bench = start!()
    dir = bench.dir

    policy = %{
      "version" => 1,
      "profiles" => %{
        "deep_coding" => %{
          "permissions" => ["workspace-write"],
          "cost_classes" => ["high"],
          "options" => [@claude, @codex]
        }
      }
    }

    File.write!(Policy.path(dir), JSON.encode!(policy))
    %{bench: bench, tmp_dir: dir}
  end

  # A human's mark with no known return: out until cleared.
  defp mark(availability, harness) do
    put_in(availability, ["quota", harness], %{
      "evidence" => %{"source" => "operator", "note" => "no credits", "resetsAt" => nil},
      "turn_id" => nil,
      "observed_at" => 1_794_050_000,
      "reenabled_at" => nil
    })
  end

  defp availability_of(harness) do
    %{profiles: [%{options: options}]} = F.policy(@operator)
    Enum.find(options, &(&1.harness == harness)).availability
  end

  test "a marked harness: the mark is gone, and the view shows it available", %{tmp_dir: dir} do
    Availability.persist(dir, Availability.empty() |> mark("claude") |> mark("codex"))
    assert %{available: false, reason: :quota} = availability_of("claude")
    assert [%W.ProfileAvailability{available: false}] = W.capacity(client()).profiles

    assert %F.Outcome.Cleared{} = F.clear_quota_mark(@operator, %{"harness" => "claude"})

    on_disk = JSON.decode!(File.read!(Availability.path(dir)))
    refute Map.has_key?(on_disk["quota"], "claude")
    # Another harness's mark is kept.
    assert Map.has_key?(on_disk["quota"], "codex")
    refute File.exists?(Availability.path(dir) <> ".tmp")

    assert %{available: true} = availability_of("claude")
    assert %{available: false} = availability_of("codex")

    # The work core reads the same evidence: its profile, whose first option is Claude, is
    # available again.
    assert [%W.ProfileAvailability{profile: "deep_coding", available: true}] =
             W.capacity(client()).profiles
  end

  test "an unmarked known harness is cleared, and nothing is written", %{tmp_dir: dir} do
    assert %F.Outcome.Cleared{} = F.clear_quota_mark(@operator, %{"harness" => "codex"})
    refute File.exists?(Availability.path(dir))

    Availability.persist(dir, mark(Availability.empty(), "claude"))
    before = File.read!(Availability.path(dir))
    assert %F.Outcome.Cleared{} = F.clear_quota_mark(@operator, %{"harness" => "codex"})
    assert File.read!(Availability.path(dir)) == before
  end

  test "an unknown harness is not found, and nothing changes", %{tmp_dir: dir} do
    Availability.persist(dir, mark(Availability.empty(), "claude"))
    before = File.read!(Availability.path(dir))

    for harness <- ["gemini", "", "../claude"] do
      assert %F.Outcome.NotFound{} = F.clear_quota_mark(@operator, %{"harness" => harness})
    end

    assert File.read!(Availability.path(dir)) == before
  end

  test "operate is the right it needs, and the file is untouched without it", %{tmp_dir: dir} do
    Availability.persist(dir, mark(Availability.empty(), "claude"))

    assert %NotPermitted{capability: :clear_quota_mark, right: :operate} =
             F.clear_quota_mark({"remote:x", [:inspect]}, %{"harness" => "claude"})

    assert %{available: false} = availability_of("claude")
  end

  test "without the work core it raises: no outcome means not running", %{tmp_dir: dir} do
    Availability.persist(dir, mark(Availability.empty(), "claude"))
    stop_work()

    assert_raise AtlasRuntime.Operations.NotRunning, fn ->
      F.clear_quota_mark(@operator, %{"harness" => "claude"})
    end

    assert Map.has_key?(JSON.decode!(File.read!(Availability.path(dir)))["quota"], "claude")
  end
end

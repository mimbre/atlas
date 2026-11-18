defmodule AtlasRuntime.Work.SourceRightsTest do
  @moduledoc """
  M2 A1, fixed source rights (decision §3 "What the local policy bounds"; M2 plan C1): only
  the built-in `local` work source names something on this machine. From any other source
  each of the four forms (`repository`, `folder`, `slot`, `resume_from`) is refused
  `not_permitted` before anything is admitted: no work record, no preparer and no clone.
  From `local` the same four forms are accepted.
  """
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness

  alias AtlasRuntime.Boundary.Work, as: F
  alias AtlasRuntime.Sources.Rights

  @moduletag capture_log: true

  @remote Rights.client("flow-prod")
  @local Rights.client("local")
  @base %{kind: "base", base_id: "sha256:" <> String.duplicate("a", 64), permissions: "read-only"}

  # light_work also allows a repository here, so a refusal is the right's, not the policy's.
  @policy %{
    "profiles" => %{
      "light_work" => %{
        "permissions" => [
          "read-only",
          "workspace-write",
          "materialized-folder",
          "dedicated-repository"
        ],
        "cost_classes" => ["low", "standard"],
        "options" => [%{"provider" => "openai", "harness" => "codex", "model" => "gpt-test"}]
      }
    }
  }

  setup do
    test = self()
    bench = start!(@policy, prepare_hook: fn tag -> send(test, {:prepare_hook, tag}) end)
    %{bench: bench}
  end

  defp repository(bench, instructions),
    do:
      request(bench, instructions, %{
        workspace: %{
          kind: "repository",
          url: "https://example.invalid/r.git",
          branch: "task/x",
          base: "develop"
        }
      })

  defp work_files(bench) do
    case File.ls(Path.join(bench.dir, "work")) do
      # Committed records only: a write in flight has its `.json.tmp` beside them.
      {:ok, names} -> Enum.filter(names, &(&1 =~ ~r/\Awork-.*\.json\z/))
      {:error, :enoent} -> []
    end
  end

  # Nothing of a refused request exists: no record, no launch, no preparer.
  defp assert_nothing_admitted(bench) do
    assert work_files(bench) == []
    assert %F.Outcome.Works{works: []} = F.list_work(@remote, %{})
    assert launches(bench) == []
    refute_received {:prepare_hook, _}
  end

  test "the rights are fixed in code: local holds the socket's work rights, any other source three" do
    assert {"source:flow-prod", [:submit, :cancel, :read]} = @remote
    assert {"source:local", rights} = @local
    assert :choose_path in rights and :choose_slot in rights
    refute :choose_path in elem(Rights.client("other"), 1)
  end

  describe "from a non-local source" do
    test "repository: refused not_permitted, nothing admitted or cloned", %{bench: bench} do
      assert %F.Outcome.Refused{reason: :not_permitted} =
               F.submit(@remote, repository(bench, "complete repo"))

      assert_nothing_admitted(bench)
    end

    test "folder: refused not_permitted, nothing admitted or prepared", %{bench: bench} do
      assert %F.Outcome.Refused{reason: :not_permitted} =
               F.submit(@remote, request(bench, "complete folder"))

      assert_nothing_admitted(bench)
    end

    test "slot: refused not_permitted, nothing admitted", %{bench: bench} do
      # A base names no path, so only the slot is in question.
      assert %F.Outcome.Refused{reason: :not_permitted} =
               F.submit(@remote, request(bench, "complete slot", %{workspace: @base, slot: "s1"}))

      assert_nothing_admitted(bench)
    end

    test "resume_from: refused not_permitted, nothing admitted", %{bench: bench} do
      assert %F.Outcome.Refused{reason: :not_permitted} =
               F.submit(
                 @remote,
                 request(bench, "complete resume", %{
                   workspace: @base,
                   resume_from: "turn-0123456789abcdef"
                 })
               )

      assert_nothing_admitted(bench)
    end
  end

  describe "from local" do
    test "folder and slot are accepted", %{bench: bench} do
      assert %F.Outcome.Accepted{work: folder} =
               F.submit(@local, request(bench, "complete local"))

      assert await_state(folder.work_id, :completed, @local)

      assert %F.Outcome.Accepted{work: slot} =
               F.submit(@local, request(bench, "complete on s2", %{slot: "s2"}))

      assert [%{slot: "s2"}] = await_state(slot.work_id, :completed, @local).attempts
    end

    test "resume_from is accepted", %{bench: bench} do
      assert %F.Outcome.Accepted{work: first} = F.submit(@local, request(bench, "complete first"))
      [%{turn_id: turn}] = await_state(first.work_id, :completed, @local).attempts

      assert %F.Outcome.Accepted{} =
               F.submit(@local, request(bench, "complete first", %{resume_from: turn}))
    end

    test "repository is accepted", %{bench: bench} do
      assert %F.Outcome.Accepted{work: work} = F.submit(@local, repository(bench, "repo local"))
      # Added to the local source; its lease is the executor's record.
      await(fn -> match?([_record], work_files(bench)) end)
      F.cancel(@local, %{work_id: work.work_id})
    end
  end
end

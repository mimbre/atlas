defmodule AtlasFlow.WorkSource.TranslateTest do
  # Plan m3 §3.5, A2 acceptance 10: Flow's task ↔ the Runtime's work. The version-2 intent
  # and its offered_work (never a slot, folder, resume_from, repository or path: a property
  # over random intents), reports → task fields and attempt values, and the task fact → the
  # run's result. Pure; asserted on structure and values.
  use ExUnit.Case, async: true

  alias AtlasFlow.FakeFacts.Leasing, as: L
  alias AtlasFlow.WorkSource.Translate

  @contract_fields [:work_key, :title, :instructions, :profile, :cost_class, :input, :after_check]
  @forbidden ~w(slot folder resume_from repository workspace branch url path)

  defp spec(seed) do
    :rand.seed(:exsss, {seed, seed * 7, seed * 13})
    pick = &Enum.random/1

    %{
      "kind" => pick.(~w(plan author review fix)),
      "role" => "developer",
      "profile" => pick.(~w(deep_coding independent_review)),
      "cost_class" => pick.(~w(low standard high)),
      "instructions" => "Do part #{seed}.",
      "fields" => pick.([[], ["step"]]),
      "check" => pick.([nil, ["mix", "test"]]),
      "input" => %{"repository" => "/home/someone/repo-#{seed}", "base" => "develop"},
      "machinery" => "robot",
      "slot" => "slot-#{seed}",
      "folder" => "/Users/someone/work"
    }
  end

  defp walk(term, fun) when is_map(term),
    do: Enum.each(term, fn {k, v} -> fun.(k) && walk(v, fun) end)

  defp walk(term, fun) when is_list(term), do: Enum.each(term, &walk(&1, fun))
  defp walk(term, fun), do: fun.(term)

  test "no offered work has a slot, folder, resume_from, repository or an absolute path" do
    for seed <- 1..200 do
      spec = spec(seed)
      subject = %{"key" => "B-#{seed}", "values" => %{"step" => "/var/tmp/somewhere"}}
      intent = Translate.intent(spec, subject, "TK-B-#{seed}-1", L.base(), "robot-1", L.epoch())
      assert Translate.intent?(intent)
      work = Translate.offered_work(intent)

      assert Map.keys(work) -- @contract_fields == []
      assert Map.keys(work.input) -- [:base, :change_set, :permissions] == []

      walk(work, fn
        key when is_atom(key) -> refute Atom.to_string(key) in @forbidden
        value when is_binary(value) -> refute String.starts_with?(value, "/")
        _ -> true
      end)
    end
  end

  test "the offered work's fields come from the intent" do
    intent = L.intent("TK-B-1-1", check: ["mix", "test"])
    work = Translate.offered_work(intent)

    assert %{
             work_key: "TK-B-1-1",
             profile: "deep_coding",
             cost_class: "standard",
             after_check: %{command: ["mix", "test"]},
             input: %{
               base: %{base_id: "code-" <> _, manifest: manifest},
               permissions: "workspace-write"
             }
           } = work

    assert manifest == L.base().manifest
    refute Map.has_key?(work.after_check, :timeout)
    refute Map.has_key?(Translate.offered_work(L.intent("TK-B-1-1")), :after_check)
  end

  describe "the after-check in a pulled work's folder (fix path a)" do
    # The Runtime runs the check in the composed folder, where a pulled base places the
    # repository at `<root>/` (AtlasFlow.Bases.root_of/1).
    defp command(check, repository),
      do:
        L.intent("TK-B-1-1", check: check)
        |> Translate.root_check(repository)
        |> Translate.offered_work()
        |> Map.get(:after_check)

    test "a relative program path is placed in the repository's root" do
      assert AtlasFlow.Bases.root_of("github.com/mimbre/atlas") == "atlas"

      assert command(["bin/check"], "github.com/mimbre/atlas") ==
               %{command: ["atlas/bin/check"]}

      assert command(["bin/check", "--fast"], "github.com/mimbre/atlas") ==
               %{command: ["atlas/bin/check", "--fast"]}
    end

    test "a bare name, an absolute path, no check or no repository is kept" do
      assert command(["mix", "test"], "github.com/mimbre/atlas") == %{command: ["mix", "test"]}

      assert command(["/usr/bin/true"], "github.com/mimbre/atlas") == %{
               command: ["/usr/bin/true"]
             }

      assert command(nil, "github.com/mimbre/atlas") == nil
      assert command(["bin/check"], nil) == %{command: ["bin/check"]}
    end
  end

  describe "the stored result manifest (fix path b)" do
    defp reported(opts \\ []),
      do: Translate.normal(L.ended(L.change_set([{"a.txt", "a\n"}], "sha256:b", opts)))

    test "is the plain change set: valid as an input manifest, its fingerprints beside it" do
      ended = reported()
      manifest = Translate.manifest(ended)
      fingerprints = Translate.ended_values(ended)["result_fingerprints"]

      assert Enum.all?(manifest["roots"], &(Map.keys(&1) |> Enum.sort() == ~w(entries root)))
      assert AtlasChangeset.validate(manifest) == :ok
      assert Translate.fingerprints_hold?(manifest, fingerprints)
      assert Translate.fingerprints_hold?(manifest, JSON.decode!(fingerprints))
    end

    test "fingerprints that do not recompute, or none, do not hold" do
      bad = reported(fingerprint: "csf_" <> String.duplicate("0", 64))
      manifest = Translate.manifest(bad)

      refute Translate.fingerprints_hold?(
               manifest,
               Translate.ended_values(bad)["result_fingerprints"]
             )

      refute Translate.fingerprints_hold?(Translate.manifest(reported()), nil)
      refute Translate.fingerprints_hold?(Translate.manifest(reported()), [])
      refute Translate.fingerprints_hold?(Translate.manifest(reported()), "not json")
    end
  end

  test "a review reads only; the other kinds may write" do
    assert Translate.permissions("review") == "read-only"
    for kind <- ~w(plan author fix), do: assert(Translate.permissions(kind) == "workspace-write")
  end

  test "only a version-2 intent with a base is one Dispatch offers" do
    assert Translate.intent?(L.intent("TK-B-1-1"))
    refute Translate.intent?(%{"version" => 1, "key" => "TK-B-1-1", "request" => %{}})
    refute Translate.intent?(put_in(L.intent("TK-B-1-1"), ["work", "input", "base"], %{}))
  end

  test "the lease input the task fact keeps names the base manifest" do
    intent = L.intent("TK-B-1-1")
    assert Translate.input_manifest(Translate.lease_input(intent)) == L.base().manifest
    assert Translate.input_manifest(nil) == nil
  end

  describe "ended → the task fact's result fields" do
    defp values(opts), do: Translate.ended_values(Translate.normal(L.ended(nil, opts)))

    defp check(overrides),
      do:
        Map.merge(
          %{command: ["mix", "test"], timed_out: false, duration_ms: 5, output_tail: "tail"},
          overrides
        )

    test "the check's ending" do
      assert values(check: check(%{exit_status: 0}))["check_ending"] == nil
      assert values(check: check(%{exit_status: 0}))["check_exit_status"] == 0
      assert values(check: check(%{timed_out: true}))["check_ending"] == "timed_out"
      assert values(check: check(%{error: :not_found}))["check_ending"] == "error: not_found"
      assert values(check: check(%{signal: "KILL"}))["check_ending"] == "signal: KILL"
      assert values(check: check(%{}))["check_ending"] == "no_exit_status"
      assert values(check: check(%{exit_status: 1}))["check_output_tail"] == "tail"
    end

    test "the answer is cut at 8 KB, on a character boundary" do
      long = String.duplicate("é", 5000)
      answer = values(answer: long)["answer"]
      assert byte_size(answer) <= 8192
      assert String.valid?(answer)
    end

    test "fingerprints are the roots' csf_; with no change set none, and every field is given" do
      v = Translate.ended_values(Translate.normal(L.ended(L.change_set([{"a", "a"}], "b"))))

      assert [%{"root" => "repo", "fingerprint" => "csf_" <> _}] =
               JSON.decode!(v["result_fingerprints"])

      v = values([])
      assert Map.has_key?(v, "result_fingerprints") and v["result_fingerprints"] == nil
      assert v["result_kind"] == "completed"
    end
  end

  describe "the result-less endings (Q8)" do
    defp ending(kind, reason), do: Translate.normal(L.ended(nil, kind: kind, reason: reason))

    test "returned, a Runtime stop, and a cancel Flow asked for bring no result" do
      assert Translate.result_less(ending(:returned, nil), nil) == "returned"
      assert Translate.result_less(ending(:interrupted, :runtime_stop), nil) == "runtime_stop"
      assert Translate.result_less(ending(:cancelled, :cancel), "supervision") == "supervision"
    end

    test "every other ending is a result" do
      assert Translate.result_less(ending(:cancelled, :cancel), nil) == nil
      assert Translate.result_less(ending(:interrupted, :quota), nil) == nil
      assert Translate.result_less(ending(:failed, nil), nil) == nil
    end
  end

  describe "the task fact → the run's result" do
    defp fact(values), do: %{"values" => values}

    test "completed with a check that exited 0 and no ending; check_failed otherwise" do
      done = %{
        "lease_state" => "done",
        "result_kind" => "completed",
        "result_state" => "complete"
      }

      assert {:result, "completed", _} =
               Translate.outcome(fact(Map.merge(done, %{"check_exit_status" => 0})), true)

      assert {:result, "check_failed", _} =
               Translate.outcome(fact(Map.merge(done, %{"check_exit_status" => 1})), true)

      assert {:result, "check_failed", _} =
               Translate.outcome(fact(Map.merge(done, %{"check_ending" => "timed_out"})), true)

      assert {:result, "check_failed", _} = Translate.outcome(fact(done), true)
      assert {:result, "completed", _} = Translate.outcome(fact(done), false)

      assert {:result, "completed", _} =
               Translate.outcome(fact(Map.delete(done, "result_state")), false)
    end

    test "refused, too large, invalid and other kinds are stuck, each with its reason" do
      assert {:result, "stuck", %{"reason" => "refused: invalid"}} =
               Translate.outcome(
                 fact(%{
                   "lease_state" => "done",
                   "result_kind" => "refused",
                   "reason" => "invalid"
                 }),
                 false
               )

      for state <- ~w(too_large invalid) do
        assert {:result, "stuck", %{"reason" => ^state}} =
                 Translate.outcome(
                   fact(%{
                     "lease_state" => "done",
                     "result_kind" => "completed",
                     "result_state" => state
                   }),
                   false
                 )
      end

      assert {:result, "stuck", %{"reason" => "failed"}} =
               Translate.outcome(
                 fact(%{"lease_state" => "done", "result_kind" => "failed"}),
                 false
               )
    end

    test "no result yet, or one still incomplete, waits; a result-less ending retries" do
      assert :waiting = Translate.outcome(nil, false)
      assert :waiting = Translate.outcome(fact(%{"lease_state" => "started"}), false)

      assert :waiting =
               Translate.outcome(
                 fact(%{
                   "lease_state" => "done",
                   "result_kind" => "completed",
                   "result_state" => "incomplete"
                 }),
                 false
               )

      # The three result-less endings of §3.5, as Delivery writes them.
      for {kind, reason, cause} <- [
            {"returned", nil, "returned"},
            {"interrupted", "runtime_stop", "runtime_stop"},
            {"cancelled", "cancel", "supervision"}
          ] do
        values = %{
          "lease_state" => "done",
          "result_kind" => kind,
          "reason" => reason,
          "lease_end_cause" => cause
        }

        assert :retry = Translate.outcome(fact(values), false)
        assert Translate.no_result?(values)
      end
    end

    # B1: result-less is decided from the ending, not from the cancel request.
    test "an ending with a result after a supervision cancel request keeps its result" do
      requested = %{"lease_state" => "done", "lease_end_cause" => "supervision"}

      completed = Map.put(requested, "result_kind", "completed")
      refute Translate.no_result?(completed)
      assert {:result, "completed", _} = Translate.outcome(fact(completed), false)

      for kind <- ~w(failed interrupted) do
        values = Map.put(requested, "result_kind", kind)
        refute Translate.no_result?(values)
        assert {:result, "stuck", %{"kind" => ^kind}} = Translate.outcome(fact(values), false)
      end

      # A cancelled with no cancel request from Flow is a result (stuck), not a retry.
      cancelled = %{"lease_state" => "done", "result_kind" => "cancelled"}
      refute Translate.no_result?(cancelled)
      assert {:result, "stuck", _} = Translate.outcome(fact(cancelled), false)
    end
  end

  test "the attempt values carry no selection reason" do
    values = Translate.attempt_values(Translate.normal(L.ended(nil)))
    refute Map.has_key?(values, "selection_reason")
    assert values["turn_id"] == "turn-1"
  end
end

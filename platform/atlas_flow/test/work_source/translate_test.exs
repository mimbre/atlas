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
      assert Map.keys(work.input) -- [:base, :permissions] == []

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

  test "a review reads only; the other kinds may write" do
    assert Translate.permissions("review") == "read-only"
    for kind <- ~w(plan author fix), do: assert(Translate.permissions(kind) == "workspace-write")
  end

  # IS-Atlas-20, IS-Atlas-19: a subject's review on its latest result reads a Git checkout
  # of it without a result push; its fix on that result still pushes its own.
  test "a review on a result asks for a checkout and no result ref; a fix pushes its result" do
    on_result = fn kind ->
      spec = %{
        spec(1)
        | "kind" => kind,
          "input" => %{"repository" => "github.com/mimbre/atlas", "result" => "latest"}
      }

      spec
      |> Translate.intent(%{"key" => "IS-1"}, "TK-IS-1-2", L.base(), "robot-1", L.epoch())
      |> Translate.result_ref("TK-IS-1-2")
    end

    review = on_result.("review")
    assert Translate.intent?(review)
    assert %{"permissions" => "read-only", "checkout" => true} = review["work"]["input"]
    refute Map.has_key?(review["work"]["input"], "result_ref")
    assert %{permissions: "read-only", checkout: true} = Translate.offered_work(review).input
    refute Map.has_key?(Translate.offered_work(review).input, :result_ref)
    assert Translate.input_result_ref(Translate.lease_input(review)) == nil

    fix = on_result.("fix")
    assert fix["work"]["input"]["permissions"] == "workspace-write"
    assert fix["work"]["input"]["result_ref"] == "refs/atlas/results/TK-IS-1-2"
    refute Map.has_key?(fix["work"]["input"], "checkout")
    refute Map.has_key?(Translate.offered_work(fix).input, :checkout)

    # A review on a base (no result) is read-only as before, without a checkout.
    spec = %{spec(1) | "kind" => "review"}
    plain = Translate.intent(spec, %{"key" => "B-1"}, "TK-B-1-1", L.base(), "r", L.epoch())
    refute Map.has_key?(plain["work"]["input"], "checkout")
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

    test "every field is given; a change set an older Runtime reports is not read (IS-Atlas-100)" do
      v = values([])
      assert Map.has_key?(v, "answer") and v["answer"] == nil
      assert v["result_kind"] == "completed"

      with_change_set =
        Translate.ended_values(Translate.normal(L.ended(L.change_set([{"a", "a"}], "b"))))

      assert with_change_set == v
    end
  end

  describe "the result-less endings (Q8, D-0102)" do
    defp ending(kind, reason, opts \\ []),
      do: Translate.normal(L.ended(nil, [kind: kind, reason: reason] ++ opts))

    test "returned, any interruption, a check cut short, and a cancel Flow asked for bring no result" do
      assert Translate.result_less(ending(:returned, nil), nil) == "returned"
      assert Translate.result_less(ending(:interrupted, :runtime_stop), nil) == "interrupted"
      assert Translate.result_less(ending(:interrupted, nil), nil) == "interrupted"
      assert Translate.result_less(ending(:interrupted, :quota), nil) == "interrupted"

      assert Translate.result_less(ending(:completed, nil, check: check(%{})), nil) ==
               "check_interrupted"

      assert Translate.result_less(ending(:cancelled, :cancel), "supervision") == "supervision"
      assert Translate.result_less(ending(:cancelled, :cancel), "restart") == "restart"
    end

    test "every other ending is a result" do
      assert Translate.result_less(ending(:cancelled, :cancel), nil) == nil
      assert Translate.result_less(ending(:failed, nil), nil) == nil
      assert Translate.result_less(ending(:completed, nil), nil) == nil

      for check <- [%{exit_status: 1}, %{timed_out: true}, %{signal: "KILL"}] do
        assert Translate.result_less(ending(:completed, nil, check: check(check)), nil) == nil
      end
    end
  end

  describe "the task fact → the run's result" do
    defp fact(values), do: %{"values" => values}

    test "completed with a check that exited 0 and no ending; check_failed otherwise" do
      done = %{"lease_state" => "done", "result_kind" => "completed"}

      assert {:result, "completed", _} =
               Translate.outcome(fact(Map.merge(done, %{"check_exit_status" => 0})), true)

      assert {:result, "check_failed", _} =
               Translate.outcome(fact(Map.merge(done, %{"check_exit_status" => 1})), true)

      assert {:result, "check_failed", _} =
               Translate.outcome(fact(Map.merge(done, %{"check_ending" => "timed_out"})), true)

      assert {:result, "check_failed", _} = Translate.outcome(fact(done), true)
      assert {:result, "completed", _} = Translate.outcome(fact(done), false)
    end

    test "refused and other kinds are stuck, each with its reason" do
      assert {:result, "stuck", %{"reason" => "refused: invalid"}} =
               Translate.outcome(
                 fact(%{
                   "lease_state" => "done",
                   "result_kind" => "refused",
                   "reason" => "invalid"
                 }),
                 false
               )

      assert {:result, "stuck", %{"reason" => "failed"}} =
               Translate.outcome(
                 fact(%{"lease_state" => "done", "result_kind" => "failed"}),
                 false
               )
    end

    test "no result yet waits; a result-less ending retries" do
      assert :waiting = Translate.outcome(nil, false)
      assert :waiting = Translate.outcome(fact(%{"lease_state" => "started"}), false)

      # The result-less endings of §3.5 and D-0102, as Delivery writes them.
      for {kind, reason, check_ending, cause} <- [
            {"returned", nil, nil, "returned"},
            {"interrupted", "runtime_stop", nil, "interrupted"},
            {"interrupted", nil, nil, "interrupted"},
            {"completed", nil, "no_exit_status", "check_interrupted"},
            {"cancelled", "cancel", nil, "supervision"},
            {"cancelled", "cancel", nil, "restart"}
          ] do
        values = %{
          "lease_state" => "done",
          "result_kind" => kind,
          "reason" => reason,
          "check_ending" => check_ending,
          "lease_end_cause" => cause
        }

        assert :retry = Translate.outcome(fact(values), false)
        assert :retry = Translate.outcome(fact(values), true)
        assert Translate.no_result?(values)
      end
    end

    # D-0102: an update, a Runtime stop or crash, or a restart is retried from the same
    # step, as often as it happens: never stuck, never an empty turn.
    test "an interrupted ending without a cause on the fact retries, whatever its reason" do
      for reason <- [nil, "runtime_stop", "quota"] do
        values = %{
          "lease_state" => "done",
          "result_kind" => "interrupted",
          "reason" => reason,
          "attempt" => 3
        }

        assert Translate.no_result?(values)
        assert Translate.empty(values) == nil
        assert :retry = Translate.outcome(fact(values), false)
      end
    end

    # UC-Atlas-03: a silent turn is ended. Its run decides whether it is started again.
    test "a lease lost at expiry, or a crash with no answer and no result, is an empty turn" do
      silent = %{"lease_state" => "lost", "lease_end_cause" => "expired", "attempt" => 2}
      assert Translate.empty(silent) == "silent"
      assert {:empty, "silent", 2} = Translate.outcome(fact(silent), true)

      # Lost for another cause (not accepted in time, the supervisor changed): offered again.
      for cause <- ~w(late_accept supervision answer) do
        lost = %{silent | "lease_end_cause" => cause}
        assert Translate.empty(lost) == nil
        assert :waiting = Translate.outcome(fact(lost), true)
      end

      # Expired, within its grace: not yet.
      assert Translate.empty(%{silent | "lease_state" => "expired"}) == nil

      nothing = %{"lease_state" => "done", "result_kind" => "crashed", "attempt" => 1}
      assert Translate.empty(nothing) == "empty"
      assert {:empty, "empty", 1} = Translate.outcome(fact(nothing), false)

      # With an answer it said something: stuck, as before.
      said = Map.put(nothing, "answer", "I stopped because …")
      assert Translate.empty(said) == nil
      assert {:result, "stuck", _} = Translate.outcome(fact(said), false)

      # A failure names its cause; a completed end is a result.
      failed = %{"lease_state" => "done", "result_kind" => "failed", "reason" => "time_limit"}
      assert Translate.empty(failed) == nil
      completed = %{"lease_state" => "done", "result_kind" => "completed"}
      assert Translate.empty(completed) == nil
    end

    test "the attempts a run started again are the intent's retried numbers" do
      assert Translate.retried(nil) == []
      assert Translate.retried(%{"key" => "TK-B-1-1"}) == []
      assert Translate.retried(%{"retried" => [1, "x", 3]}) == [1, 3]
    end

    # B1: result-less is decided from the ending, not from the cancel request.
    test "an ending with a result after a supervision cancel request keeps its result" do
      requested = %{"lease_state" => "done", "lease_end_cause" => "supervision"}

      completed = Map.put(requested, "result_kind", "completed")
      refute Translate.no_result?(completed)
      assert {:result, "completed", _} = Translate.outcome(fact(completed), false)

      failed = Map.put(requested, "result_kind", "failed")
      refute Translate.no_result?(failed)
      assert {:result, "stuck", %{"kind" => "failed"}} = Translate.outcome(fact(failed), false)

      # Interrupted is no result by rule (D-0102), also after a cancel request: retried.
      interrupted = Map.merge(requested, %{"result_kind" => "interrupted", "attempt" => 1})
      assert Translate.no_result?(interrupted)
      assert :retry = Translate.outcome(fact(interrupted), false)

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

  test "the latest result is the latest task that ended with one, never a review" do
    t = &%{"key" => &1, "task_kind" => &2, "outcome" => &3}
    author = t.("TK-1", "author", "completed")
    review = t.("TK-2", "review", "completed")

    assert Translate.latest_result([]) == nil
    assert Translate.latest_result([author, review]) == "TK-1"
    assert Translate.latest_result([author, review, t.("TK-3", "fix", "check_failed")]) == "TK-3"

    # A fix that ended stuck or abandoned left no result: a retry starts from the author's.
    for outcome <- ~w(stuck abandoned cancelled) do
      assert Translate.latest_result([author, review, t.("TK-3", "fix", outcome)]) == "TK-1"
    end

    # A record of an answer names no task.
    assert Translate.latest_result([author, %{"outcome" => "held"}]) == "TK-1"
    assert Translate.latest_result([t.("TK-1", "author", "stuck")]) == nil
  end
end

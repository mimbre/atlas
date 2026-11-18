defmodule AtlasFlow.LadderTest do
  use ExUnit.Case, async: true

  alias AtlasFlow.Ladder

  @base_a %{"base_id" => "base-a", "manifest" => "man-a", "base_snapshot" => "snap-a"}
  @base_b %{"base_id" => "base-b", "manifest" => "man-b", "base_snapshot" => "snap-b"}
  @max ["deep_coding", "independent_review", "deep_coding_max"]
  @plain ["deep_coding", "independent_review"]

  defp key(n), do: "TK-PK-1-#{n}"

  defp authored(n, opts \\ []) do
    %{
      "key" => key(n),
      "kind" => Keyword.get(opts, :kind, "author"),
      "outcome" => Keyword.get(opts, :outcome, "completed"),
      "reason" => Keyword.get(opts, :reason),
      "base" => Keyword.get(opts, :base, @base_a),
      "result_state" => Keyword.get(opts, :state, "complete"),
      "result_manifest" => "rm-#{n}",
      "result_fingerprints" => "csf-#{n}",
      "turn_id" => "turn-#{n}",
      "reviewed" => Keyword.get(opts, :reviewed),
      "check" => Keyword.get(opts, :check)
    }
  end

  defp reviewed(n, of, verdict, opts \\ []) do
    findings =
      Keyword.get(opts, :findings, if(verdict == "changes_required", do: ["f1"], else: []))

    answer =
      case verdict do
        nil ->
          "no block here"

        v ->
          "notes\n```json\n" <>
            JSON.encode!(%{"verdict" => v, "findings" => findings}) <> "\n```\n"
      end

    %{
      "key" => key(n),
      "kind" => "review",
      "outcome" => Keyword.get(opts, :outcome, "completed"),
      "base" => @base_a,
      "based_on" => "csf-#{of}",
      "answer" => answer,
      "turn_id" => Keyword.get(opts, :turn, "review-turn-#{n}")
    }
  end

  defp diagnosed(n, of, answer, opts \\ []),
    do: %{
      "key" => key(n),
      "kind" => "diagnose",
      "outcome" => Keyword.get(opts, :outcome, "completed"),
      "reason" => Keyword.get(opts, :reason),
      "base" => @base_a,
      "reviewed" => key(of),
      "answer" => answer
    }

  defp diag(cause, extra \\ %{}),
    do:
      "Found it.\n```\n" <>
        JSON.encode!(Map.merge(%{"cause" => cause, "evidence" => "ev", "advice" => "adv"}, extra)) <>
        "\n```"

  defp opt(id),
    do: %{
      "id" => id,
      "text" => "t-#{id}",
      "details" => "d",
      "rule" => "rule-#{id}",
      "consequences" => "c"
    }

  defp decision(extra \\ %{}),
    do:
      Map.merge(
        %{
          "question" => "Which scope?",
          "rationale" => "r",
          "options" => [opt("narrow"), opt("wide")]
        },
        extra
      )

  # A ladder on `rung` with its budget spent (unless `extra` says otherwise).
  defp at(rung, extra \\ %{}),
    do: Map.merge(%{"rung" => rung, "fixes" => 2, "base" => @base_a}, extra)

  # Plays the tasks in order through `next/5`, each ending as given; the steps and the
  # last ladder.
  defp play(tasks, profiles \\ @plain, ladder \\ nil) do
    Enum.reduce(1..length(tasks), {[], ladder}, fn n, {steps, ladder} ->
      seen = Enum.take(tasks, n)
      {step, ladder} = Ladder.next(ladder, {:ended, key(n)}, seen, profiles)
      {steps ++ [step], ladder}
    end)
  end

  defp last_step(tasks, profiles \\ @plain), do: play(tasks, profiles) |> elem(0) |> List.last()

  # Rung (d)'s diagnosis phrased `decision`: the escalation.
  defp escalated(decision, profiles \\ @plain) do
    tasks = [authored(1), reviewed(2, 1, "changes_required")]

    {{:task, %{"step" => "diagnose"}}, d} =
      Ladder.next(at("c"), {:ended, key(2)}, tasks, profiles)

    tasks = tasks ++ [diagnosed(3, 1, diag("other", %{"decision" => decision}))]
    {Ladder.next(d, {:ended, key(3)}, tasks, profiles), tasks}
  end

  defp writes?(term) when is_map(term),
    do:
      Map.has_key?(term, "op") or Map.has_key?(term, "content") or term["kind"] == "decision" or
        Enum.any?(Map.values(term), &writes?/1)

  defp writes?(term) when is_list(term), do: Enum.any?(term, &writes?/1)
  defp writes?(term) when is_tuple(term), do: term |> Tuple.to_list() |> writes?()
  defp writes?(_), do: false

  describe "an author's end" do
    test "a complete result is reviewed read-only on the author's base and change set" do
      {:task, review} = last_step([authored(1)])

      assert {review["step"], review["kind"]} == {"review", "review"}
      assert review["profile"] == "independent_review"
      assert review["permissions"] == "read-only"
      assert review["base"] == @base_a
      assert review["change_set"] == %{"manifest" => "rm-1", "fingerprints" => "csf-1"}
      assert review["based_on"] == "csf-1"
      assert review["reviewed"] == key(1)
    end

    test "a failed check is fixed on the author's change set, with the check, writable" do
      {[{:task, fix}], ladder} = play([authored(1, outcome: "check_failed")])

      assert fix["kind"] == "fix"
      assert fix["permissions"] == "workspace-write"
      assert fix["check"] == true
      assert fix["base"] == @base_a
      assert fix["change_set"] == %{"manifest" => "rm-1", "fingerprints" => "csf-1"}
      assert ladder["fixes"] == 1
    end

    test "a failed check without a complete result is fixed on the latest result" do
      tasks = [
        authored(1),
        reviewed(2, 1, "changes_required"),
        authored(3, kind: "fix", outcome: "check_failed", state: "incomplete", reviewed: key(1))
      ]

      {:task, fix} = last_step(tasks)
      assert fix["change_set"] == %{"manifest" => "rm-1", "fingerprints" => "csf-1"}
      assert fix["reviewed"] == key(1)
    end

    test "a stuck author holds the package and asks the supervisor" do
      assert {:held, %{"reason" => "stuck", "task" => k, "question" => q}} =
               last_step([authored(1, outcome: "stuck")])

      assert k == key(1)
      assert {q["answers"], q["recommended"]} == {["fresh", "abandon"], "fresh"}
    end
  end

  describe "an abandoned task (Main's ruling 2)" do
    test "it is started once more, nothing else counted; abandoned again, held and the supervisor asked" do
      {[{:task, again}], ladder} = play([authored(1, outcome: "abandoned")])
      assert {again["step"], again["base"], again["change_set"]} == {"author", @base_a, nil}
      assert {ladder["fixes"], ladder["rereviews"], ladder["retries"]} == {0, %{}, 1}

      twice = [authored(1, outcome: "abandoned"), authored(2, outcome: "abandoned")]
      {[_, held], ladder} = play(twice)
      assert {:held, %{"reason" => "abandoned", "task" => k, "question" => q}} = held
      assert k == key(2)
      assert {q["answers"], q["recommended"]} == {["retry", "abandon"], "retry"}
      assert ladder["awaiting"]["on"] == "held"

      {[_, {:held, %{"question" => q_max}}], _} = play(twice, @max)
      assert q_max["answers"] == ["retry", "stronger", "abandon"]

      assert {{:task, retried}, l} = Ladder.next(ladder, {:answer, "retry"}, twice, @plain)
      assert {retried["step"], l["awaiting"]} == {"author", nil}

      thrice = twice ++ [authored(3, outcome: "abandoned")]

      assert {{:held, %{"reason" => "abandoned"}}, _} =
               Ladder.next(l, {:ended, key(3)}, thrice, @plain)
    end

    test "the retry bound counts in a row: any other end resets it" do
      tasks = [
        authored(1, outcome: "abandoned"),
        authored(2),
        reviewed(3, 2, "approved", outcome: "abandoned")
      ]

      {[_, _, step], ladder} = play(tasks)

      assert {:task, %{"step" => "review", "based_on" => "csf-2"}} = step
      assert ladder["retries"] == 1
    end

    test "an abandoned fix is started again on the same change set, with its findings" do
      tasks = [
        authored(1),
        reviewed(2, 1, "changes_required", findings: ["a"]),
        authored(3, kind: "fix", outcome: "abandoned", state: "incomplete", reviewed: key(1))
      ]

      {:task, fix} = last_step(tasks)
      assert {fix["step"], fix["reviewed"], fix["findings"]} == {"fix", key(1), ["a"]}
      assert fix["change_set"] == %{"manifest" => "rm-1", "fingerprints" => "csf-1"}
    end
  end

  describe "a review's end" do
    test "approved on the latest result → ready" do
      assert {:ready, %{"task" => t, "review" => r}} =
               last_step([authored(1), reviewed(2, 1, "approved")])

      assert {t, r} == {key(1), key(2)}
    end

    test "changes required → a fix of the reviewed change set, with the findings" do
      tasks = [authored(1), reviewed(2, 1, "changes_required", findings: ["a", "b"])]
      {:task, fix} = last_step(tasks)

      assert fix["kind"] == "fix"
      assert fix["change_set"] == %{"manifest" => "rm-1", "fingerprints" => "csf-1"}
      assert fix["reviewed"] == key(1)
      assert fix["findings"] == ["a", "b"]
      assert fix["permissions"] == "workspace-write"
    end

    test "the fixed result is reviewed next, on its own change set and the original base" do
      tasks = [
        authored(1),
        reviewed(2, 1, "changes_required"),
        authored(3, kind: "fix", reviewed: key(1), base: @base_b),
        reviewed(4, 3, "approved")
      ]

      {steps, _} = play(tasks)

      assert [{:task, %{"kind" => "review"}}, {:task, %{"kind" => "fix"}}, {:task, r}, ready] =
               steps

      assert {r["kind"], r["based_on"], r["base"]} == {"review", "csf-3", @base_a}
      assert {:ready, %{"task" => t}} = ready
      assert t == key(3)
    end

    test "a review that did not complete holds the package" do
      assert {:held, %{"reason" => "stuck"}} =
               last_step([authored(1), reviewed(2, 1, "approved", outcome: "stuck")])

      assert {:held, %{"reason" => "review_not_completed", "task" => k}} =
               last_step([authored(1), reviewed(2, 1, "approved", outcome: "interrupted")])

      assert k == key(2)
    end

    test "a superseded verdict: one review of the latest, nothing while it runs, then held" do
      fix = authored(2, kind: "fix", reviewed: key(1))
      old = reviewed(3, 1, "approved")

      assert {{:task, r}, l} = Ladder.next(nil, {:ended, key(3)}, [authored(1), fix, old], @plain)

      assert {r["kind"], r["based_on"], l["rereviews"]} ==
               {"review", "csf-2", %{"superseded" => 1}}

      running = Map.merge(reviewed(4, 2, nil), %{"outcome" => nil})

      assert {:none, _} =
               Ladder.next(nil, {:ended, key(3)}, [authored(1), fix, old, running], @plain)

      {steps, _} = play([authored(1), fix, old, reviewed(4, 1, "approved")])
      assert {:held, %{"reason" => "invalid_review:superseded"}} = List.last(steps)
    end

    test "R1: two invalid reviews of one reason hold the package with that reason, and no third review" do
      tasks = [authored(1), reviewed(2, 1, nil), reviewed(3, 1, nil)]
      {steps, ladder} = play(tasks)

      assert [{:task, %{"kind" => "review"}}, {:task, %{"kind" => "review"}}, held] = steps
      assert {:held, %{"reason" => "invalid_review:no_verdict", "task" => k}} = held
      assert k == key(3)
      assert ladder["rereviews"] == %{"no_verdict" => 1}
    end

    test "re-reviews are counted per reason" do
      tasks = [
        authored(1),
        reviewed(2, 1, nil),
        reviewed(3, 1, "approved", turn: "turn-1"),
        reviewed(4, 1, nil)
      ]

      {steps, ladder} = play(tasks)

      assert [_, {:task, %{"kind" => "review"}}, {:task, %{"kind" => "review"}}, held] = steps
      assert {:held, %{"reason" => "invalid_review:no_verdict"}} = held
      assert ladder["rereviews"] == %{"no_verdict" => 1, "author_turn" => 1}
    end

    test "re-reviews count in a row: a valid verdict and a new result reset them" do
      tasks = [
        authored(1),
        reviewed(2, 1, nil),
        reviewed(3, 1, "changes_required"),
        authored(4, kind: "fix", reviewed: key(1)),
        reviewed(5, 4, nil)
      ]

      {steps, ladder} = play(tasks)
      assert {:task, %{"kind" => "review", "based_on" => "csf-4"}} = List.last(steps)
      assert ladder["rereviews"] == %{"no_verdict" => 1}
    end

    test "changes required without a finding, or in an author's turn, is an invalid review" do
      no_findings = [authored(1), reviewed(2, 1, "changes_required", findings: [])]
      {_, l1} = play(no_findings)
      assert l1["rereviews"] == %{"no_findings" => 1}

      same_turn = [authored(1), reviewed(2, 1, "approved", turn: "turn-1")]
      {[_, step], l2} = play(same_turn)
      assert {:task, %{"kind" => "review"}} = step
      assert l2["rereviews"] == %{"author_turn" => 1}
    end
  end

  describe "the rungs" do
    # An author, then `n` rounds of changes required → fix.
    defp rounds(n) do
      Enum.flat_map(0..(n - 1), fn i ->
        reviewed_n = 1 + 2 * i
        fixed = if i == 0, do: authored(1), else: authored(reviewed_n, kind: "fix", base: @base_b)
        [fixed, reviewed(reviewed_n + 1, reviewed_n, "changes_required")]
      end)
    end

    test "the budget is two fix tasks; then rung (a) diagnoses the latest result read-only" do
      {steps, ladder} = play(rounds(3))
      review_ends = steps |> Enum.drop(1) |> Enum.take_every(2)

      assert Enum.map(review_ends, fn {:task, t} -> t["step"] end) == ["fix", "fix", "diagnose"]

      {:task, diagnose} = List.last(review_ends)
      assert diagnose["permissions"] == "read-only"
      assert diagnose["role"] == "investigator"
      assert diagnose["change_set"] == %{"manifest" => "rm-5", "fingerprints" => "csf-5"}
      assert {ladder["rung"], ladder["fixes"], diagnose["rung"]} == {"a", 0, "a"}
      assert Ladder.budget() == 2
    end

    test "rung (b): a fresh author on the original base, with no change set and the diagnosis" do
      tasks = rounds(3) ++ [diagnosed(7, 5, diag("wrong_assumption"))]
      {:task, fresh} = last_step(tasks)

      assert {fresh["step"], fresh["kind"], fresh["rung"]} == {"fresh", "author", "b"}
      assert fresh["base"] == @base_a
      assert fresh["change_set"] == nil
      assert fresh["permissions"] == "workspace-write"
      assert fresh["profile"] == "deep_coding"
      assert fresh["diagnosis"]["cause"] == "wrong_assumption"

      shuffled = Enum.reverse(tasks)
      assert {{:task, ^fresh}, _} = Ladder.next(at("a"), {:ended, key(7)}, shuffled, @plain)
    end

    test "the diagnosis routes the ladder" do
      tasks = fn answer ->
        [authored(1), reviewed(2, 1, "changes_required"), diagnosed(3, 1, answer)]
      end

      route = fn answer ->
        Ladder.next(at("a", %{"fixes" => 0}), {:ended, key(3)}, tasks.(answer), @plain)
      end

      assert {{:task, %{"step" => "diagnose", "rung" => "d", "permissions" => "read-only"}}, _} =
               route.(diag("unclear_spec"))

      assert {{:held, %{"reason" => "native_check"}}, _} =
               route.(diag("environment", %{"needs" => "native_check"}))

      assert {{:escalate, %{"reason" => "access"}}, %{"rung" => "e"}} =
               route.(diag("environment", %{"needs" => "access", "decision" => decision()}))

      assert {{:held, %{"reason" => "access_no_decision"}}, _} =
               route.(diag("environment", %{"needs" => "access"}))

      assert {{:task, %{"step" => "fresh", "rung" => "b"}}, _} = route.(diag("other"))

      assert {{:task, %{"step" => "fresh", "diagnosis" => %{"cause" => "other"}}}, _} =
               route.("unparseable")
    end

    test "a flaky test gets one fix that stabilises it, then the ladder climbs" do
      tasks = [
        authored(1),
        reviewed(2, 1, "changes_required"),
        diagnosed(3, 1, diag("flaky_test"))
      ]

      {{:task, fix}, l} = Ladder.next(at("a", %{"fixes" => 0}), {:ended, key(3)}, tasks, @plain)

      assert {fix["step"], fix["flaky"], fix["change_set"]["manifest"]} == {"fix", true, "rm-1"}
      assert l["fixes"] == 1

      tasks =
        tasks ++ [authored(4, kind: "fix", reviewed: key(1)), reviewed(5, 4, "changes_required")]

      assert {{:task, %{"step" => "fresh", "flaky" => false}}, l2} =
               Ladder.next(l, {:ended, key(5)}, tasks, @plain)

      assert {l2["rung"], Map.has_key?(l2, "flaky")} == {"b", false}
    end

    test "rung (c) is a stronger author when offered; without it, rung (d)" do
      tasks = [authored(1), reviewed(2, 1, "changes_required")]

      assert {{:task, stronger}, l} = Ladder.next(at("b"), {:ended, key(2)}, tasks, @max)

      assert {stronger["step"], stronger["profile"], stronger["cost_class"]} ==
               {"stronger", "deep_coding_max", "high"}

      assert {stronger["base"], stronger["change_set"], l["fixes"], l["rung"]} ==
               {@base_a, nil, 0, "c"}

      assert {{:task, %{"step" => "diagnose"}}, %{"rung" => "d"}} =
               Ladder.next(at("b"), {:ended, key(2)}, tasks, @plain)
    end

    test "rung (d) diagnoses the scope choice; no decision phrased holds; after (e) nothing is left" do
      tasks = [authored(1), reviewed(2, 1, "changes_required")]
      assert {{:task, d}, l} = Ladder.next(at("c"), {:ended, key(2)}, tasks, @max)

      assert {d["step"], d["permissions"], d["change_set"]["manifest"], l["rung"]} ==
               {"diagnose", "read-only", "rm-1", "d"}

      no_decision = tasks ++ [diagnosed(3, 1, diag("other"))]

      assert {{:held, %{"reason" => "no_decision"}}, _} =
               Ladder.next(l, {:ended, key(3)}, no_decision, @max)

      assert {{:held, %{"reason" => "no_rung_left"}}, _} =
               Ladder.next(at("e"), {:ended, key(2)}, tasks, @max)
    end

    test "a policy refusal of the rung's own task skips the rung; any other refusal holds" do
      refused = fn kind ->
        authored(2, kind: kind, outcome: "stuck", reason: "refused: policy_forbids")
      end

      ladder_b = at("b", %{"fixes" => 0})

      assert {{:task, %{"step" => "stronger"}}, %{"rung" => "c"}} =
               Ladder.next(ladder_b, {:ended, key(2)}, [authored(1), refused.("author")], @max)

      assert {{:task, %{"step" => "diagnose"}}, %{"rung" => "d"}} =
               Ladder.next(ladder_b, {:ended, key(2)}, [authored(1), refused.("author")], @plain)

      no_option = diagnosed(2, 1, nil, outcome: "stuck", reason: "refused: no_permitted_option")

      assert {{:task, %{"step" => "fresh"}}, %{"rung" => "b"}} =
               Ladder.next(
                 at("a", %{"fixes" => 0}),
                 {:ended, key(2)},
                 [authored(1), no_option],
                 @plain
               )

      assert {{:held, %{"reason" => "stuck"}}, _} =
               Ladder.next(ladder_b, {:ended, key(2)}, [authored(1), refused.("fix")], @max)

      assert {:held, %{"reason" => "stuck"}} =
               last_step([
                 Map.merge(authored(1), %{
                   "outcome" => "stuck",
                   "reason" => "refused: policy_forbids"
                 })
               ])
    end
  end

  describe "rung (e) (plan §3.3, Main's ruling 1)" do
    test "it escalates with the worded options first, next to the fixed answers, and no write" do
      {result, _} = escalated(decision())

      assert {{:escalate, q}, ladder} = result
      assert Enum.map(q["options"], & &1["id"]) == ["narrow", "wide"]
      assert q["answers"] == ["narrow", "wide", "fresh", "abandon"]
      assert q["recommended"] == "narrow"
      assert {q["latest"], q["rung"], q["continue"]} == {key(1), "e", nil}
      assert {ladder["rung"], ladder["awaiting"]["on"]} == {"e", "escalation"}
      refute writes?(result)

      {{{:escalate, q_max}, _}, _} = escalated(decision(), @max)
      assert q_max["answers"] == ["narrow", "wide", "fresh", "stronger", "abandon"]
    end

    test "work continues on the recommended option only when it is safe and touches no authority" do
      {{{:escalate, q}, ladder}, tasks} = escalated(decision(%{"safe_to_continue" => true}))
      go = q["continue"]

      assert {go["step"], go["base"], go["change_set"], go["choice"]["id"]} ==
               {"fresh", @base_a, nil, "narrow"}

      assert ladder["choice"]["id"] == "narrow"

      assert Enum.any?(
               Ladder.sections("author", ladder, tasks),
               &String.contains?(&1, "rule-narrow")
             )

      for unsafe <- [%{"touches" => ["credentials"]}, %{"authority" => true}, %{}] do
        {{{:escalate, q}, _}, _} =
          escalated(decision(Map.put(unsafe, "safe_to_continue", unsafe != %{})))

        assert q["continue"] == nil
      end
    end

    test "R1: no work goes on when the recommended option was left out, though the next is recommended" do
      no_rule = Map.delete(opt("narrow"), "rule")

      for first <- [opt("fresh"), no_rule] do
        {{{:escalate, q}, ladder}, _} =
          escalated(decision(%{"options" => [first, opt("risky")], "safe_to_continue" => true}))

        assert {q["recommended"], q["safe_to_continue"]} == {"risky", false}
        assert {q["continue"], ladder["choice"]} == {nil, nil}
      end
    end

    test "R2: when the work on the default fails while the escalation waits, its options stay on offer" do
      {{{:escalate, q}, ladder}, tasks} = escalated(decision(%{"safe_to_continue" => true}))
      assert %{"step" => "fresh"} = q["continue"]

      stuck = tasks ++ [authored(4, outcome: "stuck")]
      assert {{:held, held}, l} = Ladder.next(ladder, {:ended, key(4)}, stuck, @plain)
      assert held["question"]["answers"] == ["narrow", "wide", "fresh", "abandon"]
      assert held["question"]["options"] == q["options"]
      assert {{:task, wide}, _} = Ladder.next(l, {:answer, "wide"}, stuck, @plain)
      assert {wide["step"], wide["choice"]["id"]} == {"fresh", "wide"}

      # Each of `ends` ends in turn after the escalation: the last step and ladder.
      after_escalation = fn ends ->
        Enum.reduce(ends, {nil, ladder, tasks}, fn task, {_, l, ts} ->
          ts = ts ++ [task]
          {step, l} = Ladder.next(l, {:ended, task["key"]}, ts, @plain)
          {step, l, ts}
        end)
      end

      {{:held, spent}, l, ts} =
        after_escalation.([
          authored(4, outcome: "check_failed"),
          authored(5, kind: "fix", outcome: "check_failed"),
          authored(6, kind: "fix", outcome: "check_failed")
        ])

      assert spent["reason"] == "no_rung_left"
      assert spent["question"]["answers"] == ["narrow", "wide", "fresh", "abandon"]

      assert {{:task, %{"choice" => %{"id" => "wide"}}}, _} =
               Ladder.next(l, {:answer, "wide"}, ts, @plain)

      {{:held, abandoned}, _, _} =
        after_escalation.([authored(4, outcome: "abandoned"), authored(5, outcome: "abandoned")])

      assert abandoned["question"]["answers"] == ["retry", "narrow", "wide", "abandon"]
    end

    test "an answer applies only while the ladder waits, and only one the question offers" do
      {{{:escalate, q}, ladder}, tasks} = escalated(decision())

      assert {:none, _} = Ladder.next(at("b"), {:answer, "fresh"}, tasks, @plain)

      assert {{:escalate, ^q}, ^ladder} =
               Ladder.next(ladder, {:answer, "stronger"}, tasks, @plain)

      assert {{:escalate, ^q}, ^ladder} =
               Ladder.next(ladder, {:answer, "nonsense"}, tasks, @plain)

      assert {{:task, fresh}, l} = Ladder.next(ladder, {:answer, "fresh"}, tasks, @plain)
      assert {fresh["step"], fresh["base"], fresh["choice"]} == {"fresh", @base_a, nil}
      assert {l["rung"], l["fixes"], l["rereviews"], l["awaiting"]} == {"e", 0, %{}, nil}
      assert {:none, _} = Ladder.next(l, {:answer, "fresh"}, tasks, @plain)

      assert {{:task, wide}, _} = Ladder.next(ladder, {:answer, "wide"}, tasks, @plain)
      assert {wide["step"], wide["choice"]["id"]} == {"fresh", "wide"}

      assert {:none, %{"awaiting" => nil}} =
               Ladder.next(ladder, {:answer, "abandon"}, tasks, @plain)

      {{{:escalate, _}, max_ladder}, _} = escalated(decision(), @max)

      assert {{:task, %{"step" => "stronger", "profile" => "deep_coding_max"}}, _} =
               Ladder.next(max_ladder, {:answer, "stronger"}, tasks, @max)
    end

    test "a held package takes the fixed answers" do
      {_, held} = play([authored(1, outcome: "stuck")])

      assert {{:task, %{"step" => "fresh"}}, %{"awaiting" => nil}} =
               Ladder.next(held, {:answer, "fresh"}, [authored(1, outcome: "stuck")], @plain)
    end
  end

  describe "reading tasks" do
    test "the latest result needs a complete stored result with a manifest" do
      incomplete = Map.put(authored(3, kind: "fix"), "result_state", "incomplete")
      no_manifest = Map.put(authored(4, kind: "fix"), "result_manifest", nil)
      assert Ladder.latest([no_manifest, authored(1), incomplete])["key"] == key(1)
      assert Ladder.latest([reviewed(2, 1, "approved")]) == nil
    end

    test "the original base is the first author's, as {base_id, manifest, base_snapshot}" do
      later = authored(5, base: @base_b)
      assert Ladder.original_base([later, authored(2)]) == @base_a

      assert Ladder.authors([authored(1), reviewed(2, 1, "approved"), later]) == [
               "turn-1",
               "turn-5"
             ]
    end
  end

  describe "parsing answers" do
    test "the verdict is the JSON object the answer ends with, fenced or bare" do
      two =
        "```json\n{\"verdict\":\"approved\"}\n```\nthen\n```json\n{\"verdict\":\"changes_required\",\"findings\":[\"z\"]}\n```"

      assert Ladder.verdict(two) == {:ok, "changes_required", ["z"]}
      assert Ladder.verdict("ok\n```\n{\"verdict\":\"approved\"}\n```") == {:ok, "approved", []}

      assert Ladder.verdict("ok {\"verdict\":\"approved\",\"findings\":[]}") ==
               {:ok, "approved", []}

      assert Ladder.verdict("```json\n{\"verdict\":\"approved\"}\n```\n```json\n{not json\n```") ==
               :error

      assert Ladder.verdict("```json\n{\"verdict\":\"approved\"}\n```\nmore text") == :error
      assert Ladder.verdict("```json\n{\"verdict\":\"maybe\"}\n```") == :error
      assert Ladder.verdict("{\"verdict\":\"changes_required\",\"findings\":\"one\"}") == :error
      assert Ladder.verdict("no block") == :error
      assert Ladder.verdict(nil) == :error
    end

    test "findings are capped at 20 texts of 300 characters; others are JSON-encoded" do
      long = String.duplicate("é", 400)
      findings = List.duplicate(long, 25)

      answer =
        "```json\n" <>
          JSON.encode!(%{"verdict" => "changes_required", "findings" => findings}) <> "\n```"

      {:ok, "changes_required", kept} = Ladder.verdict(answer)
      assert length(kept) == 20
      assert Enum.all?(kept, &(String.length(&1) == 300))

      objects =
        JSON.encode!(%{"verdict" => "changes_required", "findings" => [%{"file" => "a.ex"}, 7]})

      assert {:ok, "changes_required", [object, "7"]} = Ladder.verdict(objects)
      assert JSON.decode!(object) == %{"file" => "a.ex"}
    end

    test "a diagnosis is #297's map: cause, clipped texts, needs, and a checked decision" do
      long = String.duplicate("é", 2500)

      options = [
        opt("narrow"),
        Map.delete(opt("no-rule"), "rule"),
        opt("hold"),
        opt("fresh"),
        opt("Bad id")
      ]

      options = options ++ Enum.map(1..25, &opt("o#{&1}"))
      wide = put_in(opt("x"), ["details"], long)

      d =
        Ladder.diagnosis(
          diag("environment", %{
            "evidence" => long,
            "needs" => "magic",
            "decision" => %{
              "question" => "Q?",
              "options" => options ++ [wide],
              "touches" => ["spending", "x"]
            }
          })
        )

      assert {d["cause"], String.length(d["evidence"]), Map.has_key?(d, "needs")} ==
               {"environment", 2000, false}

      ids = Enum.map(d["decision"]["options"], & &1["id"])
      assert {hd(ids), length(ids)} == {"narrow", 20}
      refute Enum.any?(ids, &(&1 in ["no-rule", "hold", "fresh", "Bad id"]))
      assert {d["decision"]["authority"], d["decision"]["safe_to_continue"]} == {true, false}

      x =
        Ladder.diagnosis(
          diag("other", %{"decision" => %{"question" => "Q?", "options" => [wide]}})
        )

      assert x["decision"]["options"] |> hd() |> Map.get("details") |> String.length() == 300

      assert Ladder.diagnosis(diag("other", %{"needs" => "access"}))["needs"] == "access"

      refute Map.has_key?(
               Ladder.diagnosis(diag("other", %{"decision" => %{"question" => "Q"}})),
               "decision"
             )

      assert Ladder.diagnosis(diag("bored")) == nil
      assert Ladder.diagnosis("none") == nil
    end

    test "a worded option may not be none: the answer's reset value is reserved" do
      decision = fn options ->
        Ladder.diagnosis(
          diag("other", %{
            "decision" => %{"question" => "Q?", "options" => options, "safe_to_continue" => true}
          })
        )["decision"]
      end

      d = decision.([opt("none"), opt("narrow")])
      assert Enum.map(d["options"], & &1["id"]) == ["narrow"]
      # The recommended option was left out, so no work goes on on the next one (R1).
      assert d["safe_to_continue"] == false
      # Only none on offer: no decision at all.
      assert decision.([opt("none")]) == nil
    end
  end

  describe "sections (#297's sections/3)" do
    defp count(kind, ladder, tasks), do: length(Ladder.sections(kind, ladder, tasks))

    defp has?(kind, ladder, tasks, text),
      do: Enum.any?(Ladder.sections(kind, ladder, tasks), &String.contains?(&1, text))

    test "a review and a diagnosis get their answer formats; rung (d) also the scope choice" do
      tasks = [authored(1), reviewed(2, 1, "changes_required")]

      assert count("review", %{}, tasks) == 1
      assert has?("review", %{}, tasks, ~s("verdict"))
      assert count("diagnose", %{"rung" => "a"}, tasks) == 2
      assert has?("diagnose", %{"rung" => "a"}, tasks, ~s("cause"))
      assert count("diagnose", %{"rung" => "d"}, tasks) == 3
      assert count("author", %{"rung" => nil}, [authored(1)]) == 0
    end

    test "a fix gets the review's findings or the check's tail; an author on a rung the diagnosis and the history" do
      after_review = [
        authored(1),
        reviewed(2, 1, "changes_required", findings: ["finding-a", "finding-b"])
      ]

      assert has?("fix", %{}, after_review, "finding-a") and
               has?("fix", %{}, after_review, "finding-b")

      failed = [
        authored(1, outcome: "check_failed", check: %{"exit_status" => 1, "tail" => "boom-tail"})
      ]

      assert has?("fix", %{}, failed, "boom-tail")

      ladder = %{"rung" => "b", "diagnosis" => %{"cause" => "other", "evidence" => "ev-text"}}
      assert count("author", ladder, after_review) == 2
      assert has?("author", ladder, after_review, "ev-text")
      assert has?("author", ladder, after_review, key(2))
    end
  end
end

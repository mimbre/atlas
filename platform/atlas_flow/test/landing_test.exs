defmodule AtlasFlow.LandingTest.Support do
  @moduledoc """
  What the Landing tests share (F3-L), on F2-E's loop bench (`AtlasFlow.Sorts.Loop.Bench`):
  a bin's author and review tasks worked on the lease path with a change set on the
  repository's root (`loop`, where Bases places `example.org/acme/loop`), and Landing on its
  own `FakeCode` (Code for publishing), with Bases' `FakeCode` for a snapshot's revision.
  """
  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias AtlasFlow.{FakeCode, FakeFacts, Landing, Results, WorkSource}
  alias AtlasFlow.FakeFacts.Leasing, as: L
  alias AtlasFlow.Sorts.Loop.Bench
  alias AtlasFlow.WorkSource.Translate

  @mini {"mini", "ada"}
  @every 60_000

  def mini, do: @mini
  def every, do: @every

  @doc "Landing on `code` (its own FakeCode); `engine` gets its casts (default the test)."
  def landing!(c, code, opts \\ []) do
    start_supervised!(
      Supervisor.child_spec(
        {Landing,
         Keyword.merge(
           [
             model: AtlasFlow.Sorts.Loop,
             actors: Bench.actors(),
             clock: c.clock,
             every: @every,
             engine: self(),
             client: FakeCode.client(code),
             snapshot_client: FakeCode.client(c.code)
           ],
           opts
         )},
        id: Keyword.get(opts, :id, Landing)
      )
    )
    |> tap(&sync/1)
  end

  @doc "Waits until Landing handled every message sent to it before (a sys call, no timer)."
  def sync(landing), do: :sys.get_state(landing)

  @doc "The Engine's cast for `task`, then waits for Landing to handle it."
  def kick(landing, task \\ "TK-B-1-1") do
    Landing.publish(task, landing)
    sync(landing)
  end

  def files(key), do: [{"load.txt", "load #{key}\n"}]

  @doc "A bin `key` on the mini, supervised by ada, whose author's result passed its check."
  def authored!(c, key \\ "B-1") do
    Bench.started(c, key)
    finish(@mini, files: files(key), check: 0)
    assert Bench.settle(c, key)["state"] == "reviewing"
  end

  @doc "`authored!/2`, then its review approved it: the run is `ready`."
  def approved!(c, key \\ "B-1") do
    authored!(c, key)
    review!(c, key, "approved")
  end

  def review!(c, key, verdict) do
    finish(@mini, answer: Bench.verdict(verdict))
    Bench.settle(c, key)
  end

  @doc "As `Bench.finish/2`, with the change set on the root `loop`."
  def finish(client, opts \\ []) do
    %{lease_id: lease, work: offered} = Bench.lease!(client)
    files = Keyword.get(opts, :files, [])
    change_set = if files != [], do: change_set(files, offered.input.base.base_id)

    check =
      case Keyword.get(opts, :check) do
        nil -> []
        status -> [check: %{exit_status: status, output_tail: "tail #{status}"}]
      end

    ended = L.ended(change_set, check ++ Keyword.take(opts, [:answer]))
    assert {:recorded, _} = Bench.report(client, lease, 1, %{state: :accepted})
    assert {:recorded, _} = Bench.report(client, lease, 2, %{state: :started})
    assert {:recorded, answer} = Bench.report(client, lease, 3, ended)

    for sha <- Map.get(answer, :missing, []) do
      {_path, bytes} = Enum.find(files, fn {_, b} -> L.sha256(b) == sha end)

      assert :stored =
               WorkSource.put_blob(client, %{
                 lease_id: lease,
                 sha256: sha,
                 size: byte_size(bytes),
                 content: [bytes]
               })
    end

    drain()
    %{lease_id: lease, work: offered}
  end

  # Delivery's casts of this end (the test stands in for the Engine).
  defp drain do
    receive do
      {:"$gen_cast", {:reconcile, "bin", _}} -> drain()
    after
      0 -> :ok
    end
  end

  def change_set(files, base_id) do
    entries =
      for {path, bytes} <- files,
          do: %{
            path: path,
            op: :write,
            kind: :file,
            mode: :"100644",
            size: byte_size(bytes),
            sha256: L.sha256(bytes)
          }

    fingerprint = AtlasChangeset.fingerprint(base_id, "loop", Translate.normal(entries))
    %{base: base_id, roots: [%{root: "loop", fingerprint: fingerprint, entries: entries}]}
  end

  @doc """
  A fix task `key` of bin `bin` whose complete result (`files`, on `of`'s base) passed its
  check, as the loop would leave it: its blobs and change set in the result store, pinned.
  """
  def fix!(key, bin, of, files) do
    base = Bench.task_values(of)
    cs = Translate.normal(change_set(files, base["base_id"]))

    for {_path, bytes} <- files,
        do:
          :stored =
            Results.put(L.sha256(bytes), byte_size(bytes), [bytes], Results.room(0))

    {:ok, sha} = Results.put_manifest(cs)
    :ok = Results.pin(key, sha)

    fingerprints =
      JSON.encode!(
        for r <- cs["roots"], do: %{"root" => r["root"], "fingerprint" => r["fingerprint"]}
      )

    FakeFacts.put("task", %{
      "key" => key,
      "version" => 1,
      "values" =>
        Map.merge(Map.take(base, ~w(base_id base_snapshot attempt runtime)), %{
          "kind" => "fix",
          "state" => "ready",
          "result_state" => "complete",
          "result_manifest" => sha,
          "result_fingerprints" => fingerprints,
          "check_exit_status" => 0
        }),
      "links" => %{"task_of" => [bin]}
    })
  end

  def names(fake), do: Enum.map(FakeCode.calls(fake), &elem(&1, 0))
  def count(fake, name), do: Enum.count(names(fake), &(&1 == name))
  def requests(fake, name), do: for({^name, input} <- FakeCode.requests(fake), do: input)

  @doc "The review ids `mark_ready` was asked for, oldest first."
  def marked(fake), do: for(r <- requests(fake, :mark_ready), do: r["review_id"])

  def review_of(task), do: Bench.task_values(task)["review_id"]
end

defmodule AtlasFlow.LandingTest do
  @moduledoc """
  F3-L (F2/F3 plan rev 3 §3.2, §5 F3-L): Landing publishes a checked result as a Code draft
  review and marks it ready only when the identity chain holds (the newest review approved
  the revision Code reports, `at_revision`, CI `success`), one ready at a time and FIFO.
  Red CI is one fix signal. Landing rebuilds from Facts at boot, reads CI again on its
  injected-clock timer only while a draft is open, and back-fills a review's
  `reviewed_revision` (a12). Real Dispatch, Delivery, Bases and result store, `FakeFacts`,
  `FakeCode` and a manual clock; the test process stands in for the Engine. Asserted on
  Code's call log, task fact values and casts, never on wording.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import AtlasFlow.LandingTest.Support
  import AtlasFlow.Sorts.Loop.Bench, except: [finish: 1, finish: 2]

  alias AtlasFlow.{FakeCode, FakeFacts, ManualClock, Publish}

  setup do
    c = setup!() |> source!()
    publishing = start_supervised!({FakeCode, %{}}, id: :publishing)
    Map.put(c, :publishing, publishing)
  end

  # Facts reads so far, once Dispatch handled what it was sent (a sys call, no timer).
  defp quiet_reads do
    :sys.get_state(AtlasFlow.Dispatch)
    FakeFacts.reads()
  end

  defp advance(%{clock: {ManualClock, clock}}, landing, ms) do
    ManualClock.advance(clock, ms)
    sync(landing)
  end

  describe "publish (acceptance 1)" do
    test "a checked author result becomes one draft review; its publication is on the task",
         c do
      authored!(c)
      landing = landing!(c, c.publishing)

      assert [:create_change, :put_change_blob, :seal_change, :create_review, :review_status] ==
               names(c.publishing)

      [review] = requests(c.publishing, :create_review)
      assert review["draft"] == true
      assert review["target"] == "develop"

      v = task_values("TK-B-1-1")
      assert v["code_change_id"] == Publish.id("change", "TK-B-1-1")
      assert v["review_id"] == review["review_id"]
      assert v["published_fingerprint"] == review["fingerprint"]
      assert FakeCode.locations(c.publishing)[v["review_id"]] =~ ~r/\Awork\/flow-review-/

      {:ok, report} =
        AtlasFlow.Code.Client.review_status(FakeCode.client(c.publishing), v["review_id"])

      assert v["published_revision"] == report.revision
      assert v["review_url"] == report.link
      assert v["review_ci"] == "none"

      # The review task in flight is not touched; a repeat publishes nothing again.
      assert task_values("TK-B-1-2")["reviewed_revision"] == nil
      kick(landing)
      kick(landing, "TK-B-1-2")
      assert count(c.publishing, :create_change) == 1
      assert count(c.publishing, :create_review) == 1
      assert marked(c.publishing) == []
    end

    test "a failed check is never published", c do
      started(c)
      finish(mini(), files: files("B-1"), check: 1)
      assert settle(c)["state"] == "fixing"
      landing!(c, c.publishing)
      assert FakeCode.calls(c.publishing) == []
    end
  end

  describe "ready (acceptance 2)" do
    test "only when the review approved Code's revision, at it, with CI success", c do
      authored!(c)
      landing = landing!(c, c.publishing)
      review!(c, "B-1", "approved")
      id = review_of("TK-B-1-1")
      # The review ended after the publication: the Engine wrote what it reviewed.
      assert task_values("TK-B-1-2")["reviewed_revision"] ==
               task_values("TK-B-1-1")["published_revision"]

      for report <- [
            %{ci: :none},
            %{ci: :pending},
            %{ci: :failure},
            %{ci: :success, at_revision: false}
          ] do
        FakeCode.status(c.publishing, id, report)
        kick(landing)
        assert marked(c.publishing) == [], inspect(report)
      end

      FakeCode.status(c.publishing, id, %{ci: :success, at_revision: true})
      kick(landing)
      assert marked(c.publishing) == [id]
      v = task_values("TK-B-1-1")
      assert {v["review_ci"], is_binary(v["marked_ready_at"])} == {"success", true}

      kick(landing)
      assert marked(c.publishing) == [id]
    end

    test "an approval of an earlier revision is none: a fix published after it moves the draft",
         c do
      approved!(c)
      landing = landing!(c, c.publishing)
      id = review_of("TK-B-1-1")
      first = task_values("TK-B-1-1")["published_revision"]

      fix!("TK-B-1-3", "B-1", "TK-B-1-1", [{"load.txt", "load B-1\n"}, {"fix.txt", "two\n"}])
      kick(landing, "TK-B-1-3")
      [update] = requests(c.publishing, :update_review)
      assert {update["review_id"], update["revision"]} == {id, first}
      assert task_values("TK-B-1-3")["review_id"] == id
      assert task_values("TK-B-1-3")["published_revision"] not in [nil, first]

      FakeCode.status(c.publishing, id, %{ci: :success})
      kick(landing)
      assert task_values("TK-B-1-2")["reviewed_revision"] == first
      assert marked(c.publishing) == []
    end
  end

  describe "one ready at a time (acceptance 3)" do
    test "the others wait, and go in the order they became ready", c do
      for key <- ~w(B-1 B-2 B-3), do: approved!(c, key)
      landing = landing!(c, c.publishing)
      [b1, b2, b3] = for key <- ~w(B-1 B-2 B-3), do: review_of("TK-#{key}-1")

      FakeCode.status(c.publishing, b2, %{ci: :success})
      kick(landing, "TK-B-2-1")
      assert marked(c.publishing) == [b2]

      # B-3 becomes ready before B-1: both wait while B-2 is ready and open.
      FakeCode.status(c.publishing, b3, %{ci: :success})
      kick(landing, "TK-B-3-1")
      FakeCode.status(c.publishing, b1, %{ci: :success})
      kick(landing, "TK-B-1-1")
      assert marked(c.publishing) == [b2]

      FakeCode.status(c.publishing, b2, %{state: :merged})
      kick(landing)
      assert marked(c.publishing) == [b2, b3]

      FakeCode.status(c.publishing, b3, %{state: :closed})
      kick(landing)
      assert marked(c.publishing) == [b2, b3, b1]
    end
  end

  describe "red CI (acceptance 4)" do
    test "with no review in flight: one fix signal", c do
      approved!(c)
      landing = landing!(c, c.publishing)
      id = review_of("TK-B-1-1")

      FakeCode.status(c.publishing, id, %{ci: :failure})
      kick(landing)
      assert_received {:"$gen_cast", {:reconcile, "bin", "B-1"}}
      assert task_values("TK-B-1-1")["review_ci"] == "failure"

      kick(landing)
      advance(c, landing, every())
      refute_received {:"$gen_cast", {:reconcile, "bin", _}}
      assert marked(c.publishing) == []
    end

    test "red CI not at the review's revision (someone else's head): not recorded, no signal",
         c do
      approved!(c)
      landing = landing!(c, c.publishing)
      id = review_of("TK-B-1-1")

      FakeCode.status(c.publishing, id, %{ci: :failure, at_revision: false})
      kick(landing)
      advance(c, landing, every())
      refute_received {:"$gen_cast", {:reconcile, "bin", _}}
      assert task_values("TK-B-1-1")["review_ci"] != "failure"

      # Control: the same red CI back at the revision is recorded and signalled.
      FakeCode.status(c.publishing, id, %{ci: :failure, at_revision: true})
      kick(landing)
      assert_received {:"$gen_cast", {:reconcile, "bin", "B-1"}}
      assert task_values("TK-B-1-1")["review_ci"] == "failure"
    end

    test "during a review: the one fix signal waits for the verdict", c do
      authored!(c)
      landing = landing!(c, c.publishing)
      id = review_of("TK-B-1-1")

      # Recorded for the verdict to see, but no signal while the review is in flight.
      FakeCode.status(c.publishing, id, %{ci: :failure})
      kick(landing)
      advance(c, landing, every())
      refute_received {:"$gen_cast", {:reconcile, "bin", _}}
      assert task_values("TK-B-1-1")["review_ci"] == "failure"

      review!(c, "B-1", "approved")
      kick(landing, "TK-B-1-2")
      assert_received {:"$gen_cast", {:reconcile, "bin", "B-1"}}
      kick(landing)
      refute_received {:"$gen_cast", {:reconcile, "bin", _}}
      assert marked(c.publishing) == []
    end
  end

  describe "red CI becomes a fix (acceptance 4, the Engine's side)" do
    alias AtlasFlow.Activities.Task

    defp given(run) do
      cs = run["pending"]["task"]["work"]["input"]["change_set"]
      cs && cs["manifest"]
    end

    defp instructions(run), do: run["pending"]["task"]["work"]["instructions"]

    test "a review that ends on red CI: approved is a fix of the reviewed result, not ready", c do
      authored!(c)
      landing = landing!(c, c.publishing)
      FakeCode.status(c.publishing, review_of("TK-B-1-1"), %{ci: :failure})
      kick(landing)
      author = task_values("TK-B-1-1")

      run = review!(c, "B-1", "approved")
      assert run["state"] == "fixing"
      assert run["pending"]["task"]["key"] == "TK-B-1-3"
      assert given(run) == author["result_manifest"]
      assert run["pending"]["ladder"]["fixes"] == 1
      # The fix is told the CI failure: the revision and review link Landing recorded.
      assert String.contains?(instructions(run), author["published_revision"])
      assert String.contains?(instructions(run), author["review_url"])
      assert marked(c.publishing) == []
    end

    test "changes required on red CI: one fix that carries both", c do
      authored!(c)
      landing = landing!(c, c.publishing)
      FakeCode.status(c.publishing, review_of("TK-B-1-1"), %{ci: :failure})
      kick(landing)
      author = task_values("TK-B-1-1")

      finish(mini(), answer: verdict("changes_required", ["strap the load"]))
      run = settle(c)
      assert run["state"] == "fixing"
      assert run["pending"]["ladder"]["fixes"] == 1
      assert String.contains?(instructions(run), "strap the load")
      assert String.contains?(instructions(run), author["published_revision"])
    end

    test "CI green at the verdict: approved is ready, and the fix is not told of CI", c do
      authored!(c)
      landing = landing!(c, c.publishing)
      FakeCode.status(c.publishing, review_of("TK-B-1-1"), %{ci: :success})
      kick(landing)
      assert review!(c, "B-1", "approved")["state"] == "ready"
    end

    test "red after ready (no review in flight): a fix state with no step runs the CI fix", c do
      approved!(c)
      landing = landing!(c, c.publishing)
      ready = run(c)
      assert ready["state"] == "ready"
      {:task, fix} = c.runner.flows["work"].mechanism("fixing")
      subject = FakeFacts.get("bin", "B-1")

      ctx = %{
        assignee: {:machinery, "mini"},
        number: fn -> {:ok, 9} end,
        now: ~U[2026-11-17 12:00:00Z]
      }

      # The run as a branch from ready to fixing would enter it: no task, no step.
      entered = put_in(ready, ["pending", "task"], nil)

      assert Task.step(entered, fix, subject, ctx) == :none

      FakeCode.status(c.publishing, review_of("TK-B-1-1"), %{ci: :failure})
      kick(landing)
      assert_received {:"$gen_cast", {:reconcile, "bin", "B-1"}}
      author = task_values("TK-B-1-1")

      assert {:pending, intent, [_create], ladder} = Task.step(entered, fix, subject, ctx)
      assert intent["key"] == "TK-B-1-9"
      assert intent["work"]["input"]["change_set"]["manifest"] == author["result_manifest"]
      assert intent["work"]["input"]["permissions"] == "workspace-write"
      assert intent["work"]["after_check"] == %{"command" => ["bin/check"]}
      assert String.contains?(intent["work"]["instructions"], author["published_revision"])
      assert ladder["fixes"] == ready["pending"]["ladder"]["fixes"] + 1

      # Only a fix runs it: a review state with no step still starts nothing.
      {:task, review} = c.runner.flows["work"].mechanism("reviewing")
      assert Task.step(entered, review, subject, ctx) == :none
    end
  end

  describe "boot (acceptance 5)" do
    test "a restarted Landing rebuilds from Facts alone: no second publication, then ready", c do
      authored!(c)
      landing!(c, c.publishing)
      review!(c, "B-1", "approved")
      before = task_values("TK-B-1-1")
      :ok = stop_supervised(AtlasFlow.Landing)

      FakeCode.status(c.publishing, before["review_id"], %{ci: :success})
      calls = length(FakeCode.calls(c.publishing))
      landing!(c, c.publishing)

      assert Enum.drop(names(c.publishing), calls) == [:review_status, :mark_ready]
      published = ~w(code_change_id review_id review_url published_revision published_fingerprint)
      assert Map.take(task_values("TK-B-1-1"), published) == Map.take(before, published)
      assert task_values("TK-B-1-1")["review_ci"] == "success"
      assert marked(c.publishing) == [before["review_id"]]
    end
  end

  describe "the CI timer (acceptance 7)" do
    test "CI is read again on Landing's clock only while a draft is open", c do
      landing = landing!(c, c.publishing)
      # No draft: the clock wakes nothing (no sweep, so not even a read of Facts). The
      # count is every Flow endpoint's: Dispatch's own reads (its boot, a `ready` cast) are
      # waited for first.
      reads = quiet_reads()
      advance(c, landing, every())
      assert FakeCode.calls(c.publishing) == []
      assert FakeFacts.reads() == reads

      authored!(c)
      kick(landing)
      id = review_of("TK-B-1-1")
      reads = count(c.publishing, :review_status)
      assert reads == 1

      advance(c, landing, every() - 1)
      assert count(c.publishing, :review_status) == reads
      advance(c, landing, 1)
      assert count(c.publishing, :review_status) == reads + 1

      # The draft goes (closed): read once more, then never again.
      FakeCode.status(c.publishing, id, %{state: :closed})
      advance(c, landing, every())
      assert count(c.publishing, :review_status) == reads + 2

      after_close = quiet_reads()
      advance(c, landing, every())
      advance(c, landing, every())
      assert count(c.publishing, :review_status) == reads + 2
      assert FakeFacts.reads() == after_close
    end
  end

  describe "back-fill (acceptance 8, a12)" do
    test "a review that ended before the publication gets its revision; the draft becomes ready",
         c do
      approved!(c)
      assert task_values("TK-B-1-2")["reviewed_revision"] == nil
      assert task_values("TK-B-1-1")["published_revision"] == nil

      landing = landing!(c, c.publishing)
      published = task_values("TK-B-1-1")["published_revision"]
      assert is_binary(published)
      assert task_values("TK-B-1-2")["reviewed_revision"] == published

      FakeCode.status(c.publishing, review_of("TK-B-1-1"), %{ci: :success})
      kick(landing)
      assert marked(c.publishing) == [review_of("TK-B-1-1")]
    end
  end
end

defmodule AtlasFlow.LandingEngineTest do
  @moduledoc """
  F3-L acceptance 1 and 6 through the real Engine: a check pass is published as a draft in
  parallel with the review, and a Landing stuck in a Code call delays no grant (lesson 1),
  because the Engine only casts to it. Landing's Code is gated: each call tells the test,
  and waits for its go, so the test knows by a message that Landing is inside Code.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import AtlasFlow.LandingTest.Support, except: [finish: 2]

  alias AtlasFlow.{Bases, Delivery, Dispatch, Engine, FakeCode, FakeFacts}
  alias AtlasFlow.{ManualClock, Results}
  alias AtlasFlow.Sorts.Loop
  alias AtlasFlow.Sorts.Loop.Bench

  defmodule Gate do
    @moduledoc "Landing's Code: FakeCode behind a gate the test opens (`{fake, gate, test}`)."
    alias AtlasFlow.FakeCode

    for {name, arity} <- [
          create_change: 2,
          put_change_blob: 4,
          seal_change: 2,
          create_review: 2,
          update_review: 2,
          mark_ready: 2,
          review_status: 2,
          snapshot_revision: 3
        ] do
      args = Macro.generate_arguments(arity - 1, __MODULE__)

      def unquote(name)({fake, gate, test}, unquote_splicing(args)) do
        if Agent.get(gate, & &1) == :closed do
          send(test, {:gated, unquote(name), self()})

          receive do
            :go -> :ok
          end
        end

        FakeCode.unquote(name)(fake, unquote_splicing(args))
      end
    end
  end

  @actors Bench.actors()

  setup do
    Application.put_env(:atlas_bus, :store, "landing-#{System.unique_integer([:positive])}")
    dir = Path.join(System.tmp_dir!(), "landing-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    start_supervised!(FakeFacts)
    {:ok, clock} = ManualClock.start_link(~U[2026-11-17 12:00:00Z])
    clock = {ManualClock, clock}
    results = [dir: dir, clock: clock, sweep_ms: 86_400_000, pins: fn -> [] end]
    start_supervised!(Supervisor.child_spec({Results, results}, id: Results))

    code = start_supervised!({FakeCode, %{}}, id: :code)
    FakeCode.put(code, Bench.repository(), "develop", "rev_1", %{"README.md" => Bench.readme()})
    for clerk <- ~w(ada bea dee), do: FakeFacts.put("clerk", %{"key" => clerk})
    for robot <- ~w(mini laptop), do: FakeFacts.put("robot", %{"key" => robot})

    runner = AtlasFlow.Model.load(Loop, :prod, @actors)
    c = %{runner: runner, clock: clock, code: code, dir: dir}
    Bench.start_bases(c)

    start_supervised!(
      {Dispatch,
       model: Loop, actors: @actors, clock: clock, poll_wait: 0, sweep_ms: nil, resync_ms: nil}
    )

    start_supervised!(
      {Delivery, model: Loop, actors: @actors, clock: clock, engine: AtlasFlow.Engine}
    )

    publishing = start_supervised!({FakeCode, %{}}, id: :publishing)
    {:ok, gate} = Agent.start_link(fn -> :closed end)
    Map.merge(c, %{publishing: publishing, gate: gate})
  end

  test "a check pass is a draft in parallel with the review; a Landing inside Code delays no grant",
       c do
    # Bases holds develop's base before the Engine's first round.
    Bases.request(Bench.repository(), "develop", {self(), :based})
    assert_receive :based, 2_000
    Bench.bin("B-1", "mini")

    landing =
      landing!(c, c.publishing,
        client: {Gate, {c.publishing, c.gate, self()}},
        engine: AtlasFlow.Engine,
        name: AtlasFlow.Landing
      )

    engine =
      start_supervised!(
        {Engine,
         every: 3_600_000, clock: c.clock, model: Loop, actors: @actors, name: AtlasFlow.Engine}
      )

    Engine.idle(engine)
    Bench.supervise(c, "ada")
    Engine.round(engine)

    # The author's result, its check passed: Delivery casts the Engine, which stores it and
    # casts Landing; Landing goes into Code and stays there until the test lets it go.
    finish(mini(), files: files("B-1"), check: 0)
    assert_receive {:gated, :create_change, ^landing}, 2_000

    # Meanwhile the Engine goes on: the review's intent, and Dispatch grants it.
    Engine.round(engine)
    assert Bench.run(c)["state"] == "reviewing"
    %{work: review} = Bench.lease!(mini())
    assert review.input.permissions == "read-only"
    assert Bench.task_values("TK-B-1-1")["published_revision"] == nil

    # Let Landing go on: it publishes the draft while the review is in flight.
    Agent.update(c.gate, fn _ -> :open end)
    send(landing, :go)
    sync(landing)

    v = Bench.task_values("TK-B-1-1")
    assert is_binary(v["published_revision"]) and is_binary(v["review_id"])
    assert [%{"draft" => true}] = requests(c.publishing, :create_review)
    assert Bench.task_values("TK-B-1-2")["state"] == "waiting"
  end

  # As the support's `finish/2`, but Delivery casts the real Engine (nothing to drain).
  defp finish(client, opts) do
    %{lease_id: lease, work: offered} = Bench.lease!(client)
    files = Keyword.fetch!(opts, :files)
    cs = change_set(files, offered.input.base.base_id)
    ended = AtlasFlow.FakeFacts.Leasing.ended(cs, check: %{exit_status: 0, output_tail: "ok"})
    assert {:recorded, _} = Bench.report(client, lease, 1, %{state: :accepted})
    assert {:recorded, _} = Bench.report(client, lease, 2, %{state: :started})
    assert {:recorded, answer} = Bench.report(client, lease, 3, ended)

    for sha <- Map.get(answer, :missing, []) do
      {_path, bytes} =
        Enum.find(files, fn {_, b} -> AtlasFlow.FakeFacts.Leasing.sha256(b) == sha end)

      assert :stored =
               AtlasFlow.WorkSource.put_blob(client, %{
                 lease_id: lease,
                 sha256: sha,
                 size: byte_size(bytes),
                 content: [bytes]
               })
    end

    :ok
  end
end

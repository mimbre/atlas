defmodule AtlasRuntime.Work.FromWorkTest do
  @moduledoc """
  S5a P9 (design §3.9 "New work based on an earlier result"; s5a-plan B2–B7, B25, B30): a
  `from_work` work runs in its own Runtime-chosen folder, `<home>/workers/work-<work_id>`,
  which the core composes at start through the real helper (`snapshot compose`, never Code)
  from the earlier work's frozen result: its base plus exactly its change set, read-only on
  disk or writable. The source is pinned at accept. It always runs in a fresh conversation.
  A completed follow-up is frozen relative to the original base (cumulative) and records
  `based_on`.

  Every chain starts from a `base` work (P7a, P7b) on the loopback Code stand-in. A goal
  `wait NAME` keeps a turn running until `<home>/NAME` is removed, so a test can look at the
  folder the agent sees.
  """
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness

  import AtlasRuntime.CodeStandIn,
    only: [submit_base!: 2, expected_folder: 2, private_attempt: 3, writable_bits: 1]

  alias AtlasRuntime.Boundary.Work, as: F
  alias AtlasRuntime.CodeStandIn
  alias AtlasRuntime.Model.Work, as: M
  alias AtlasRuntime.Work.Store

  @moduletag capture_log: true

  @retention 3600
  @files %{"README.md" => "base\n", "run.sh" => "echo run\n", "old.md" => "old\n"}
  @source_goal "write atlas/one.txt one; chmod atlas/run.sh 755; symlink atlas/link one.txt; delete atlas/old.md"

  setup context do
    bench = start!(%{}, Keyword.put(Map.get(context, :work_options, []), :retention, @retention))
    code = CodeStandIn.start!(bench.dir, @files)
    on_exit(fn -> CodeStandIn.stop(code, bench.dir) end)
    %{bench: bench, code: code}
  end

  defp from_request(work_id, instructions, permissions, extra \\ %{}) do
    {workspace, extra} = Map.pop(extra, :workspace, %{})

    Map.merge(
      %{
        title: instructions,
        instructions: instructions,
        profile: "light_work",
        cost_class: "standard",
        workspace:
          Map.merge(
            %{kind: "from_work", work_id: work_id, permissions: permissions},
            workspace
          )
      },
      extra
    )
  end

  defp submit_from!(work_id, instructions, permissions, extra \\ %{}, client \\ client()) do
    assert %F.Outcome.Accepted{work: work} =
             F.submit(client, from_request(work_id, instructions, permissions, extra))

    work
  end

  # A completed, quiescent work, and its frozen result as get_frozen serves it.
  defp done!(id) do
    work =
      await_work(
        id,
        &(&1.state == :completed and Enum.all?(&1.attempts, fn a -> a.quiescent end))
      )

    {work, F.get_frozen(client(), %{work_id: id, attempt: List.last(work.attempts).attempt})}
  end

  defp source!(code, goal \\ @source_goal) do
    work = submit_base!(code, goal)
    done!(work.work_id)
  end

  # What an agent sees in a folder: every entry by relative path, with its content (a
  # symlink's target, a directory's type) and whether a file is executable. Write bits are
  # compared apart.
  defp tree(folder) do
    for path <- Path.wildcard(Path.join(folder, "**"), match_dot: true), into: %{} do
      {:ok, info} = File.lstat(path)

      content =
        case info.type do
          :regular -> File.read!(path)
          :symlink -> {:link, File.read_link!(path)}
          other -> other
        end

      # A symlink's own mode is not content (lstat gives 0777 on macOS).
      executable = info.type == :regular and Bitwise.band(info.mode, 0o111) != 0
      {Path.relative_to(path, folder), {content, executable}}
    end
  end

  defp any_write_bit?(folder) do
    [folder | Path.wildcard(Path.join(folder, "**"), match_dot: true)]
    |> Enum.reject(&match?({:ok, %{type: :symlink}}, File.lstat(&1)))
    |> Enum.any?(&(writable_bits(&1) != 0))
  end

  defp hold!(bench, name), do: File.write!(Path.join(bench.dir, name), "")
  defp release!(bench, name), do: File.rm!(Path.join(bench.dir, name))

  defp roots(%F.Outcome.Frozen{roots: roots}),
    do: for(root <- roots, do: %F.RootFingerprint{root: root.root, fingerprint: root.fingerprint})

  defp entries(%F.Outcome.Frozen{roots: [root]}),
    do: Map.new(root.entries, &{&1.path, {&1.op, &1.kind, &1.mode, &1.sha256, &1.target}})

  defp launch_of(bench, goal), do: Enum.find(launches(bench), &(&1["goal"] == goal))

  test "read-only: the agent sees exactly the base plus the frozen change set, in its own folder, read-only, in a fresh conversation",
       %{bench: bench, code: code} do
    {source, source_frozen} = source!(code)
    source_folder = expected_folder(bench.dir, source.work_id)
    source_tree = tree(source_folder)
    {:ok, %{inode: source_inode}} = File.lstat(source_folder)

    hold!(bench, "hold-ro")
    follow = submit_from!(source.work_id, "wait hold-ro", "read-only")
    await_launch(bench, follow)
    folder = expected_folder(bench.dir, follow.work_id)

    # Composed: the base plus exactly the change set (written, executable, symlink, deleted),
    # which is what the source's agent left; and nothing in it is writable.
    seen = tree(folder)
    assert seen == source_tree
    assert seen["atlas/one.txt"] == {"one\n", false}
    assert seen["atlas/run.sh"] == {"echo run\n", true}
    assert seen["atlas/link"] == {{:link, "one.txt"}, false}
    refute Map.has_key?(seen, "atlas/old.md")
    assert seen["atlas/README.md"] == {"base\n", false}
    refute any_write_bit?(folder)

    # The turn runs in that folder with the read-only sandbox, in a fresh conversation.
    launch = launch_of(bench, "wait hold-ro")
    assert launch["cwd"] == folder
    refute launch["resumed"]
    refute "resume" in launch["argv"]
    assert %{folder: ^folder, preparing: false} = private_attempt(bench.dir, follow.work_id, 1)

    # No Code contact: compose reads only the Runtime home.
    assert CodeStandIn.archives(code) == ["atlas"]

    release!(bench, "hold-ro")
    {done, frozen} = done!(follow.work_id)
    [%{turn_id: turn_id, result: result}] = done.attempts
    assert turn(bench, turn_id)["sandbox"] == "read-only"

    # Its own frozen result: relative to the original base, the same fingerprints as the
    # source's, and based_on names the source's attempt and fingerprints.
    assert %F.Outcome.Frozen{work_id: id, attempt: 1, base: base} = frozen
    assert id == follow.work_id and base == code.id
    assert roots(frozen) == roots(source_frozen)
    assert result.work_product.frozen.fingerprints == roots(source_frozen)

    assert %F.BasedOn{work_id: source_id, attempt: 1, fingerprints: based} =
             result.work_product.based_on

    assert source_id == source.work_id and based == roots(source_frozen)

    # The source's folder is untouched.
    assert tree(source_folder) == source_tree
    assert {:ok, %{inode: ^source_inode}} = File.lstat(source_folder)

    # The stored request is the submitted one; the pinned source is private.
    record = Store.read_work(bench.dir, follow.work_id)

    assert %M.FromWork{work_id: ^source_id, attempt: nil, permissions: :read_only} =
             record.request.workspace

    assert %M.Source{work_id: ^source_id, attempt: 1} = record.source
    assert %F.FromWork{attempt: nil} = done.request.workspace
  end

  test "read-only: any write the agent attempts fails, and nothing is written",
       %{bench: bench, code: code} do
    {source, _frozen} = source!(code)
    follow = submit_from!(source.work_id, "write atlas/new.txt agent", "read-only")

    work = await_work(follow.work_id, &(&1.state in [:failed, :crashed, :completed]))
    assert work.state in [:failed, :crashed]
    folder = expected_folder(bench.dir, follow.work_id)
    refute File.exists?(Path.join(folder, "atlas/new.txt"))
    assert launch_of(bench, "write atlas/new.txt agent")["cwd"] == folder
  end

  test "workspace-write: a further change is frozen relative to the original base, holding both (cumulative), with based_on",
       %{bench: bench, code: code} do
    {source, source_frozen} = source!(code)
    follow = submit_from!(source.work_id, "write atlas/two.txt two", "workspace-write")
    {done, frozen} = done!(follow.work_id)
    folder = expected_folder(bench.dir, follow.work_id)

    [%{turn_id: turn_id, result: result}] = done.attempts
    turn = turn(bench, turn_id)
    assert turn["cwd"] == folder
    assert turn["permissions"]["profile"] == "materialized-folder"
    assert turn["permissions"]["root"] == folder

    assert frozen.base == code.id
    assert result.work_product.frozen.base == code.id
    assert result.work_product.frozen.fingerprints == roots(frozen)
    refute roots(frozen) == roots(source_frozen)

    # Every change of the chain, relative to the base: the source's and its own.
    assert entries(frozen) ==
             Map.put(entries(source_frozen), "two.txt", entries(frozen)["two.txt"])

    assert {:write, :file, :"100644", _sha, nil} = entries(frozen)["two.txt"]
    assert {:delete, nil, nil, nil, nil} = entries(frozen)["old.md"]

    assert %F.BasedOn{work_id: id, attempt: 1, fingerprints: based} =
             result.work_product.based_on

    assert id == source.work_id and based == roots(source_frozen)
    assert writable_bits(Path.join(folder, "atlas/two.txt")) != 0
  end

  test "a client without choose_path runs base → from_work → from_work; each result is cumulative, and no request or refusal names a path",
       %{bench: bench, code: code} do
    # The owner without choose_path (the harness client holds it on develop, D44).
    reader = {"c1", [:submit, :cancel, :read]}
    refute :choose_path in elem(reader, 1)

    {first, first_frozen} = source!(code, "write atlas/a.txt a")
    second = submit_from!(first.work_id, "write atlas/b.txt b", "workspace-write", %{}, reader)
    {_second, second_frozen} = done!(second.work_id)
    third = submit_from!(second.work_id, "write atlas/c.txt c", "workspace-write", %{}, reader)
    {third_done, third_frozen} = done!(third.work_id)

    assert Map.keys(entries(first_frozen)) == ["a.txt"]
    assert Map.keys(entries(second_frozen)) == ["a.txt", "b.txt"]
    assert Map.keys(entries(third_frozen)) == ["a.txt", "b.txt", "c.txt"]

    assert Enum.map([first_frozen, second_frozen, third_frozen], & &1.base) ==
             List.duplicate(code.id, 3)

    [%{result: result}] = third_done.attempts
    assert %F.BasedOn{work_id: id, fingerprints: based} = result.work_product.based_on
    assert id == second.work_id and based == roots(second_frozen)

    # The requests carry only ids; a from_work workspace has no path field at all.
    for work <- [second, third_done] do
      refute Map.has_key?(Map.from_struct(work.request.workspace), :path)
    end

    # Without choose_path a refusal carries no detail at all (B32), so it names no path.
    assert %F.Outcome.Refused{reason: :not_permitted, detail: nil} =
             F.submit(reader, from_request("work-0000000000000000", "x", "read-only"))

    assert File.read!(Path.join(expected_folder(bench.dir, third.work_id), "atlas/c.txt")) ==
             "c\n"
  end

  test "refusals: no frozen result, another client's or an unknown work, policy, resume_from, resume retry",
       %{bench: bench, code: code} do
    {source, _frozen} = source!(code)
    before = Path.wildcard(Path.join(bench.dir, "work/**"))

    # (b) Another client's work and an unknown work: the same not_permitted, the same detail.
    assert %F.Outcome.Refused{reason: :not_permitted, detail: other} =
             F.submit(client("c2"), from_request(source.work_id, "other", "read-only"))

    assert %F.Outcome.Refused{reason: :not_permitted, detail: unknown} =
             F.submit(client(), from_request("work-0123456789abcdef", "unknown", "read-only"))

    assert other == unknown

    # read_all may read it, so it may build on it.
    assert %F.Outcome.Accepted{} =
             F.submit(
               client("admin", [:read_all]),
               from_request(source.work_id, "complete admin", "read-only")
             )

    # (e) resume_from with from_work.
    assert %F.Outcome.Refused{reason: :invalid} =
             F.submit(
               client(),
               from_request(source.work_id, "resume", "read-only", %{
                 resume_from: "turn-0123456789abcdef"
               })
             )

    # An attempt that does not exist, or that is not completed, has no frozen result.
    assert %F.Outcome.Refused{reason: :unsupported_workspace} =
             F.submit(
               client(),
               from_request(source.work_id, "attempt 2", "read-only", %{workspace: %{attempt: 2}})
             )

    # (d) A permission the profile does not allow.
    write_policy!(bench.dir, %{
      "profiles" => %{
        "light_work" => %{
          "permissions" => ["read-only"],
          "cost_classes" => ["standard"],
          "options" => [%{"provider" => "openai", "harness" => "codex", "model" => "gpt-test"}]
        }
      }
    })

    assert %F.Outcome.Refused{reason: :policy_forbids} =
             F.submit(client(), from_request(source.work_id, "no write", "workspace-write"))

    write_policy!(bench.dir)

    # Of all those submits, only the admin's work was written.
    assert length(Path.wildcard(Path.join(bench.dir, "work/*.json"))) ==
             length(Enum.filter(before, &String.ends_with?(&1, ".json"))) + 1

    # (f) retry resume: true of a from_work work.
    follow = submit_from!(source.work_id, "complete follow", "read-only")
    {done, _} = done!(follow.work_id)
    [%{turn_id: turn_id}] = done.attempts
    await(fn -> turn(bench, turn_id)["session_id"] end)

    assert %F.Outcome.Refused{reason: :resume_unavailable} =
             F.retry(client(), %{work_id: follow.work_id, resume: true})

    assert [_] = work!(follow.work_id).attempts
  end

  test "(a) a plain folder or a repository work has no frozen result: unsupported_workspace",
       %{bench: bench} do
    plain = submit!(bench, "complete plain", %{})
    await_state(plain.work_id, :completed)

    assert %F.Outcome.Refused{reason: :unsupported_workspace} =
             F.submit(client(), from_request(plain.work_id, "from plain", "read-only"))

    # A repository work, as the store holds one (no Git is run).
    stop_work()
    record = Store.read_work(bench.dir, plain.work_id)

    repository = %{
      record
      | work_id: "work-00000000000000aa",
        client_key: nil,
        idempotency_key: "work-00000000000000aa",
        request: %{
          record.request
          | workspace: M.Repository.new!(url: "https://example.invalid/r.git", branch: "b")
        }
    }

    Store.put_work!(bench.dir, repository)
    start_work!(bench)

    assert %F.Outcome.Refused{reason: :unsupported_workspace} =
             F.submit(client(), from_request("work-00000000000000aa", "from repo", "read-only"))

    # A live work has no completed attempt yet.
    hold!(bench, "hold-live")
    live = submit!(bench, "wait hold-live")
    await_launch(bench, live)

    assert %F.Outcome.Refused{reason: :unsupported_workspace} =
             F.submit(client(), from_request(live.work_id, "from live", "read-only"))

    release!(bench, "hold-live")
  end

  test "(c) a pruned source gives pruned; one another work still names is retained and accepted",
       %{bench: bench, code: code} do
    {gone, _} = source!(code, "write atlas/gone.txt gone")
    {kept, _} = source!(code, "write atlas/kept.txt kept")
    referrer = submit_from!(kept.work_id, "complete referrer", "read-only")
    done!(referrer.work_id)

    stop_work()

    for id <- [gone.work_id, kept.work_id] do
      record = Store.read_work(bench.dir, id)
      Store.put_work!(bench.dir, aged(record))
    end

    start_work!(bench, retention: @retention)
    await(fn -> match?(%F.Outcome.Pruned{}, F.get_work(client(), %{work_id: gone.work_id})) end)
    await(fn -> match?(%F.Outcome.Pruned{}, F.get_work(client(), %{work_id: kept.work_id})) end)

    assert %F.Outcome.Pruned{work_id: id, kind: :completed} =
             F.submit(client(), from_request(gone.work_id, "from gone", "read-only"))

    assert id == gone.work_id

    # Retained (the referrer's source names it): accepted, and composed from it.
    follow = submit_from!(kept.work_id, "complete from kept", "read-only")
    {_done, frozen} = done!(follow.work_id)
    assert Map.keys(entries(frozen)) == ["kept.txt"]

    # Visibility comes from the key tombstone's client.
    assert %F.Outcome.Refused{reason: :not_permitted} =
             F.submit(client("c2"), from_request(kept.work_id, "c2 kept", "read-only"))
  end

  test "the source is pinned at accept: a later completed attempt of the source does not change what a retry composes",
       %{bench: bench, code: code} do
    hold!(bench, "hold-src")
    source = submit_base!(code, "wait hold-src")
    await_launch(bench, source)
    source_folder = expected_folder(bench.dir, source.work_id)
    File.write!(Path.join(source_folder, "atlas/v.txt"), "one\n")
    release!(bench, "hold-src")
    done!(source.work_id)

    follow = submit_from!(source.work_id, "complete pinned", "read-only")
    {_, first} = done!(follow.work_id)
    assert %M.Source{attempt: 1} = Store.read_work(bench.dir, follow.work_id).source

    # The source's attempt 2 completes with other content.
    hold!(bench, "hold-src")
    assert %F.Outcome.Accepted{} = F.retry(client(), %{work_id: source.work_id})
    await_launch(bench, source, 2)
    File.write!(Path.join(source_folder, "atlas/v.txt"), "two\n")
    release!(bench, "hold-src")
    await_work(source.work_id, &match?([_, %{state: :completed, quiescent: true}], &1.attempts))

    # A fresh retry of the follow-up composes attempt 1 again.
    assert %F.Outcome.Accepted{} = F.retry(client(), %{work_id: follow.work_id})

    done =
      await_work(follow.work_id, &match?([_, %{state: :completed, quiescent: true}], &1.attempts))

    folder = expected_folder(bench.dir, follow.work_id)
    assert File.read!(Path.join(folder, "atlas/v.txt")) == "one\n"
    [_, %{result: result}] = done.attempts
    assert %F.BasedOn{attempt: 1} = result.work_product.based_on
    assert result.work_product.frozen.fingerprints == roots(first)
  end

  test "(g) a fresh retry of a writable follow-up rebuilds its folder by composing the pinned source again",
       %{bench: bench, code: code} do
    {source, _} = source!(code)
    hold!(bench, "hold-w")
    follow = submit_from!(source.work_id, "wait hold-w", "workspace-write")
    await_launch(bench, follow)
    folder = expected_folder(bench.dir, follow.work_id)
    starting = tree(folder)

    # What the agent wrote in attempt 1.
    File.write!(Path.join(folder, "atlas/agent.txt"), "agent\n")
    release!(bench, "hold-w")
    {_, first} = done!(follow.work_id)
    assert Map.has_key?(entries(first), "agent.txt")

    hold!(bench, "hold-w")
    assert %F.Outcome.Accepted{} = F.retry(client(), %{work_id: follow.work_id})
    await_launch(bench, follow, 2)

    # The same starting tree: the earlier write is gone.
    assert tree(folder) == starting
    refute File.exists?(Path.join(folder, "atlas/agent.txt"))
    assert Path.wildcard(Path.join([bench.dir, "scratch", "rebuild-*"])) == []
    assert Path.wildcard(Path.join([bench.dir, "scratch", "compose-*"])) == []
    release!(bench, "hold-w")

    done = await_work(follow.work_id, &match?([_, %{state: :completed}], &1.attempts))
    assert [%{state: :completed}, %{state: :completed}] = done.attempts
    # Attempt 1's frozen result survives the rebuild.
    assert ^first = F.get_frozen(client(), %{work_id: follow.work_id, attempt: 1})

    assert [_, %{"resumed" => false}] =
             Enum.filter(launches(bench), &(&1["goal"] == "wait hold-w"))
  end

  test "a restart while composing: interrupted, retryable, never prepared again; a fresh retry composes",
       %{bench: bench, code: code} do
    {source, _} = source!(code)
    test = self()

    hook = fn
      :composing ->
        send(test, {:composing, self()})

        receive do
          :go -> :ok
        end

      _ ->
        :ok
    end

    stop_work()
    start_work!(bench, prepare_hook: hook, retention: @retention)
    follow = submit_from!(source.work_id, "complete after restart", "read-only")
    assert_receive {:composing, preparer}, 10_000
    assert %{state: :starting, preparing: true} = private_attempt(bench.dir, follow.work_id, 1)

    stop_work()
    start_work!(bench, retention: @retention)
    [attempt] = await_state(follow.work_id, :interrupted).attempts
    assert attempt.result.retryable
    send(preparer, :go)

    heartbeats(3)
    assert launch_of(bench, "complete after restart") == nil
    assert Path.wildcard(Path.join([bench.dir, "scratch", "compose-*"])) == []

    assert %F.Outcome.Accepted{} = F.retry(client(), %{work_id: follow.work_id})
    done = await_work(follow.work_id, &match?([_, %{state: :completed}], &1.attempts))
    assert [%{state: :interrupted}, %{state: :completed}] = done.attempts

    assert launch_of(bench, "complete after restart")["cwd"] ==
             expected_folder(bench.dir, follow.work_id)
  end

  defp aged(record) do
    old =
      DateTime.add(DateTime.utc_now(), -2 * @retention, :second)
      |> DateTime.truncate(:millisecond)

    %{
      record
      | attempts:
          Enum.map(record.attempts, fn attempt ->
            %{attempt | timestamps: %{attempt.timestamps | ended_at: old}}
          end)
    }
  end
end

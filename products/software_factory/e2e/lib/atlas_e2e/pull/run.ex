defmodule AtlasE2E.Pull.Run do
  @moduledoc """
  One pull-e2e run in `<run>` (plan rev 2 §9 setup, §10; review round 1): setup, the
  scenarios in order, the graceful reap and its proof, and the verdict. It takes its builds
  from the warm cache `AtlasE2E.Pull.Prepare` made before it (Main's ruling: compile before
  the timed run), and prints the measured durations split into compile (the prepare) and
  test (this run): every step, every scenario, the phases and the total. They are also kept
  in `<artifacts>/<run>/durations.json`, one folder per run (nothing of an earlier run is
  wiped).

  Exit codes: 0 passed · 1 a scenario failed · 3 watchdog (5 100 s, an upper bound only) ·
  4 `environment_too_slow` · 5 the reap's proof failed (on every path: also after a failure,
  a signal, the watchdog or a crash) · 6 incomplete (a scenario needs a package this tree
  lacks, e.g. D2; nothing failed).
  """
  alias AtlasE2E.{Instance}

  alias AtlasE2E.Pull.{
    Bench,
    Console,
    Core,
    Edge,
    Facts,
    Fixture,
    Hub,
    Needs,
    Prepare,
    Runtime,
    Scenario,
    Seed,
    Steps,
    Stub
  }

  @watchdog_s 5_100
  @scenarios Path.expand("../../../pull/scenarios", __DIR__)

  def scenarios_dir, do: @scenarios

  @doc "The artifacts folder of `run`: `artifacts/pull/<run's name>/` (never wiped)."
  def artifacts(run) do
    base =
      System.get_env("ATLAS_E2E_ARTIFACTS") ||
        Path.join(Instance.root(), "products/software_factory/e2e/artifacts/pull")

    Path.join(base, Path.basename(run))
  end

  @doc """
  Run `fun`, whatever way it ends: `{:ok, value}`, or `{:error, kind, reason, stacktrace}`
  for a raise, an `exit` (a call that timed out) or a `throw` (F4: none escapes the verdict).
  """
  def guard(fun) do
    {:ok, fun.()}
  rescue
    error -> {:error, :error, error, __STACKTRACE__}
  catch
    kind, reason -> {:error, kind, reason, __STACKTRACE__}
  end

  @doc "The watchdog's exit status: 5 when its reap found something left, else 3."
  def watchdog_status({:ok, _}), do: 3
  def watchdog_status({:error, _}), do: 5

  def main(run, filters, opts \\ []) do
    started = Bench.now()
    Process.put(:pull_run, run)
    root = Instance.root()
    cache = opts[:cache] || System.get_env("PULL_E2E_CACHE") || Prepare.default_cache()
    Prepare.ready!(cache)
    artifacts = artifacts(run)
    File.mkdir_p!(artifacts)

    scenarios = Scenario.load(@scenarios, filters)
    if scenarios == [], do: raise("pull-e2e: no scenario matches #{Enum.join(filters, " ")}")
    own = Bench.own()
    # The bench itself, as bench_pid: the reaper never signals it (F1).
    Bench.record(run, "bench", %{bench_pid: own.pid, own_pgid: own.pgid})

    watchdog =
      Bench.watchdog(started + @watchdog_s * 1000, fn ->
        IO.puts(
          "\npull-e2e: the watchdog fired at #{@watchdog_s} s (an upper bound; see the durations)"
        )

        Bench.keep(run, artifacts, "watchdog", "the watchdog fired at #{@watchdog_s} s\n")
        status = watchdog_status(Bench.reap(run, fast: true, own_pgid: own.pgid))

        if status == 5,
          do: IO.puts("pull-e2e: LEAK: the reap's proof found what was left (table above)")

        System.halt(status)
      end)

    {:ok, _} = Hub.start_link(log: Path.join(run, "events"))
    IO.puts("pull-e2e: run #{run}, scenarios #{Enum.map_join(scenarios, " ", & &1.id)}")

    {outcome, ctx} =
      case guard(fn ->
             Bench.within("setup", 900, fn -> setup(run, root, cache, scenarios, own) end)
           end) do
        {:ok, ctx} ->
          Bench.duration(run, :phase, "setup", Bench.now() - started)
          {scenarios(ctx, scenarios, artifacts), ctx}

        {:error, kind, reason, stack} ->
          text = Exception.format(kind, reason, stack)
          IO.puts("pull-e2e: setup failed\n" <> text)
          Bench.keep(run, artifacts, "setup", text)
          {{:failed, "setup", verdict(reason)}, nil}
      end

    teardown_started = Bench.now()
    teardown(ctx)
    reap = Bench.reap(run, fast: false, own_pgid: own.pgid)
    Bench.cancel(watchdog)
    Bench.duration(run, :phase, "teardown", Bench.now() - teardown_started)
    total = Bench.now() - started
    Bench.duration(run, :phase, "total", total)
    summary(run, cache, artifacts, total)

    status =
      case {reap, outcome} do
        {{:error, _}, _} -> 5
        {_, {:failed, _, :too_slow}} -> 4
        {_, {:failed, _, _}} -> 1
        {_, {:incomplete, _}} -> 6
        {_, :passed} -> 0
      end

    if status == 5 do
      IO.puts("pull-e2e: LEAK: the reap's proof found what was left (table above)")
      Bench.keep(run, artifacts, "reap", "the reap's proof found what was left (table above)\n")
    end

    # Whatever the verdict, the run folder goes; what is worth reading was kept first.
    File.rm_rf!(run)
    IO.puts("pull-e2e: #{verdict_text(outcome)}; exit #{status}")
    status
  end

  defp verdict(%Scenario.TooSlow{}), do: :too_slow
  defp verdict(_), do: :failed

  defp verdict_text(:passed), do: "every scenario passed"

  defp verdict_text({:incomplete, needs}),
    do:
      "INCOMPLETE: not run for a missing package: #{Enum.map_join(needs, ", ", fn {id, n} -> "#{id} needs #{n}" end)}"

  defp verdict_text({:failed, id, :too_slow}),
    do: "#{id}: environment_too_slow (not a product failure)"

  defp verdict_text({:failed, id, _}), do: "#{id} FAILED"

  # ---- setup --------------------------------------------------------------------------

  defp setup(run, root, cache, scenarios, own) do
    needs = Needs.modules(scenarios)
    {:ok, host} = :inet.gethostname()
    hostname = to_string(host)
    bin = Path.join(run, "bin")
    File.mkdir_p!(bin)

    # The warm builds, copied into the run (so every process of it names <run>).
    stub = Path.join(bin, "pull-stub")
    cli = Path.join(bin, "atlas-runtime")
    File.cp!(Prepare.stub(cache), stub)
    File.cp!(Prepare.cli(cache), cli)
    File.chmod!(stub, 0o755)
    File.chmod!(cli, 0o755)

    git_env = git_env(run)

    fixture =
      Bench.within("fixture remote", 10, fn ->
        Fixture.remote!(Path.join(run, "remote/atlas.git"), git_env)
      end)

    [ws_port, edge_port] = Instance.free_ports(2)
    tls = Fixture.tls()
    base = %{run: run, root: root, ws_port: ws_port, remote_url: fixture.url, hostname: hostname}

    extra =
      Needs.fold(needs, :settings, 1, Core.extra(base), fn m, acc ->
        Instance.deep_merge(acc, m.settings(base))
      end)

    instance = Core.prepare(run, extra)

    ids = scenarios |> Enum.flat_map(& &1.subjects) |> Enum.uniq()
    subjects = Seed.plan(ids)
    rela = Facts.url(instance)

    Bench.within("rela and the seed", 60, fn ->
      Core.start_rela(run, instance)
      Seed.write!(rela, subjects)
    end)

    ctx0 = %{
      run: run,
      root: root,
      hostname: hostname,
      instance: instance,
      rela: rela,
      fixture: fixture,
      own: own,
      needs: needs
    }

    # The Runtime home first: its token is the credential the core is started with.
    rt =
      Runtime.prepare(run, :rt,
        edge_port: edge_port,
        ca_pem: tls.root_pem,
        cli: cli,
        stub: stub,
        build: Prepare.service_build(cache),
        policy: fn p -> Needs.fold(needs, :policy, 2, p, fn m, acc -> m.policy(acc, ctx0) end) end,
        path: Needs.fold(needs, :path, 1, [], fn m, acc -> acc ++ m.path(ctx0) end)
      )

    Bench.within("core start (adrienne's credential)", 160, fn ->
      Core.restart(run, instance, Core.credentials(hostname, "adrienne", rt.token))
    end)

    Bench.within("persons", 60, fn ->
      Core.person!(run, instance, "Melle")
      Core.person!(run, instance, "Adrienne")
    end)

    {:ok, edge} = Edge.start_link(port: edge_port, upstream: {{127, 0, 0, 1}, ws_port}, tls: tls)
    Bench.started("edge", fn -> Edge.stop(edge) end)
    Bench.record(run, "listen", %{port: edge_port, name: "edge"})

    _reader = Stub.events!(run, stub: stub)

    # One start, from the warm build (Main's ruling: no warm-up stop and restart; S4's
    # restart is the warm one).
    rt = Bench.within("Runtime start (warm build)", 90, fn -> Runtime.start(rt) end)
    rt = Runtime.follow(rt)

    console =
      Bench.within("TUI", 30, fn ->
        c = Console.start(run, instance)
        Console.ready(c)
        c
      end)

    ctx =
      Map.merge(ctx0, %{
        edge: edge,
        rt: rt,
        console: console,
        subjects: subjects,
        d2?: Needs.present?(:d2, root),
        results: Path.join(run, "results"),
        incarnation0: rt.incarnation,
        lease_ttl: Core.lease_ttl(),
        ws_port: ws_port,
        base: base
      })

    ctx = Needs.fold(needs, :start, 1, ctx, fn m, acc -> m.start(acc) end)

    Bench.within("ready", 30, fn ->
      Steps.ready(ctx, 0)

      Scenario.check!(
        is_binary(rt.incarnation),
        "service status gives an incarnation",
        rt.incarnation
      )
    end)

    IO.puts(
      "pull-e2e: ready; D2 #{if ctx.d2?, do: "present", else: "absent: S2/S2b report needs D2"}"
    )

    ctx
  end

  defp git_env(run) do
    dir = Path.join(run, "git")
    File.mkdir_p!(dir)
    file = Path.join(dir, "gitconfig")

    File.write!(
      file,
      "[init]\n\ttemplateDir =\n[core]\n\texcludesFile = /dev/null\n\tattributesFile = /dev/null\n"
    )

    System.put_env("GIT_CONFIG_GLOBAL", file)
    System.put_env("GIT_CONFIG_NOSYSTEM", "1")
    [{"GIT_CONFIG_GLOBAL", file}, {"GIT_CONFIG_NOSYSTEM", "1"}]
  end

  # ---- scenarios ----------------------------------------------------------------------

  defp scenarios(ctx, scenarios, artifacts) do
    Enum.reduce_while(scenarios, {:passed, [], ctx}, fn scenario, {:passed, needs, ctx} ->
      case Needs.missing(scenario.requires, ctx.root) do
        [] ->
          IO.puts(
            "\n#{scenario.id} #{scenario.title}  (#{Path.relative_to(scenario.file, ctx.root)})"
          )

          started = Bench.now()
          result = guard(fn -> scenario.run.(ctx) end)
          took = Bench.now() - started
          Bench.duration(ctx.run, :scenario, scenario.id, took)

          case result do
            {:ok, value} ->
              IO.puts("  #{scenario.id} passed in #{Float.round(took / 1000, 1)} s")

              # A scenario that changes the run hands on its context (F11): S4 the restarted
              # Runtime, S3 the core's new lease_ttl.
              ctx = if is_map(value) and Map.has_key?(value, :rt), do: value, else: ctx
              {:cont, {:passed, needs, ctx}}

            {:error, kind, reason, stack} ->
              text = Exception.format(kind, reason, stack)
              IO.puts("  #{scenario.id} failed after #{Float.round(took / 1000, 1)} s\n" <> text)
              File.write!(Path.join(ctx.run, "screen.txt"), safe_screen(ctx))
              Bench.keep(ctx.run, artifacts, scenario.id, text)
              {:halt, {{:failed, scenario.id, verdict(reason)}, needs, ctx}}
          end

        missing ->
          for {_, name, what} <- missing,
              do: IO.puts("\n#{scenario.id} #{scenario.title}: needs #{name} (#{what}); not run")

          Bench.duration(ctx.run, :scenario, scenario.id, 0)

          {:cont,
           {:passed, needs ++ Enum.map(missing, fn {_, name, _} -> {scenario.id, name} end), ctx}}
      end
    end)
    |> case do
      {:passed, [], _} -> :passed
      {:passed, needs, _} -> {:incomplete, needs}
      {failed, _, _} -> failed
    end
  end

  defp safe_screen(ctx) do
    Console.screen(ctx.console)
  rescue
    _ -> ""
  catch
    _, _ -> ""
  end

  # ---- teardown -----------------------------------------------------------------------

  @doc false
  # Before the reap, on every outcome: the needs' stops (with a context: setup passed), then
  # all the run tied to itself as it started (`Bench.started/2`: the readers, the TUI's tmux
  # server, the edge), the last started first, also when setup failed (`ctx` nil).
  def teardown(ctx) do
    needs =
      if ctx do
        case guard(fn -> Needs.fold(ctx.needs, :stop, 1, :ok, fn m, _ -> m.stop(ctx) end) end) do
          {:ok, _} ->
            [{"needs", :ok}]

          {:error, kind, reason, _} ->
            [{"needs", {:error, Exception.format_banner(kind, reason)}}]
        end
      else
        []
      end

    stopped = needs ++ Bench.stop_started()

    for {what, {:error, banner}} <- stopped,
        do: IO.puts("pull-e2e: stopping #{what}: #{banner}")

    stopped
  end

  defp summary(run, cache, artifacts, total) do
    lines =
      case File.read(Path.join(run, "durations.jsonl")) do
        {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
        _ -> []
      end

    compile = Prepare.measured(cache)

    File.write!(
      Path.join(artifacts, "durations.json"),
      JSON.encode!(%{compile: compile, test: lines, test_total_ms: total})
    )

    IO.puts("\npull-e2e durations (measured)")
    IO.puts("  compile (prepare, before the timed run): #{secs(compile["total_ms"])}")
    for %{"name" => n, "ms" => ms} <- compile["steps"], do: IO.puts("    #{n}: #{secs(ms)}")
    IO.puts("  test (this run):")

    for %{"kind" => kind, "name" => name, "ms" => ms} <- lines, kind in ["phase", "scenario"] do
      IO.puts("    #{kind} #{name}: #{secs(ms)}")
    end

    IO.puts("  test total: #{secs(total)} (upper bound #{@watchdog_s} s)")
  end

  defp secs(nil), do: "-"
  defp secs(ms), do: "#{Float.round(ms / 1000, 1)} s"
end

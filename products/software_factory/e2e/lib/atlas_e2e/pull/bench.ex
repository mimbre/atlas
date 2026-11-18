defmodule AtlasE2E.Pull.Bench do
  @moduledoc """
  The pull-e2e's bench: the run folder, the pid registry, step budgets, bounded commands,
  the watchdog and the reaper with its proof (plan rev 2 §4, §10; review round 1 F1, F2,
  F4–F6).

  **The run folder** `<run>` is made by the wrapper (`pull/run.sh`), short and resolved
  (`/tmp` → `/private/tmp`). Everything of the run is under it; the test BEAM runs with
  `TMPDIR=<run>/tmp`.

  **The registry** `<run>/pids.jsonl`: one JSON line per thing started, written as soon as
  its pid is known (`record/3`), with the process's start time (`lstart`, from `ps`) and
  its group leader's (`leader_lstart`): every session (`session/5`), each Runtime group,
  each core pid (re-read after every restart), rela, each stub, the Port readers, the tmux
  server, the listening ports, and what the graceful stops need. The bench itself is
  recorded as `bench_pid`, never as a `pid`: nothing of the reaper ever signals it. `reap/2`
  reads the registry back, so `mix atlas.pull_e2e --reap <run>` works from another BEAM.

  **Never a stranger's process (F6).** The mini is shared and the run is long, so a
  recorded pid or pgid may belong to someone else by the time of the reap. A pid is
  signalled only while `ps` shows it with the start time recorded for it; a group only while
  its leader does, or, once its leader has ended, member by member, each started after it.

  **Bounded commands (F5).** `session/5` (recorded, a session of its own) and `bounded/3`
  (not recorded) end a command at its step's deadline: its group is KILLed. Both are
  tethered (`pull-stub session|tether`): if this BEAM ends however it ends, the stub sees its
  stdin end and KILLs the command's group, so nothing outlives the bench. `within/3` fails
  a step that ran over its budget even when nothing in it waited.

  **The reaper** (`reap/2`): graceful stops unless `fast: true`, each bounded (Runtime stop
  60 s, a gate 10 s, tmux 10 s, `atlas-ops stop` 30 s); forced KILLs (always, checked as
  above; never the bench's own pgid: `kill_group/3`); then the **proof**: no recorded process
  of the run is alive, no process's command line holds `<run>`, no process is in a recorded
  group, every recorded port refuses, the tmux socket is gone. What the proof finds is
  killed and fails the reap (`{:error, table}`, exit 5).
  """
  require Logger

  @registry "pids.jsonl"
  @default_step_ms 30_000
  @graceful_ms %{runtime: 60_000, gate: 10_000, tmux: 10_000, ops: 30_000}

  defmodule OverBudget do
    defexception [:message]
  end

  # ---- the run ------------------------------------------------------------------------

  def me, do: String.to_integer(to_string(:os.getpid()))

  @doc "The bench's own OS pid and pgid (read once with `ps`), for the self-kill guard."
  def own(opts \\ []) do
    pid = me()
    ps = opts[:ps] || (&ps/0)

    pgid =
      opts[:own_pgid] ||
        Enum.find_value(ps.(), fn line -> line.pid == pid && line.pgid end) ||
        raise "the bench cannot read its own pgid (ps -A -o pid=,pgid=,…)"

    %{pid: pid, pgid: pgid}
  end

  def path(run, name), do: Path.join(run, name)

  # ---- registry -----------------------------------------------------------------------

  @doc """
  Append one registry line: `what` and its attributes (`pid`, `pgid`, `session`, …). A
  `pid` gets its start time (`lstart`) and a `pgid` its leader's (`leader_lstart`) from
  `ps` unless given (`opts[:lstart]` looks them up; tests pass them).
  """
  def record(run, what, attrs \\ %{}, opts \\ []) do
    lookup = opts[:lstart] || (&lstart/1)
    line = Map.new(attrs, fn {k, v} -> {to_string(k), v} end) |> Map.put("what", to_string(what))

    line =
      case line do
        %{"pid" => pid} when is_integer(pid) ->
          Map.put_new_lazy(line, "lstart", fn -> lookup.(pid) end)

        _ ->
          line
      end

    line =
      case line do
        %{"pgid" => pgid, "pid" => pgid} ->
          Map.put_new(line, "leader_lstart", line["lstart"])

        %{"pgid" => pgid} when is_integer(pgid) ->
          Map.put_new_lazy(line, "leader_lstart", fn -> lookup.(pgid) end)

        _ ->
          line
      end

    File.write!(path(run, @registry), JSON.encode!(line) <> "\n", [:append])
    line
  end

  def registry(run) do
    case File.read(path(run, @registry)) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      {:error, :enoent} -> []
    end
  end

  @doc "A process's start time as `ps` prints it (`lstart`), or nil."
  def lstart(pid) do
    case System.cmd("ps", ["-o", "lstart=", "-p", "#{pid}"], stderr_to_stdout: true) do
      {out, 0} ->
        out |> String.split() |> Enum.join(" ") |> then(&if(&1 == "", do: nil, else: &1))

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  # ---- step budgets -------------------------------------------------------------------

  @doc """
  Run `fun` as the step `name` with a budget of `seconds`: every wait inside is capped at
  what is left, and a step that took longer than its budget fails (`OverBudget`), whatever
  it did. Prints the step's measured duration and records it in `<run>/durations.jsonl`.
  """
  def within(name, seconds, fun, opts \\ []) do
    clock = opts[:clock] || (&now/0)
    outer = Process.get(:pull_deadline)
    started = clock.()
    Process.put(:pull_deadline, started + seconds * 1000)
    Process.put(:pull_step, name)

    try do
      result = fun.()
      took = clock.() - started
      if run = Process.get(:pull_run), do: duration(run, :step, name, took)

      if took > seconds * 1000,
        do: raise(OverBudget, message: "#{name} took #{took} ms, over its budget of #{seconds} s")

      IO.puts("    ✓ #{name} (#{Float.round(took / 1000, 1)} s of #{seconds} s)")
      result
    rescue
      error ->
        IO.puts("    ✗ #{name} after #{Float.round((clock.() - started) / 1000, 1)} s")
        reraise error, __STACKTRACE__
    after
      if outer, do: Process.put(:pull_deadline, outer), else: Process.delete(:pull_deadline)
    end
  end

  @doc "What is left of the current step's budget, in ms (at least 1)."
  def remaining do
    case Process.get(:pull_deadline) do
      nil -> @default_step_ms
      deadline -> max(deadline - now(), 1)
    end
  end

  @doc "Append a measured duration (ms) to `<run>/durations.jsonl`."
  def duration(run, kind, name, ms) do
    line = JSON.encode!(%{kind: kind, name: name, ms: ms})
    File.write!(path(run, "durations.jsonl"), line <> "\n", [:append])
  end

  def now, do: System.monotonic_time(:millisecond)

  # ---- bounded external commands ------------------------------------------------------

  @doc """
  Run `command args` as `pull-stub session -- command args`: a new session, so its pgid
  is its own and never the bench's, and tethered to this BEAM. The session is recorded as
  `what` the moment its first line names it. Returns `{output, status}` when it exits; at
  the deadline (the step's, or `within:` ms, or `deadline:` monotonic ms) its group is
  KILLed and it raises (`on_deadline: :return` gives `{output, :timeout}`).
  """
  def session(run, what, command, args, opts \\ []) do
    stub = opts[:stub] || path(run, "bin/pull-stub")
    deadline = deadline(opts)

    port =
      Port.open({:spawn_executable, stub}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 65_536},
        {:args, ["session", "--", executable(command) | args]},
        {:env, env(opts[:env])},
        {:cd, opts[:cd] || File.cwd!()}
      ])

    collect(%{
      run: run,
      what: what,
      port: port,
      session: nil,
      tethered?: true,
      acc: [],
      deadline: deadline,
      record?: true,
      opts: opts
    })
  end

  @doc """
  Run `command args` bounded, not recorded (a build before the run, a graceful stop, a
  person's `atlas put`): tethered through `opts[:stub]` when given, else a plain Port child
  (in OTP 28 a session of its own). At the deadline its group is KILLed; the answer is
  `{output, :timeout}` (or a raise with `on_deadline: :raise`).
  """
  def bounded(command, args, opts \\ []) do
    {exe, args} =
      if stub = opts[:stub],
        do: {stub, ["tether", "--", executable(command) | args]},
        else: {executable(command), args}

    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 65_536},
        {:args, args},
        {:env, env(opts[:env])},
        {:cd, opts[:cd] || File.cwd!()}
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)

    collect(%{
      run: nil,
      what: opts[:what] || Path.basename(command),
      port: port,
      session: pid,
      tethered?: opts[:stub] != nil,
      acc: [],
      deadline: deadline(opts),
      record?: false,
      opts: Keyword.put_new(opts, :on_deadline, :return)
    })
  end

  defp deadline(opts), do: opts[:deadline] || now() + (opts[:within] || remaining())

  defp executable(command) do
    if String.contains?(command, "/"),
      do: command,
      else: System.find_executable(command) || command
  end

  defp env(nil), do: []

  defp env(pairs),
    do:
      Enum.map(pairs, fn {k, v} ->
        {String.to_charlist(k), if(v, do: String.to_charlist(v), else: false)}
      end)

  defp collect(%{port: port} = c) do
    receive do
      {^port, {:data, {:eol, line}}} when c.record? and c.session == nil ->
        case JSON.decode(line) do
          {:ok, %{"session" => pid}} ->
            record(c.run, c.what, %{pid: pid, pgid: pid, session: true}, c.opts)
            collect(%{c | session: pid})

          _ ->
            collect(%{c | acc: [line | c.acc]})
        end

      {^port, {:data, {:eol, line}}} ->
        collect(%{c | acc: [line | c.acc]})

      {^port, {:data, {:noeol, part}}} ->
        collect(%{c | acc: [part | c.acc]})

      {^port, {:exit_status, status}} ->
        {output(c), status}

      # Now, as at the deadline (a cancel; tests end a command without waiting for time).
      :pull_deadline ->
        expire(c)
    after
      max(c.deadline - now(), 0) ->
        expire(c)
    end
  end

  defp expire(%{port: port} = c) do
    cond do
      # A session's command: its own session, known once its line came.
      c.record? and c.session -> signal(-c.session, "KILL")
      # A tethered command: the tether KILLs its group when the Port closes (below);
      # signalling the tether first would leave the command behind.
      c.tethered? -> :ok
      # A plain Port child: a session of its own (OTP 28).
      true -> signal(-c.session, "KILL") || signal(c.session, "KILL")
    end

    # The Port may have ended meanwhile (its exit_status still queued).
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    if c.opts[:on_deadline] == :return,
      do: {output(c), :timeout},
      else: raise("#{c.what} did not end within its budget:\n" <> output(c))
  end

  defp output(c), do: c.acc |> Enum.reverse() |> Enum.join("\n")

  # ---- signals and processes ------------------------------------------------------------

  @doc "`kill -s SIG -- target` (a negative target is a group); true when it was delivered."
  def signal(target, sig \\ "KILL") do
    {_, status} =
      System.cmd("/bin/sh", ["-c", ~s(kill -s "$0" -- "$1" 2>/dev/null), sig, "#{target}"])

    status == 0
  end

  @doc "KILL the group `pgid`, unless it is the bench's own (`{:error, :own_pgid}`)."
  def kill_group(pgid, own_pgid, kill \\ &signal/2) do
    cond do
      not is_integer(pgid) or pgid <= 1 -> {:error, :invalid}
      pgid == own_pgid -> {:error, :own_pgid}
      true -> {:ok, kill.(-pgid, "KILL")}
    end
  end

  @doc "Whether `pid` runs: `ps` shows it, not a zombie (and with start time `lstart`, when given)."
  def alive?(pid, lstart \\ nil, ps \\ &ps/0) do
    Enum.any?(
      ps.(),
      &(&1.pid == pid and not zombie?(&1) and (lstart == nil or &1.lstart == lstart))
    )
  end

  defp zombie?(line), do: String.starts_with?(line.stat, "Z")

  @doc """
  The process table, one map per process: `pid`, `ppid`, `pgid`, `stat`, `lstart` (its
  start time, as `ps` prints it) and `command` (`ps -A -o pid=,ppid=,pgid=,stat=,lstart=,command=`,
  the same on BSD and procps).
  """
  def ps do
    {out, 0} = System.cmd("ps", ["-A", "-o", "pid=,ppid=,pgid=,stat=,lstart=,command="])
    parse_ps(out)
  end

  def parse_ps(out) do
    for line <- String.split(out, "\n", trim: true),
        [pid, ppid, pgid, stat, d, m, day, t, y | rest] =
          String.split(String.trim(line), ~r/\s+/, parts: 10),
        match?({_, ""}, Integer.parse(pid)) do
      %{
        pid: String.to_integer(pid),
        ppid: String.to_integer(ppid),
        pgid: String.to_integer(pgid),
        stat: stat,
        lstart: Enum.join([d, m, day, t, y], " "),
        command: Enum.join(rest, " ")
      }
    end
  end

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  @doc "An `lstart` as a comparable tuple (`{y, m, d, h, min, s}`), or nil."
  def start_key(nil), do: nil

  def start_key(lstart) do
    with [_dow, mon, day, time, year] <- String.split(lstart),
         m when is_integer(m) <- Enum.find_index(@months, &(&1 == mon)),
         [h, mi, s] <- String.split(time, ":") do
      {String.to_integer(year), m + 1, String.to_integer(day), String.to_integer(h),
       String.to_integer(mi), String.to_integer(s)}
    else
      _ -> nil
    end
  end

  # ---- the watchdog ---------------------------------------------------------------------

  @doc """
  A process that runs `on_fire` at the monotonic time `deadline_ms` (the run's upper bound,
  5 100 s after the start): `on_fire` reaps (fast) and halts. `cancel/1` stops it.
  """
  def watchdog(deadline_ms, on_fire, clock \\ &now/0) do
    spawn(fn ->
      receive do
        :cancel -> :ok
      after
        max(deadline_ms - clock.(), 0) -> on_fire.()
      end
    end)
  end

  def cancel(watchdog), do: send(watchdog, :cancel)

  # ---- the reaper -----------------------------------------------------------------------

  @doc """
  Stop everything the registry names and prove it gone. Options: `fast:` (KILL only: no
  graceful stop), `own_pgid:`, and for tests `ps:` (the process table), `kill:`, `cmd:`
  (runs a graceful stop: `cmd.(what, command, args, env, within_ms)`), `budgets:` and
  `connect:`. Returns `{:ok, table}` or `{:error, table}`; it prints the table.
  """
  def reap(run, opts \\ []) do
    ps = opts[:ps] || (&ps/0)
    kill = opts[:kill] || (&signal/2)
    own_pgid = opts[:own_pgid] || own(ps: ps).pgid
    lines = registry(run)
    stub = path(run, "bin/pull-stub")
    stub = if File.exists?(stub), do: stub

    cmd =
      opts[:cmd] ||
        fn _what, command, args, env, within ->
          bounded(command, args, env: env, within: within, stub: stub)
        end

    table =
      if opts[:fast],
        do: [],
        else: graceful(lines, cmd, Map.merge(@graceful_ms, opts[:budgets] || %{}), [])

    {table, refused} = forced(lines, own_pgid, kill, ps.(), table)
    {table, leaks} = proof(run, lines, own_pgid, Keyword.merge(opts, ps: ps, kill: kill), table)

    print(table)
    if refused == [] and leaks == [], do: {:ok, table}, else: {:error, table}
  end

  # Graceful (normal path only): the Runtimes' `service stop --force`, a `fail` to every
  # stub's gate (one no agent waits at answers 3 at once), the tmux servers, then rela and
  # the core; each within its budget, and one that runs over is KILLed and noted.
  defp graceful(lines, cmd, budgets, table) do
    steps =
      for(
        %{"what" => "runtime_home"} = l <- lines,
        do:
          {"runtime #{l["name"]}", l["cli"], ["service", "stop", "--force"],
           [{"ATLAS_RUNTIME_HOME", l["home"]}], budgets.runtime}
      ) ++
        for(
          %{"what" => "stub", "gate" => gate} = l <- lines,
          is_binary(gate),
          File.exists?(gate),
          do: {"stub #{l["pid"]}", l["bin"], ["gate", gate, ~s({"cmd":"fail"})], [], budgets.gate}
        ) ++
        for(
          %{"what" => "tmux_socket", "socket" => s} <- lines,
          do: {"tmux", "tmux", ["-S", s, "kill-server"], [], budgets.tmux}
        ) ++
        for(
          %{"what" => "instance"} = l <- lines,
          do:
            {"core and rela", Path.join(l["root"], "bin/atlas-ops"),
             ["stop", "--rela", "--env", "test"],
             [{"ATLAS_ENV_FILE", l["file"]}, {"ATLAS_NO_UPDATE", "1"}], budgets.ops}
        )

    Enum.reduce(steps, table, fn {what, command, args, env, within}, table ->
      {_, status} = cmd.(what, command, args, env, within)

      note =
        if status == :timeout, do: "timed out after #{within} ms: KILLed", else: "exit #{status}"

      [
        %{
          what: what,
          pid: nil,
          pgid: nil,
          stopped_by: "#{Path.basename(command)} #{Enum.join(args, " ")} (#{note})",
          gone: nil
        }
        | table
      ]
    end)
  end

  @doc false
  # Whether the recorded process is still the one recorded: `ps` shows its pid with its start time.
  def ours?(table, pid, lstart),
    do:
      is_integer(pid) and lstart != nil and
        Enum.any?(table, &(&1.pid == pid and &1.lstart == lstart))

  @doc false
  # The processes of the recorded group `pgid` (leader started at `leader_lstart`) that are
  # still the run's: `{:group, members}` while its leader is (one KILL of the group),
  # `{:members, members}` once the leader has ended (each started after it), `{:not_ours, why}`.
  def group(table, pgid, leader_lstart) do
    members = Enum.filter(table, &(&1.pgid == pgid and not zombie?(&1)))
    leader = Enum.find(table, &(&1.pid == pgid))
    since = start_key(leader_lstart)

    cond do
      leader_lstart == nil -> {:not_ours, "no recorded start time: not verified, not signalled"}
      leader && leader.lstart == leader_lstart -> {:group, members}
      leader -> {:not_ours, "pid #{pgid} is another process now"}
      true -> {:members, Enum.filter(members, &(since != nil and start_key(&1.lstart) >= since))}
    end
  end

  defp forced(lines, own_pgid, kill, table_ps, table) do
    me = me()
    groups = lines |> Enum.filter(&is_integer(&1["pgid"])) |> Enum.uniq_by(& &1["pgid"])

    {table, refused} =
      Enum.reduce(groups, {table, []}, fn l, {table, refused} ->
        if l["pgid"] == own_pgid do
          {[row(l, "refused (own_pgid)") | table], [l | refused]}
        else
          case group(table_ps, l["pgid"], l["leader_lstart"]) do
            {:group, []} ->
              {[row(l, "group gone") | table], refused}

            {:group, _members} ->
              {:ok, _} = kill_group(l["pgid"], own_pgid, kill)
              {[row(l, "kill -KILL -#{l["pgid"]}") | table], refused}

            {:members, members} ->
              for m <- members, m.pid != me, do: kill.(m.pid, "KILL")

              {[
                 row(l, "leader gone; kill -KILL #{Enum.map_join(members, " ", & &1.pid)}")
                 | table
               ], refused}

            {:not_ours, why} ->
              {[row(l, why) | table], refused}
          end
        end
      end)

    table =
      for %{"what" => what, "pid" => pid} = l <- lines,
          is_integer(pid),
          pid != me,
          what in ~w(core rela tmux port stub),
          reduce: table do
        table ->
          if ours?(table_ps, pid, l["lstart"]) do
            if what == "core" do
              # Its children, by ppid, each started after it.
              since = start_key(l["lstart"])

              for c <- table_ps,
                  c.ppid == pid,
                  start_key(c.lstart) >= since,
                  do: kill.(c.pid, "KILL")
            end

            kill.(pid, "KILL")

            [
              row(
                l,
                if(what == "core", do: "kill -KILL its children, then it", else: "kill -KILL")
              )
              | table
            ]
          else
            [row(l, "gone (or another process now): not signalled") | table]
          end
      end

    {table, refused}
  end

  @doc false
  # The proof: nothing of the run is left. A process found is killed and reported.
  def proof(run, lines, own_pgid, opts, table) do
    ps = opts[:ps] || (&ps/0)
    kill = opts[:kill] || (&signal/2)
    connect = opts[:connect] || (&refuses?/1)
    table_ps = ps.()
    me = me()

    recorded =
      for %{"pid" => pid} = l <- lines,
          pid != me,
          l["what"] != "bench",
          Enum.any?(table_ps, &(&1.pid == pid and &1.lstart == l["lstart"] and not zombie?(&1))),
          l["lstart"] != nil do
        kill.(pid, "KILL")
        {row(l, "found alive by the proof: kill -KILL"), l}
      end

    ours =
      for %{"pgid" => g} = l <- lines, is_integer(g), g != own_pgid, uniq: true do
        case group(table_ps, g, l["leader_lstart"]) do
          {:group, members} -> Enum.map(members, & &1.pid)
          {:members, members} -> Enum.map(members, & &1.pid)
          {:not_ours, _} -> []
        end
      end
      |> List.flatten()
      |> MapSet.new()

    recorded_pids = MapSet.new(for {_, l} <- recorded, do: l["pid"])

    found =
      for line <- table_ps,
          line.pid != me,
          not zombie?(line),
          not MapSet.member?(recorded_pids, line.pid),
          String.contains?(line.command, run) or MapSet.member?(ours, line.pid) do
        kill.(line.pid, "KILL")

        why =
          if String.contains?(line.command, run),
            do: "holds the run folder",
            else: "in recorded pgid #{line.pgid}"

        {%{
           what: "leak: " <> String.slice(line.command, 0, 60),
           pid: line.pid,
           pgid: line.pgid,
           stopped_by: "found by the proof (#{why}): kill -KILL",
           gone: false
         }, %{"pid" => line.pid}}
      end

    ports =
      for %{"what" => "listen", "port" => port} = l <- lines, not connect.(port) do
        {%{
           what: "port #{port} (#{l["name"]})",
           pid: nil,
           pgid: nil,
           stopped_by: "still accepts",
           gone: false
         }, l}
      end

    sockets =
      for %{"what" => "tmux_socket", "socket" => s} = l <- lines, File.exists?(s) do
        File.rm(s)

        {%{
           what: "tmux socket #{s}",
           pid: nil,
           pgid: nil,
           stopped_by: "removed by the proof",
           gone: false
         }, l}
      end

    leaks = recorded ++ found ++ ports ++ sockets
    leaked = MapSet.new(for {_, l} <- leaks, pid = l["pid"], do: pid)

    table =
      Enum.map(table, fn
        %{pid: pid} = row when is_integer(pid) -> %{row | gone: not MapSet.member?(leaked, pid)}
        row -> %{row | gone: row.gone != false}
      end)

    {Enum.map(leaks, &elem(&1, 0)) ++ table, Enum.map(leaks, &elem(&1, 1))}
  end

  defp row(l, by),
    do: %{
      what: l["what"] <> if(l["name"], do: " " <> to_string(l["name"]), else: ""),
      pid: l["pid"],
      pgid: l["pgid"],
      stopped_by: by,
      gone: nil
    }

  @doc "Whether nothing accepts a connect on 127.0.0.1:`port`."
  def refuses?(port) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [], 2_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        false

      {:error, _} ->
        true
    end
  end

  defp print(table) do
    IO.puts("\n  what | pid | pgid | stopped by | confirmed gone")

    for row <- Enum.reverse(table) do
      IO.puts(
        "  #{row.what} | #{row.pid || "-"} | #{row.pgid || "-"} | #{row.stopped_by} | #{gone(row.gone)}"
      )
    end
  end

  defp gone(true), do: "yes"
  defp gone(false), do: "NO"
  defp gone(nil), do: "-"

  # ---- artifacts ----------------------------------------------------------------------

  @doc """
  Copy what a run leaves worth reading into `<artifacts>/<scenario>/` (git-ignored): the
  event logs (`wire.jsonl`, `stub.jsonl`, `rt.jsonl`, …), the Runtime's `service.log`, the
  core's and rela's logs, the registry, the durations, the S3 downtime, the last screen and
  `error.txt`.
  """
  def keep(run, artifacts, scenario, error_text) do
    dir = Path.join(artifacts, scenario)
    File.mkdir_p!(dir)

    files =
      Path.wildcard(Path.join(run, "events/*.jsonl")) ++
        Path.wildcard(Path.join(run, "rt/*/h/service.log")) ++
        Path.wildcard(Path.join(run, "inst/*.log")) ++
        Enum.filter(
          Enum.map(~w(pids.jsonl durations.jsonl downtime.json screen.txt), &path(run, &1)),
          &File.exists?/1
        )

    for file <- files do
      name = file |> Path.relative_to(run) |> String.replace("/", "_")
      File.cp(file, Path.join(dir, name))
    end

    File.write!(Path.join(dir, "error.txt"), error_text)
    dir
  end
end

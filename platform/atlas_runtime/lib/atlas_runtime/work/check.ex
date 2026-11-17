defmodule AtlasRuntime.Work.Check do
  @moduledoc """
  A work's after-check (design §3.10; s5a-plan B16–B19, B23, B24, B28, I-K5): a client-declared
  argv the native helper runs in the work's folder after the agent completed, always through
  `codex sandbox` with the turn's own permission profile, never unsandboxed.

  **Available** (`available?/0`, B23): `codex` is found on the core's own `PATH` as an
  absolute path. There is no cache: a `codex` installed later is picked up by the next
  submit, and the helper, started by the core with that same `PATH`, catches one removed
  since (`refused: sandbox_unavailable`).

  **Running** (`start/2`): a process of its own, never the Work server (F17), runs
  `atlas-runtime host check` (I-H3, as amended by the coordinator on 2026-11-17) as a Port:

      host check --cwd D (--scope JSON | --sandbox read-only) --scratch S --timeout SEC
                 --grace SEC --tail 16384 -- ARGV…

  with `ATLAS_RUNTIME_HOME` set and the core's environment otherwise. It tells its owner
  `{:check_started, pid, pgid}` once the helper reports `started`, and always ends with
  `{:check_ended, pid, result}`. `stop/2` writes `{"stop":"signal"}` or `{"stop":"kill"}` to
  the helper's stdin. If the owner dies, the Port is closed, so the helper's stdin ends and it
  stops the check's group itself (parent lost, B19).

  **Result** (a plain map: `exit_status`, `signal`, `error`, `timed_out`, `cancelled`,
  `duration_ms`, `output: %{tail, complete}`, `pgid`, `quiescent`) from the helper's lines:

  | Helper | Result |
  |---|---|
  | `ended` | as reported; `cancelled` = the helper's `stopped`; `quiescent` = `group_gone` (`false` keeps the scratch, I-H3 (a)) |
  | `refused{why}` (no `started`) | `error: why`, the B28 defaults, `quiescent: true` |
  | exit 1 after `started` without `ended` (I-H3 (c)) | `error: :helper_failed`, `exit_status: nil`, `quiescent: false` until a group-gone probe (`gone?/2`) confirms |
  | exit ≠ 0 before `started`: a setup error, `{"error": …}` on stderr (I-H3 (b)) | `error: :helper_failed`, `quiescent: true`: nothing was started |
  | silent past `timeout + 2 × grace + 60 s` | the helper is killed (SIGKILL); as exit 1, by whether it had started |

  `unavailable/0` is the result recorded without starting the helper when `codex` is gone at
  check time (§3.10 "fails closed"); `cancelled/0` the one recorded when a cancel was asked for
  before the check was due.
  """

  alias AtlasRuntime.Work.Folders

  @tail_bytes 16_384
  @errors %{
    "sandbox_unavailable" => :sandbox_unavailable,
    "leaves_folder" => :leaves_folder,
    "not_found" => :not_found
  }
  # The core's own bound on a silent helper, beyond the check's timeout and two graces.
  @slack_ms 60_000

  @doc "The tail the core asks for and records: at most 16 KiB (§3.10)."
  def tail_bytes, do: @tail_bytes

  @doc """
  The `codex` the helper will find: `System.find_executable/1` over the core's own `PATH`,
  only when it is an absolute path; nil otherwise (B23).
  """
  def codex do
    case System.find_executable("codex") do
      path when is_binary(path) -> if Path.type(path) == :absolute, do: path
      nil -> nil
    end
  end

  @doc "Whether an after-check can run now: `codex/0` found one. Never cached (B23)."
  def available?, do: codex() != nil

  @doc """
  The validation errors of an `after_check` at submit (B16), in order, as `{reason, detail}`
  or `:ok`: `command` has 1..64 strings of 1..4096 bytes without NUL; `command[0]` is a bare
  name or a folder-relative path (no leading `/`, no `..` segment); `timeout` (when given) is
  1..`max_timeout` seconds.
  """
  def validate(%{command: command, timeout: timeout}, max_timeout) do
    cond do
      not is_list(command) or command == [] or length(command) > 64 ->
        {:invalid, "after_check.command must hold 1 to 64 arguments"}

      not Enum.all?(command, &argument?/1) ->
        {:invalid, "after_check.command arguments must be 1 to 4096 bytes without NUL"}

      not program?(hd(command)) ->
        {:invalid,
         "after_check.command[0] must be a name on PATH or a path inside the folder " <>
           "(not absolute, no ..)"}

      timeout != nil and (not is_integer(timeout) or timeout < 1 or timeout > max_timeout) ->
        {:invalid, "after_check.timeout must be 1 to #{max_timeout} seconds"}

      true ->
        :ok
    end
  end

  defp argument?(text),
    do:
      is_binary(text) and byte_size(text) in 1..4096 and String.valid?(text) and
        not String.contains?(text, <<0>>)

  defp program?(name) do
    not String.starts_with?(name, "/") and ".." not in String.split(name, "/")
  end

  @doc "The scratch the core names for attempt `n` of `work_id` (B24): `<home>/scratch/check-<work_id>.<n>`."
  def scratch(home, work_id, n),
    do: Path.join([Folders.real(home), "scratch", "check-#{work_id}.#{n}"])

  @doc """
  The sandbox arguments of a turn, from its own record (`turn.json`): `{:scope, map}` for a
  `materialized-folder` scope, `{:sandbox, "read-only"}` for the read-only sandbox, or
  `:unsupported` for anything the helper's check cannot carry (B18: never a looser one).
  """
  def sandbox(%{"permissions" => %{"profile" => "materialized-folder"} = scope}),
    do: {:scope, scope}

  def sandbox(%{"sandbox" => "read-only"} = turn),
    do: if(is_nil(turn["permissions"]), do: {:sandbox, "read-only"}, else: :unsupported)

  def sandbox(_turn), do: :unsupported

  @doc "The result recorded without running anything (B28): `error` set, every other field its default."
  def refused(error) do
    %{
      exit_status: nil,
      signal: nil,
      error: error,
      timed_out: false,
      cancelled: false,
      duration_ms: 0,
      output: %{tail: "", complete: true},
      pgid: nil,
      quiescent: true
    }
  end

  @doc "`codex` was gone when the check was due: it was not run (§3.10)."
  def unavailable, do: refused(:sandbox_unavailable)

  @doc """
  A cancel was asked for before the check was due: it was not run, and is recorded as cancelled
  (§3.10, B20: a cancel stops only the check). No `error`; every other field the B28 default.
  """
  def cancelled, do: %{refused(nil) | cancelled: true}

  @doc """
  Starts the check: `{:ok, pid}`. `spec`: `home`, `cwd`, `sandbox` (`sandbox/1`), `scratch`,
  `timeout` and `grace` (seconds), `command`, and `helper` (`{executable, leading_args}`,
  default `$ATLAS_RUNTIME_EXECUTABLE` with none).
  """
  def start(spec, owner) do
    pid = spawn(fn -> run(spec, owner) end)
    {:ok, pid}
  end

  @doc "Asks the helper to stop the check's group: `:signal` (SIGINT) or `:kill` (SIGKILL)."
  def stop(pid, how) when how in [:signal, :kill] do
    send(pid, {:stop, how})
    :ok
  end

  @doc """
  Whether a check's process group is provably gone (I1): `probe.(pgid, started)` against the
  attempt's `check_pgid` and `check_started_at`, as the turn probe asks about a turn's leader.
  An attempt without a recorded group has none left.
  """
  def gone?(%{check_pgid: pgid} = attempt, probe) when is_integer(pgid) and pgid > 1 do
    started =
      case attempt.timestamps.check_started_at do
        %DateTime{} = at -> DateTime.to_unix(at)
        nil -> System.os_time(:second)
      end

    match?({:gone, _why}, probe.(pgid, started))
  end

  def gone?(_attempt, _probe), do: true

  ## The check's process

  defp run(spec, owner) do
    owner_ref = Process.monitor(owner)
    {executable, leading} = spec[:helper] || {System.fetch_env!("ATLAS_RUNTIME_EXECUTABLE"), []}
    File.mkdir_p!(Path.dirname(spec.scratch))
    File.chmod!(Path.dirname(spec.scratch), 0o700)

    sandbox =
      case spec.sandbox do
        {:scope, scope} -> ["--scope", JSON.encode!(scope)]
        {:sandbox, "read-only"} -> ["--sandbox", "read-only"]
      end

    args =
      leading ++
        ["host", "check", "--cwd", spec.cwd] ++
        sandbox ++
        ["--scratch", spec.scratch, "--timeout", Integer.to_string(spec.timeout)] ++
        ["--grace", Integer.to_string(spec.grace), "--tail", Integer.to_string(@tail_bytes)] ++
        ["--" | spec.command]

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: args,
        env: [{~c"ATLAS_RUNTIME_HOME", String.to_charlist(spec.home)}]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    bound = (spec.timeout + 2 * spec.grace) * 1000 + @slack_ms
    deadline = System.monotonic_time(:millisecond) + bound
    seen = %{started: nil, last: nil, buffer: ""}
    result = loop(port, os_pid, owner, owner_ref, deadline, seen)
    send(owner, {:check_ended, self(), result})
  end

  defp loop(port, os_pid, owner, owner_ref, deadline, seen) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        seen = lines(seen, data, owner)
        loop(port, os_pid, owner, owner_ref, deadline, seen)

      {^port, {:exit_status, status}} ->
        seen = lines(seen, "\n", owner)
        outcome(seen, status)

      {:stop, how} ->
        Port.command(port, JSON.encode!(%{"stop" => Atom.to_string(how)}) <> "\n")
        loop(port, os_pid, owner, owner_ref, deadline, seen)

      {:DOWN, ^owner_ref, :process, _, _} ->
        # Parent lost: the helper's stdin ends, so it stops the group itself (B19).
        Port.close(port)
        exit(:normal)
    after
      remaining ->
        System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
        Port.close(port)
        outcome(seen, :killed)
    end
  end

  # One JSON event per line; anything else (a setup error's text) is kept as the last line.
  defp lines(seen, data, owner) do
    {complete, rest} = split(seen.buffer <> data)

    Enum.reduce(complete, %{seen | buffer: rest}, fn line, seen ->
      case JSON.decode(line) do
        {:ok, %{"event" => "started", "pgid" => pgid}} when is_integer(pgid) ->
          send(owner, {:check_started, self(), pgid})
          %{seen | started: pgid}

        {:ok, %{"event" => event} = value} when event in ["ended", "refused"] ->
          %{seen | last: value}

        _ ->
          seen
      end
    end)
  end

  defp split(text) do
    parts = String.split(text, "\n")
    {Enum.reject(Enum.drop(parts, -1), &(&1 == "")), List.last(parts)}
  end

  defp outcome(%{last: %{"event" => "refused", "why" => why}}, _status)
       when is_map_key(@errors, why),
       do: refused(Map.fetch!(@errors, why))

  defp outcome(%{last: %{"event" => "ended"} = ended, started: pgid}, _status) do
    output = ended["output"] || %{}

    %{
      exit_status: integer(ended["exit_status"]),
      signal: if(is_binary(ended["signal"]), do: ended["signal"]),
      error: nil,
      timed_out: ended["timed_out"] == true,
      cancelled: ended["stopped"] == true,
      duration_ms: max(integer(ended["duration_ms"]) || 0, 0),
      output: %{
        tail: tail(output["tail"]),
        complete: output["complete"] == true and byte_size(output["tail"] || "") <= @tail_bytes
      },
      pgid: pgid,
      # group_gone false: the scratch is kept and the group not proven gone (I-H3 (a)).
      quiescent: ended["group_gone"] == true
    }
  end

  # No ended line: after started, the group may live on (I-H3 (c)); before it, nothing ran.
  defp outcome(%{started: pgid}, _status),
    do: %{refused(:helper_failed) | pgid: pgid, quiescent: is_nil(pgid)}

  defp integer(value) when is_integer(value), do: value
  defp integer(_), do: nil

  # At most 16 KiB, cut on a UTF-8 boundary from the front (the helper already cuts it).
  defp tail(text) when is_binary(text) and byte_size(text) > @tail_bytes,
    do: valid_suffix(binary_part(text, byte_size(text) - @tail_bytes, @tail_bytes))

  defp tail(text) when is_binary(text), do: valid_suffix(text)
  defp tail(_), do: ""

  defp valid_suffix(""), do: ""

  defp valid_suffix(text) do
    if String.valid?(text),
      do: text,
      else: valid_suffix(binary_part(text, 1, byte_size(text) - 1))
  end
end

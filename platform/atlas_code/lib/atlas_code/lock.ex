defmodule AtlasCode.Lock do
  @moduledoc """
  The OS lock on a Code home: an exclusive `flock(2)` on `<home>/service.lock`, held by a
  small `perl` process whose stdin is a pipe from this BEAM. The kernel drops the lock when
  that process ends, and it ends on its own when the pipe closes: when this BEAM exits for any
  reason (SIGKILL and OOM included), when the process watching the lock goes down, or on
  `release/1`. So a lock never outlives the BEAM that took it, and a held lock proves a live
  owner without `ps` or PIDs, which a restarted container may reuse.

  `perl` is part of every supported host: macOS ships it and Debian's `perl-base` is
  essential (in `debian:bookworm-slim`, the core image). The lock file is never removed.

  A holder process (unlinked from its caller, like `AtlasCode.Instance`) owns the port. It
  watches the process that took the lock until `watch/2` names another, e.g. the server.
  """

  @file_name "service.lock"
  # Opens (creating) the lock file, takes LOCK_EX without blocking (exit 1 when another holds
  # it), says so and holds it until stdin has a line or ends; the kernel releases it on exit.
  @helper """
  use strict; use Fcntl qw(:flock);
  open(my $f, ">>", $ARGV[0]) or exit 3;
  flock($f, LOCK_EX | LOCK_NB) or exit 1;
  $| = 1; print "locked\\n";
  my $b; while (sysread(STDIN, $b, 64)) { last if $b =~ /\\n/ }
  exit 0;
  """

  @doc "The lock file of `home`."
  def path(home), do: Path.join(home, @file_name)

  @doc """
  Takes the lock of `home` without waiting: `{:ok, lock}` (the holder's pid), `:busy` when
  another process holds it, or `{:error, reason}` when it cannot be tried.
  """
  def acquire(home) do
    case System.find_executable("perl") do
      nil ->
        {:error, :no_perl}

      perl ->
        caller = self()
        ref = make_ref()

        {holder, monitor} =
          spawn_monitor(fn -> hold(perl, path(home), caller, ref) end)

        receive do
          {^ref, :locked} ->
            Process.demonitor(monitor, [:flush])
            {:ok, holder}

          {^ref, other} ->
            Process.demonitor(monitor, [:flush])
            other

          {:DOWN, ^monitor, :process, ^holder, reason} ->
            {:error, reason}
        after
          10_000 ->
            Process.demonitor(monitor, [:flush])
            Process.exit(holder, :kill)
            {:error, :timeout}
        end
    end
  end

  @doc "Makes the lock follow `pid`: it is released when `pid` goes down."
  def watch(lock, pid) do
    call(lock, {:watch, pid})
  end

  @doc "Releases the lock and returns once the kernel has (the helper has exited)."
  def release(lock) do
    case call(lock, :release) do
      :ok -> :ok
      {:error, :noproc} -> :ok
    end
  end

  @doc "Whether `lock`'s holder (and so the lock) is still there."
  def held?(lock), do: Process.alive?(lock)

  defp call(lock, message) do
    ref = Process.monitor(lock)
    send(lock, {message, self(), ref})

    receive do
      {^ref, reply} ->
        Process.demonitor(ref, [:flush])
        reply

      {:DOWN, ^ref, :process, ^lock, _} ->
        {:error, :noproc}
    after
      15_000 ->
        Process.demonitor(ref, [:flush])
        {:error, :timeout}
    end
  end

  defp hold(perl, file, caller, ref) do
    port =
      Port.open({:spawn_executable, perl}, [
        :binary,
        :exit_status,
        {:line, 64},
        args: ["-e", @helper, file]
      ])

    receive do
      {^port, {:data, {:eol, "locked"}}} ->
        send(caller, {ref, :locked})
        loop(port, Process.monitor(caller))

      {^port, {:exit_status, 1}} ->
        send(caller, {ref, :busy})

      {^port, {:exit_status, status}} ->
        send(caller, {ref, {:error, {:exit_status, status}}})
    after
      10_000 ->
        Port.close(port)
        send(caller, {ref, {:error, :timeout}})
    end
  end

  defp loop(port, watching) do
    receive do
      {{:watch, pid}, from, ref} ->
        Process.demonitor(watching, [:flush])
        send(from, {ref, :ok})
        loop(port, Process.monitor(pid))

      {:release, from, ref} ->
        unlock(port)
        send(from, {ref, :ok})

      {:DOWN, ^watching, :process, _, _} ->
        unlock(port)

      {^port, {:exit_status, _}} ->
        # The helper ended (killed from outside): the lock is gone with it.
        :ok
    end
  end

  # Asks the helper to end and waits for it, so the lock is free when this returns.
  defp unlock(port) do
    Port.command(port, "release\n")

    receive do
      {^port, {:exit_status, _}} -> :ok
    after
      5_000 ->
        Port.close(port)
        :ok
    end
  catch
    :error, :badarg -> :ok
  end
end

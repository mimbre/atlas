defmodule AtlasRuntime.Upgrade do
  @moduledoc """
  The Runtime's side of an upgrade its supervisor started through Control (IS-Atlas-26):
  a work source serves it in its poll answer (`polled.upgrade`: `id`, `build`), and the
  source's puller hands it here. The Runtime upgrades itself in steps, kept in
  `upgrade.json` in its home so they outlast the restart, and every poll reports where it
  is (`report/1`, `poll_input.upgrade`):

  1. **draining**: the Runtime takes no new work (`AtlasRuntime.Work.set_mode/2`, drain:
     unstarted work goes back to its source) and waits until no slot is busy; the report
     names the busy slots, so Control shows what it waits for;
  2. **updating**: with no slot busy, it runs its own update command in the background
     (`atlas-runtime update --build BUILD --detach`, the binary it runs on), which refuses
     while a slot is busy or another update holds its lock, installs the released build,
     stops this Runtime and has its launch agent start it again;
  3. **restarted**: the Runtime the update started finds `upgrade.json` with another
     incarnation. On the served build it opens again (resume) and says so; the source
     verifies it (the build, a new incarnation, mode open, an offer) and ends the upgrade;
  4. **failed**: the update command failed (`update.json`) or the Runtime came back on
     another build: `failed_step` (`update` or `restart`) and `reason`, and the Runtime is
     opened again on the build it runs.

  Once the source no longer serves it after `restarted` or `failed`, `upgrade.json` goes.
  While `draining`, an answer without it (ended at the source, or the source could not
  read it) takes no step: the Runtime is not drained again nor updated, and goes on when
  it is served again; while `updating`, the restart is still taken. A served upgrade with another id starts again from draining. The
  upgrade is the source's that served it (`source`, its name): only that source's puller
  reports it and takes its steps, so another source's answers never end it.
  """

  require Logger

  alias AtlasRuntime.Work

  @file_name "upgrade.json"
  @by "upgrade"

  @steps %{
    "draining" => :draining,
    "updating" => :updating,
    "restarted" => :restarted,
    "failed" => :failed
  }
  @failed_steps %{"drain" => :drain, "update" => :update, "restart" => :restart}

  @doc """
  Where the Runtime is with the upgrade source `source` served, for that source's poll
  (`poll_input.upgrade`), or nil.
  """
  @spec report(Path.t() | nil, String.t()) :: map() | nil
  def report(nil, _source), do: nil

  def report(home, source) do
    with %{"id" => id, "step" => step, "source" => ^source} = kept <- read(home),
         %{} = runtime <- Work.runtime() do
      %{id: id, step: @steps[step], busy: busy(runtime), mode: runtime.mode}
      |> put(:failed_step, @failed_steps[kept["failed_step"]])
      |> put(:reason, kept["reason"])
    else
      _ -> nil
    end
  end

  @doc """
  One poll answer of source `source` and its upgrade (`order`, nil when it served none):
  takes the next step. Run outside the puller's own process; at most one at a time.
  """
  @spec served(Path.t(), String.t(), map() | nil) :: :ok
  def served(home, source, order) do
    order = order && Map.new(order, fn {key, value} -> {to_string(key), value} end)

    case {read(home), order, Work.runtime()} do
      {_, _, nil} ->
        :ok

      {nil, nil, _runtime} ->
        :ok

      # Another source's upgrade: only its own answers move it.
      {%{"source" => other}, _order, _runtime} when other != source ->
        :ok

      {%{"step" => step}, nil, _runtime} when step in ["restarted", "failed"] ->
        File.rm(path(home))
        :ok

      # Not served now (ended at the source, or the source could not read it): an update
      # under way still opens the Runtime after its restart; a drain takes no step.
      {%{"step" => "updating"} = kept, nil, runtime} ->
        step(home, kept, runtime)

      {_draining, nil, _runtime} ->
        :ok

      {%{"id" => id} = kept, %{"id" => id}, runtime} ->
        step(home, kept, runtime)

      {_other, %{"id" => id, "build" => build}, runtime}
      when is_binary(id) and is_binary(build) ->
        Logger.info("upgrade #{id}: to build #{build}, draining")
        kept = %{"id" => id, "build" => build, "step" => "draining", "source" => source}
        write(home, kept)
        step(home, kept, runtime)

      _invalid ->
        :ok
    end
  end

  defp step(home, %{"step" => "draining"} = kept, runtime) do
    if runtime.mode not in [:draining, :stopping], do: Work.set_mode(:draining, by(kept))

    case busy(runtime) do
      [] -> update(home, kept, runtime)
      _busy -> :ok
    end
  end

  defp step(home, %{"step" => "updating"} = kept, runtime) do
    cond do
      # The Runtime the update started.
      runtime.incarnation != kept["incarnation"] and runtime.runtime_build == kept["build"] ->
        Work.set_mode(:open, by(kept))
        Logger.info("upgrade #{kept["id"]}: restarted on build #{kept["build"]}, open")
        write(home, Map.put(kept, "step", "restarted"))

      runtime.incarnation != kept["incarnation"] ->
        fail(home, kept, "restart", "the Runtime came back on build #{runtime.runtime_build}")

      true ->
        case outcome(home) do
          %{"state" => "failed"} = failed ->
            fail(home, kept, failed_step(failed["step"]), failed["error"] || "update failed")

          %{"state" => "done", "result" => "current"} ->
            Work.set_mode(:open, by(kept))
            write(home, Map.put(kept, "step", "restarted"))

          _running ->
            :ok
        end
    end
  end

  defp step(_home, _restarted_or_failed, _runtime), do: :ok

  # No slot is busy: the update command, in the background (it stops this Runtime).
  defp update(home, kept, runtime) do
    File.rm(Path.join(home, "update.json"))

    case run_update(home, kept["build"]) do
      {:started, _printed} ->
        Logger.info("upgrade #{kept["id"]}: updating to build #{kept["build"]}")

        write(
          home,
          Map.merge(kept, %{"step" => "updating", "incarnation" => runtime.incarnation})
        )

      {:refused, %{"reason" => reason}} when reason in ["slot_busy", "update_running"] ->
        :ok

      {:refused, printed} ->
        fail(home, kept, "update", printed["error"] || "the update command refused")
    end
  end

  # The binary this Runtime runs on (`:update_command` in the application's environment
  # takes its place, for a test).
  defp run_update(home, build) do
    executable =
      Application.get_env(:atlas_runtime, :update_command) ||
        System.get_env("ATLAS_RUNTIME_EXECUTABLE")

    if is_binary(executable) and File.regular?(executable) do
      {output, status} =
        System.cmd(executable, ["update", "--build", build, "--detach"],
          env: [{"ATLAS_RUNTIME_HOME", home}],
          stderr_to_stdout: true
        )

      printed =
        case JSON.decode(output |> String.split("\n", trim: true) |> List.last() || "") do
          {:ok, %{} = printed} -> printed
          _ -> %{"error" => String.slice(output, 0, 500)}
        end

      if status == 0, do: {:started, printed}, else: {:refused, printed}
    else
      {:refused, %{"error" => "the Runtime does not know its atlas-runtime binary"}}
    end
  end

  defp fail(home, kept, failed_step, reason) do
    Logger.warning("upgrade #{kept["id"]}: failed at #{failed_step}: #{reason}")
    Work.set_mode(:open, by(kept))

    write(
      home,
      Map.merge(kept, %{
        "step" => "failed",
        "failed_step" => failed_step,
        "reason" => String.slice(scrub(reason, home), 0, 2_000)
      })
    )
  end

  # The update's steps, as the source's failed_step names them.
  defp failed_step("restart"), do: "restart"
  defp failed_step(_check_fetch_stop_or_install), do: "update"

  # A reason names no path of this machine.
  defp scrub(reason, home) do
    user = System.user_home() || "/nonexistent-home"

    reason
    |> String.replace(home, "<runtime home>")
    |> String.replace(user, "~")
  end

  defp busy(%{slots: slots}), do: for({name, true} <- slots, do: name) |> Enum.sort()

  defp by(kept), do: "#{@by}:#{kept["id"]}"

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp outcome(home) do
    with {:ok, data} <- File.read(Path.join(home, "update.json")),
         {:ok, %{} = outcome} <- JSON.decode(data) do
      outcome
    else
      _ -> nil
    end
  end

  defp path(home), do: Path.join(home, @file_name)

  defp read(home) do
    with {:ok, data} <- File.read(path(home)),
         {:ok, %{"id" => id, "build" => build, "step" => step, "source" => source} = kept}
         when is_binary(id) and is_binary(build) and is_binary(source) and
                is_map_key(@steps, step) <- JSON.decode(data) do
      kept
    else
      _ -> nil
    end
  end

  defp write(home, kept) do
    temporary = path(home) <> ".tmp"
    File.write!(temporary, JSON.encode!(kept))
    File.rename!(temporary, path(home))
  end
end

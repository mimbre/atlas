defmodule AtlasRuntime.Upgrade do
  @moduledoc """
  A supervised upgrade of this Runtime (IS-Atlas-26), as a work source orders it in a poll
  answer (`work_source` `polled.upgrade`: `id`, `build`, `action`), and what the puller
  reports of it with every poll while there is one (`poll_input.upgrade`).

  The orders:

    * `drain`: the mode `draining` (`AtlasRuntime.Work.set_mode/2`): no new work, the
      unstarted work returned, running turns finish;
    * `update`: once per upgrade, the update command in the background:
      `atlas-runtime service update --build BUILD --upgrade ID --detach` (the host CLI,
      `$ATLAS_RUNTIME_EXECUTABLE`). It takes the home's `update.lock` (refused while
      another update holds it), refuses while a slot is busy, installs the release,
      stops this Runtime and has its launch agent start it again; it records what it
      did in `update.json` in the home, which outlasts the restart;
    * `resume`: the mode `open` again, once the source saw the Runtime back.

  The report (`report/3`): the Runtime's mode, its busy slots, and `update.json` when it
  is of this upgrade (`update` none, running, refused, failed or installed, with its
  `step` and `reason`). After a restart the new puller has no order yet: `pending/1` names
  the upgrade `update.json` is of, so the first poll reports it.

  `update.json` is the update command's; the puller only reads it, and removes it once a
  source answers with no upgrade (the upgrade has ended) and no update is running.
  """

  require Logger

  alias AtlasRuntime.Work

  @record "update.json"
  @updates %{
    "running" => :running,
    "refused" => :refused,
    "failed" => :failed,
    "installed" => :installed
  }
  @steps %{"update" => :update, "restart" => :restart}

  @doc "The path of `update.json` in `home`."
  def path(home), do: Path.join(home, @record)

  @doc "What the update command recorded in `home` (string keys), or nil."
  def record(home) do
    with {:ok, text} <- File.read(path(home)),
         {:ok, %{"upgrade" => id} = record} when is_binary(id) <- JSON.decode(text) do
      record
    else
      _ -> nil
    end
  end

  @doc "The upgrade `update.json` in `home` is of, or nil."
  def pending(nil), do: nil

  def pending(home) do
    case record(home) do
      %{"upgrade" => id} when id != "" -> id
      _ -> nil
    end
  end

  @doc """
  The poll's report of upgrade `id`: `runtime` is `AtlasRuntime.Work.runtime/0`.
  """
  def report(home, runtime, id) do
    busy = for {slot, true} <- runtime.slots, do: slot

    base = %{id: id, mode: runtime.mode, busy: busy, update: :none}

    case home && record(home) do
      %{"upgrade" => ^id, "state" => state} = record when is_map_key(@updates, state) ->
        base
        |> Map.put(:update, Map.fetch!(@updates, state))
        |> put_step(record["step"])
        |> put_reason(record["reason"])

      _ ->
        base
    end
  end

  defp put_step(report, step) when is_map_key(@steps, step),
    do: Map.put(report, :step, Map.fetch!(@steps, step))

  defp put_step(report, _step), do: report

  defp put_reason(report, reason) when is_binary(reason) and reason != "",
    do: Map.put(report, :reason, String.slice(reason, 0, 2_000))

  defp put_reason(report, _reason), do: report

  @doc "An order as the answer carries it (atom or string keys and action), or nil."
  def order(order) when is_map(order) do
    get = fn key -> Map.get(order, key, Map.get(order, Atom.to_string(key))) end
    action = get.(:action)

    action =
      if is_binary(action),
        do: Enum.find([:drain, :update, :resume], &(Atom.to_string(&1) == action)),
        else: action

    with id when is_binary(id) and id != "" <- get.(:id),
         build when is_binary(build) and build != "" <- get.(:build),
         true <- action in [:drain, :update, :resume] do
      %{id: id, build: build, action: action}
    else
      _ -> nil
    end
  end

  def order(_order), do: nil

  @doc """
  Carries out `order` (`%{id, build, action}`) for source `source`. `opts`: `:spawn`, a
  function of `(executable, args, env)` that starts the update command (tests).
  """
  def handle(home, order, source, opts \\ [])

  def handle(_home, %{action: :drain, id: id}, source, _opts),
    do: mode(:draining, id, source)

  def handle(_home, %{action: :resume, id: id}, source, _opts),
    do: mode(:open, id, source)

  def handle(home, %{action: :update, id: id, build: build}, source, opts) when is_binary(home) do
    case record(home) do
      %{"upgrade" => ^id} ->
        # Started already for this upgrade: its record says how it went.
        :ok

      _ ->
        spawn = Keyword.get(opts, :spawn, &spawn_update/3)
        args = ["service", "update", "--build", build, "--upgrade", id, "--detach"]

        case spawn.(System.get_env("ATLAS_RUNTIME_EXECUTABLE"), args, [
               {"ATLAS_RUNTIME_HOME", home}
             ]) do
          :ok ->
            Logger.info("work source #{source}: upgrade #{id}: update to #{build} started")

          {:error, reason} ->
            Logger.warning("work source #{source}: upgrade #{id}: update not started: #{reason}")

            write(home, %{
              "upgrade" => id,
              "build" => build,
              "state" => "refused",
              "step" => "update",
              "reason" => reason
            })
        end
    end
  end

  def handle(_home, _order, _source, _opts), do: :ok

  @doc "The upgrade has ended at the source: forget `update.json`, unless an update runs."
  def ended(nil), do: :ok

  def ended(home) do
    case record(home) do
      %{"state" => "running"} ->
        :ok

      nil ->
        :ok

      _ended ->
        _ = File.rm(path(home))
        :ok
    end
  end

  defp mode(mode, id, source) do
    _ = Work.set_mode(mode, "upgrade #{id} (#{source})")
    :ok
  end

  # --detach returns once the command runs on its own, in its own session.
  defp spawn_update(nil, _args, _env), do: {:error, "ATLAS_RUNTIME_EXECUTABLE is not set"}

  defp spawn_update(executable, args, env) do
    case System.cmd(executable, args, env: env, stderr_to_stdout: true) do
      {_out, 0} ->
        :ok

      {out, status} ->
        {:error, "update command exited #{status}: #{String.slice(String.trim(out), 0, 500)}"}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp write(home, record) do
    tmp = path(home) <> ".tmp"
    File.write!(tmp, JSON.encode!(record))
    File.rename!(tmp, path(home))
  end
end

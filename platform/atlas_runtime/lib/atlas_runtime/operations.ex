defmodule AtlasRuntime.Operations do
  @moduledoc """
  The implementation behind `AtlasRuntime.Boundary.Operations` (design §13 S2, §13.1
  Q5–Q9, Q13): runtime info, the policy view, pause, resume and drain, stop, release of a
  slot and clearing a quota mark. The facade has checked the right and the input before any function here runs, and
  every answer is one of its declared outcome structs. Nothing starts it: it has no process.

  What a running Runtime decides (its mode and the persisted `mode.json`, its incarnation, which slots are busy, the
  stop, the release, the quota mark's write) is the work core's, `AtlasRuntime.Work`; the
  policy (`policy.json`) and the quota evidence (`availability.json`) are read on every
  call, so a hand edit shows at once.

  The contract declares no "not running" outcome. While the work core is not running,
  runtime info shows the work contract's stopped capacity (incarnation `stopped`, no
  slots), the policy view reads `$ATLAS_RUNTIME_HOME`, `stop` stops the Service directly,
  and `release_slot`/`clear_quota_mark` raise `NotRunning` rather than answer something
  untrue (OC review R2). `pause`, `resume` and `drain` then change nothing and answer
  runtime info.
  """
  use AtlasRuntime.Boundary.Operations.Implementation

  alias AtlasRuntime.{Availability, Policy, Work}
  alias AtlasRuntime.Boundary.Operations, as: F

  defmodule NotImplemented do
    @moduledoc "Raised by a skeleton capability: the contract is declared, its behaviour is not."
    defexception [:capability]

    @impl true
    def exception(capability), do: %__MODULE__{capability: capability}

    @impl true
    def message(%{capability: capability}), do: "#{capability} has no implementation yet"
  end

  defmodule NotRunning do
    @moduledoc "Raised when a capability needs the work core and it is not running."
    defexception [:capability]

    @impl true
    def exception(capability), do: %__MODULE__{capability: capability}

    @impl true
    def message(%{capability: capability}),
      do: "#{capability}: the Runtime's work core is not running"
  end

  @impl true
  def runtime_info(_client), do: struct!(F.Outcome.RuntimeInfo, info(Work.runtime()))

  @impl true
  def policy(_client), do: policy_view()

  # pause, resume and drain set the persisted mode through the work core (I-K, §13.1 Q5)
  # and answer the runtime info after it, also when the mode was already that one.
  @impl true
  def pause(client), do: change_mode(client, :paused)

  @impl true
  def resume(client), do: change_mode(client, :open)

  @impl true
  def drain(client), do: change_mode(client, :draining)

  @impl true
  def stop(client, %F.StopInput{force: force}), do: stopping(force == true, by(client))

  @impl true
  def release_slot(client, %F.ReleaseSlotInput{slot: slot}), do: release(slot, by(client))

  @impl true
  def clear_quota_mark(_client, %F.ClearQuotaMarkInput{harness: harness}), do: clear(harness)

  # Runtime info (Q13): build, incarnation and policy version as the work contract's
  # capacity shows them, the core's mode, and every slot the policy names (F1) with
  # whether it is busy.
  defp info(nil) do
    [
      runtime_build: AtlasRuntime.Provenance.context().runtime_build,
      incarnation: "stopped",
      mode: Work.mode(),
      policy_version: 0,
      slots: []
    ]
  end

  defp info(runtime) do
    [
      runtime_build: runtime.runtime_build,
      incarnation: runtime.incarnation,
      mode: runtime.mode,
      policy_version: runtime.policy_version,
      slots: for({name, busy} <- runtime.slots, do: %F.Slot{name: name, busy: busy})
    ]
  end

  # The declared view only (Q7), through `Outcome.Policy.new!/1`, which refuses any field the
  # contract does not declare.
  defp policy_view do
    home = home()
    loaded = if home, do: Policy.load(home), else: {:error, :missing}
    availability = if home, do: Availability.load(home), else: Availability.empty()

    loaded
    |> Policy.view(availability, &installed?/1, System.system_time(:second))
    |> F.Outcome.Policy.new!()
  end

  defp change_mode(client, mode) do
    _mode = Work.set_mode(mode, by(client))
    runtime_info(client)
  end

  # Stop (Q9): the core begins it once; a repeat answers the same.
  defp stopping(force, by) do
    :ok = Work.stop(force, by)
    struct!(F.Outcome.Stopping, Keyword.put(info(Work.runtime()), :mode, :stopping))
  end

  # Release (Q8): a slot the policy does not name is not found, and the core is not asked.
  defp release(slot, by) do
    case Work.runtime() do
      nil ->
        raise NotRunning, :release_slot

      %{slots: slots} ->
        if List.keymember?(slots, slot, 0),
          do: mark_released(slot, by),
          else: %F.Outcome.NotFound{}
    end
  end

  defp mark_released(slot, by) do
    case Work.mark_released(slot, by) do
      :released ->
        %F.Outcome.Released{slot: slot}

      :busy ->
        %F.Outcome.Refused{
          reason: :slot_busy,
          detail: "slot #{slot} still runs a process; release it once its end is confirmed"
        }

      :not_running ->
        raise NotRunning, :release_slot
    end
  end

  # An unmarked known harness is cleared too; only an unknown one is not found.
  defp clear(harness) do
    case Work.clear_quota_mark(harness) do
      answer when answer in [:cleared, :unmarked] -> %F.Outcome.Cleared{}
      :not_found -> %F.Outcome.NotFound{}
      :not_running -> raise NotRunning, :clear_quota_mark
    end
  end

  defp home do
    case Work.runtime() do
      %{home: home} -> home
      nil -> System.get_env("ATLAS_RUNTIME_HOME")
    end
  end

  defp installed?(harness), do: System.find_executable(harness) != nil

  defp by({id, _rights}), do: to_string(id)
end

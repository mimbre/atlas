defmodule AtlasFlow.WorkSource.Upgrade do
  @moduledoc """
  A supervised Runtime upgrade (IS-Atlas-26): its supervisor makes a `runtime_upgrade`
  fact under the Runtime's machinery (`upgrade_of`), naming the released build; Flow's
  work source moves it on, one poll of that Runtime at a time, and orders the Runtime
  what to do in the poll answer (`polled.upgrade`, `work_source` 0.5.0). The subflow
  `runtime_upgrade` (in the model) follows the `step` written here.

  On each poll of a Runtime, `poll/3` (run by `AtlasFlow.Delivery`) takes the oldest
  upgrade of its machinery that has not ended, and from its `step` and what the poll says
  (`build`, `incarnation`, `offer`, `holdings`, and `upgrade`: the Runtime's mode, its busy
  slots and what its update command recorded for this upgrade):

  | step | the poll says | written | ordered |
  |---|---|---|---|
  | requested | anything | `draining`, `from_build`, `from_incarnation` | drain |
  | draining, waiting | mode draining, a slot busy | `waiting`, `busy` | drain |
  | draining, waiting | mode draining, no slot busy | `updating` | update |
  | draining, waiting | not draining yet | | drain |
  | updating | a new incarnation on `build` | `verifying`, `incarnation` | resume |
  | updating | the update failed, or a different build restarted | `failed_step`, `reason` | recover old Runtime |
  | updating, recovering | confirmed old Runtime reports draining or paused | | resume |
  | updating, recovering | confirmed old Runtime reports open | `failed` | |
  | updating, recovering | identity or safety unknown | | wait |
  | verifying | mode open and slots offered, or work held | `done` | |
  | verifying | not open yet on the verified incarnation | | resume |

  Any other upgrade of the same machinery that has not ended is ended `failed` at `start`,
  naming the one in progress: one upgrade at a time (the composition's limit on
  `upgrade_of` already refuses it when it is made; this holds when that limit did not).

  A refused write (the fact changed meanwhile) is logged and the next poll works it out
  again; an order depending on a write is sent only after it is stored. Recovery is kept
  in `updating` or `verifying` with `failed_step` and `reason` until the old build is confirmed open;
  an unsafe or missing Runtime remains pending for its supervisor. A stored write calls
  `stored` with the upgrade's key so Delivery reconciles its run. If Facts is unreadable,
  an already-draining Runtime reporting a failed update is told to keep draining so even
  an older Runtime retains the report; other unknown cases receive no order.
  """

  require Logger

  alias AtlasFlow.Talk
  alias AtlasFlow.WorkSource.Translate

  # The kind, its relation and its fields (Model.RuntimeUpgrade), named here as
  # Configuration names the machinery's.
  @upgrade "runtime_upgrade"
  @of "upgrade_of"
  @ended ~w(done failed)

  @doc "The kind upgrades are kept in."
  def kind, do: @upgrade

  @doc "The relation from an upgrade to its machinery."
  def relation, do: @of

  @doc """
  One poll of Runtime `runtime_id` (`input` the poll's input, atom or string keys): moves
  its upgrade on, then `{:serve, %{id, build, action}}` or `:none`. `by` is the writer;
  `stored` is called with the key of each upgrade a write of it was stored on.
  """
  @spec poll(String.t(), map(), String.t(), (String.t() -> any())) :: {:serve, map()} | :none
  def poll(runtime_id, input, by \\ "flow", stored \\ fn _key -> :ok end)
      when is_binary(runtime_id) do
    input = Translate.normal(input)
    writer = {by, stored}

    case open(runtime_id) do
      {:ok, [current | others]} ->
        Enum.each(others, &refuse(&1, current, writer))
        step(current, input, writer)

      {:error, _reason} ->
        unavailable(input)

      :none ->
        :none
    end
  end

  # An older Runtime forgets a failed update after a no-order answer. Keep its
  # already-draining mode and report intact until Facts can record the failure.
  defp unavailable(%{
         "build" => build,
         "upgrade" => %{"id" => id, "mode" => "draining", "update" => update}
       })
       when is_binary(build) and build != "" and is_binary(id) and id != "" and
              update in ["refused", "failed"],
       do: {:serve, %{id: id, build: build, action: :drain}}

  defp unavailable(_input), do: :none

  defp step(fact, input, writer) do
    values = fact["values"]
    report = report(input, fact["key"])

    {changes, action} = next(values["step"] || "requested", values, input, report)
    recorded? = changes == %{} or record(fact, changes, writer)

    # Keep an old Runtime reporting a failed update if Facts is temporarily unavailable.
    action =
      if recorded? do
        action
      else
        cond do
          changes["step"] == "failed" and present?(values["failed_step"]) ->
            :resume

          values["step"] in ["updating", "verifying"] and failure?(report) and
            old_runtime?(values, input) and
              match?(%{"mode" => mode} when mode in ["open", "paused", "draining"], report) ->
            :drain

          true ->
            nil
        end
      end

    case action do
      nil -> :none
      action -> {:serve, %{id: fact["key"], build: values["build"], action: action}}
    end
  end

  # -- The steps ---------------------------------------------------------------------

  defp next("requested", _values, input, _report) do
    if present?(input["build"]) and present?(input["incarnation"]) do
      {%{
         "step" => "draining",
         "from_build" => input["build"],
         "from_incarnation" => input["incarnation"]
       }, :drain}
    else
      {%{}, nil}
    end
  end

  defp next(step, values, input, report) when step in ["draining", "waiting"] do
    if old_runtime?(values, input) and input["incarnation"] == values["from_incarnation"] do
      case report do
        %{"mode" => "draining", "busy" => [_ | _] = busy} ->
          {%{"step" => "waiting", "busy" => Enum.join(busy, ", ")}, :drain}

        %{"mode" => "draining", "busy" => []} ->
          {%{"step" => "updating", "busy" => ""}, :update}

        _ ->
          {%{}, :drain}
      end
    else
      {%{}, nil}
    end
  end

  defp next(state, %{"failed_step" => step} = values, input, report)
       when state in ["updating", "verifying"] and is_binary(step) and step != "" do
    recover(values, input, report)
  end

  defp next("updating", values, input, report) do
    restarted? =
      present?(values["from_incarnation"]) and present?(input["incarnation"]) and
        present?(input["build"]) and input["incarnation"] != values["from_incarnation"]

    cond do
      failure?(report) ->
        begin_recovery(values, input, report)

      restarted? and input["build"] == values["build"] ->
        {%{"step" => "verifying", "incarnation" => input["incarnation"]}, :resume}

      restarted? ->
        changes =
          failure(
            "restart",
            "the Runtime came back on build #{input["build"]}, not #{values["build"]}"
          )

        {changes, nil}

      old_runtime?(values, input) and input["incarnation"] == values["from_incarnation"] and
          match?(
            %{"mode" => "draining", "update" => update} when update in ["none", "running"],
            report
          ) ->
        {%{}, :update}

      true ->
        {%{}, nil}
    end
  end

  defp next("verifying", values, input, report) do
    accepts? = (input["offer"] || %{}) != %{} or (input["holdings"] || []) != []

    cond do
      failure?(report) ->
        begin_recovery(values, input, report)

      not present?(values["incarnation"]) or input["build"] != values["build"] or
          input["incarnation"] != values["incarnation"] ->
        {%{}, nil}

      match?(%{"mode" => "open"}, report) and accepts? ->
        {%{"step" => "done"}, nil}

      true ->
        {%{}, :resume}
    end
  end

  defp next(_ended_or_unknown, _values, _input, _report), do: {%{}, nil}

  defp begin_recovery(values, input, report) do
    failure = failure_fields(report)
    {recovery_changes, action} = recover(Map.merge(values, failure), input, report)

    if recovery_changes["step"] == "failed",
      do: {failure, :resume},
      else: {Map.merge(failure, recovery_changes), action}
  end

  defp failure(step, reason),
    do: %{"failed_step" => step, "reason" => String.slice(reason, 0, 2_000)}

  defp failure_fields(report) do
    failure(
      if(report["step"] in ["update", "restart"], do: report["step"], else: "unknown"),
      report["reason"] || "the update command #{report["update"]}"
    )
  end

  defp failure?(%{"update" => update}) when update in ["refused", "failed"], do: true
  defp failure?(_), do: false

  defp present?(value), do: is_binary(value) and value != ""

  defp old_runtime?(values, input) do
    present?(values["from_build"]) and present?(values["from_incarnation"]) and
      present?(input["incarnation"]) and input["build"] == values["from_build"]
  end

  defp recover(values, input, report) do
    safe? =
      old_runtime?(values, input) and
        (values["failed_step"] == "update" or
           (values["failed_step"] == "restart" and
              input["incarnation"] != values["from_incarnation"]))

    cond do
      not safe? ->
        {%{}, nil}

      match?(%{"update" => update} when update in ["running", "installed"], report) ->
        {%{}, nil}

      match?(%{"mode" => "open"}, report) ->
        {%{"step" => "failed"}, nil}

      match?(%{"mode" => mode} when mode in ["draining", "paused"], report) ->
        {%{}, :resume}

      is_nil(report) and is_nil(input["upgrade"]) ->
        {%{}, :drain}

      true ->
        {%{}, nil}
    end
  end

  # The poll's report of this upgrade, or nil (none, or of another upgrade).
  defp report(input, key) do
    case input["upgrade"] do
      %{"id" => ^key} = report -> Map.put_new(report, "busy", [])
      _ -> nil
    end
  end

  defp refuse(fact, current, writer) do
    record(
      fact,
      %{
        "step" => "failed",
        "failed_step" => "start",
        "reason" => "#{current["key"]} is in progress: one upgrade at a time"
      },
      writer
    )
  end

  # -- Facts -------------------------------------------------------------------------

  # The machinery's upgrades that have not ended, oldest first (by their number).
  defp open(runtime_id) do
    case Talk.read(@upgrade, %{"linked" => %{@of => runtime_id}, "plain" => true}) do
      %{"facts" => facts} when is_list(facts) ->
        open =
          facts
          |> Enum.filter(&(is_map(&1["values"]) and &1["values"]["step"] not in @ended))
          |> Enum.sort_by(&order/1)

        if open == [], do: :none, else: {:ok, open}

      other ->
        {:error, other}
    end
  end

  defp order(%{"key" => key}) do
    case Regex.run(~r/(\d+)$/, key) do
      [_, n] -> {String.to_integer(n), key}
      _ -> {0, key}
    end
  end

  defp record(fact, changes, {by, stored}) do
    values = fact["values"]
    changed = Map.filter(changes, fn {field, value} -> values[field] != value end)

    if changed == %{} do
      true
    else
      content = %{
        "op" => "change",
        "key" => fact["key"],
        "values" => changed,
        "version" => fact["version"],
        "was" => Map.new(Map.keys(changed), &{&1, values[&1]}),
        "by" => by
      }

      case Talk.put(@upgrade, content, digest([fact["key"], fact["version"], changed])) do
        {:stored, _position} ->
          Logger.info("flow work source: upgrade #{fact["key"]}: #{inspect(changed)}")
          stored.(fact["key"])
          true

        other ->
          Logger.warning(
            "flow work source: upgrade #{fact["key"]} not recorded: #{inspect(other)}"
          )

          false
      end
    end
  end

  defp digest(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)
end

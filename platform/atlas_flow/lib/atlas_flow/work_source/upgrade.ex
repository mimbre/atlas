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
  | updating | a new incarnation on another build | `failed` at restart | |
  | updating | the update command refused or failed | `failed` at its step | |
  | updating | the same incarnation | | update |
  | verifying | mode open and slots offered, or work held | `done` | |
  | verifying | not open yet | | resume |

  Any other upgrade of the same machinery that has not ended is ended `failed` at `start`,
  naming the one in progress: one upgrade at a time (the composition's limit on
  `upgrade_of` already refuses it when it is made; this holds when that limit did not).

  A refused write (the fact changed meanwhile) is logged and the next poll works it out
  again; every order is safe to repeat (the Runtime runs the update command once per
  upgrade). No machinery fact, no upgrade, or a Facts that does not answer: `:none`, and
  the poll is answered as before. A poll is never refused or held up for an upgrade.
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
  its upgrade on, then `{:serve, %{id, build, action}}` or `:none`. `by` is the writer.
  """
  @spec poll(String.t(), map(), String.t()) :: {:serve, map()} | :none
  def poll(runtime_id, input, by \\ "flow") when is_binary(runtime_id) do
    input = Translate.normal(input)

    case open(runtime_id) do
      {:ok, [current | others]} ->
        Enum.each(others, &refuse(&1, current, by))
        step(current, input, by)

      _none_or_unreadable ->
        :none
    end
  end

  defp step(fact, input, by) do
    values = fact["values"]
    report = report(input, fact["key"])

    {changes, action} = next(values["step"] || "requested", values, input, report)

    if changes != %{}, do: record(fact, changes, by)

    case action do
      nil -> :none
      action -> {:serve, %{id: fact["key"], build: values["build"], action: action}}
    end
  end

  # -- The steps ---------------------------------------------------------------------

  defp next("requested", _values, input, _report) do
    {%{
       "step" => "draining",
       "from_build" => input["build"],
       "from_incarnation" => input["incarnation"]
     }, :drain}
  end

  defp next(step, _values, _input, %{"mode" => "draining", "busy" => [_ | _] = busy})
       when step in ["draining", "waiting"],
       do: {%{"step" => "waiting", "busy" => Enum.join(busy, ", ")}, :drain}

  defp next(step, _values, _input, %{"mode" => "draining", "busy" => []})
       when step in ["draining", "waiting"],
       do: {%{"step" => "updating", "busy" => ""}, :update}

  defp next(step, _values, _input, _report) when step in ["draining", "waiting"],
    do: {%{}, :drain}

  defp next("updating", values, input, report) do
    restarted? = input["incarnation"] not in [nil, values["from_incarnation"]]

    cond do
      restarted? and input["build"] == values["build"] ->
        {%{"step" => "verifying", "incarnation" => input["incarnation"]}, :resume}

      restarted? ->
        failed(
          "restart",
          "the Runtime came back on build #{input["build"]}, not #{values["build"]}"
        )

      match?(%{"update" => update} when update in ["refused", "failed"], report) ->
        failed(
          report["step"] || "update",
          report["reason"] || "the update command #{report["update"]}"
        )

      true ->
        {%{}, :update}
    end
  end

  defp next("verifying", _values, input, report) do
    accepts? = (input["offer"] || %{}) != %{} or (input["holdings"] || []) != []

    if match?(%{"mode" => "open"}, report) and accepts?,
      do: {%{"step" => "done"}, nil},
      else: {%{}, :resume}
  end

  defp next(_ended_or_unknown, _values, _input, _report), do: {%{}, nil}

  defp failed(step, reason),
    do:
      {%{"step" => "failed", "failed_step" => step, "reason" => String.slice(reason, 0, 2_000)},
       nil}

  # The poll's report of this upgrade, or nil (none, or of another upgrade).
  defp report(input, key) do
    case input["upgrade"] do
      %{"id" => ^key} = report -> Map.put_new(report, "busy", [])
      _ -> nil
    end
  end

  defp refuse(fact, current, by) do
    record(
      fact,
      %{
        "step" => "failed",
        "failed_step" => "start",
        "reason" => "#{current["key"]} is in progress: one upgrade at a time"
      },
      by
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

  defp record(fact, changes, by) do
    values = fact["values"]
    changed = Map.filter(changes, fn {field, value} -> values[field] != value end)

    if changed != %{} do
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

        other ->
          Logger.warning(
            "flow work source: upgrade #{fact["key"]} not recorded: #{inspect(other)}"
          )
      end
    end
  end

  defp digest(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)
end

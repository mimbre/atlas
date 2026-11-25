defmodule AtlasFlow.WorkSource.Upgrade do
  @moduledoc """
  A Runtime's upgrade, as its supervisor starts it through Control (IS-Atlas-26): a
  `runtime_upgrade` fact that names the released build (`build`) and the Runtime's
  machinery (`upgrades`, the fact whose key is the Runtime's id, as for its
  configuration). Facts refuses a second one for the same machinery while one is open
  (the relation's `limit`), so two upgrades never run on one Runtime at once.

  The work source serves it in every poll answer of that Runtime until it ends
  (`polled.upgrade`, `work_source` 0.5.0), and the Runtime reports where it is with every
  poll (`poll_input.upgrade`). On each poll, `poll/3` (run by `AtlasFlow.Delivery`, as the
  configuration step is) writes the upgrade's `step` and what goes with it, so its run
  (the `runtime_upgrade` subflow) and Control show it:

  | `step`      | when                                                               |
  |-------------|--------------------------------------------------------------------|
  | `requested` | made; the Runtime has not polled since                             |
  | `draining`  | served: the Runtime takes no new work and waits until no slot is busy (`busy` names the busy ones); `from_build` and `from_incarnation` are recorded when it is first served |
  | `updating`  | the Runtime's update command installs the build and restarts it    |
  | `verifying` | the Runtime says it is the restarted one; verified below           |
  | `done`      | verified                                                           |
  | `failed`    | `failed_step` (`drain`, `update`, `restart`, `verify`) and `reason` say where and why |

  **Verified** when a poll after the restart shows the served build (`build`), an
  incarnation other than `from_incarnation`, mode `open` and an offer of at least one
  slot: the Runtime accepts work again. `incarnation` records the new one. Another build
  fails it at `verify`; an incarnation that did not change, a mode that is not open or an
  empty offer leave it `verifying` until a poll shows it. A Runtime already on the build
  when the upgrade is first served is `done` at once, without a restart.

  `state` (open while it runs, so Facts refuses a second one) is written `ended` with
  `done` or `failed`. A field is written only when it changes; a refused write (the fact changed meanwhile) is
  left to the next poll. No upgrade, or a Facts that does not answer: `:none`, and the poll
  is answered as before; a poll is never refused or held up for an upgrade.
  """

  require Logger

  alias AtlasFlow.Talk
  alias AtlasFlow.WorkSource.Translate

  # The kind, its relation to the machinery and its fields (Model.RuntimeUpgrade).
  @upgrade "runtime_upgrade"
  @upgrades "upgrades"
  @ended ["done", "failed"]

  @doc "The kind an upgrade is kept in."
  def kind, do: @upgrade

  @doc "The relation from an upgrade to the Runtime's machinery."
  def relation, do: @upgrades

  @doc """
  One poll of Runtime `runtime_id` (`input` the poll's input, atom or string keys): records
  what it says on its open upgrade, then `{:serve, %{id, build}}` while that upgrade is
  open, or `:none`. `by` is the writer.
  """
  @spec poll(String.t(), map(), String.t()) :: {:serve, map()} | :none
  def poll(runtime_id, input, by \\ "flow") when is_binary(runtime_id) do
    input = Translate.normal(input)

    case open(runtime_id) do
      {:ok, %{"key" => key, "values" => values} = fact} ->
        report = if match?(%{"id" => ^key}, input["upgrade"]), do: input["upgrade"]
        wanted = Map.merge(values, next(values, input, report))
        wanted = if wanted["step"] in @ended, do: Map.put(wanted, "state", "ended"), else: wanted
        record(fact, wanted, by)

        if wanted["step"] in @ended,
          do: :none,
          else: {:serve, %{id: key, build: values["build"]}}

      _none_or_unreadable ->
        :none
    end
  end

  # The fields this poll sets. Without a report: first served (requested, or no step yet)
  # records where it starts from; later, the Runtime has not taken it yet.
  defp next(values, input, nil) do
    if values["step"] in [nil, "requested"] do
      first = %{"from_build" => input["build"], "from_incarnation" => input["incarnation"]}

      if input["build"] == values["build"],
        do:
          Map.merge(first, %{"step" => "done", "reason" => "the Runtime already runs this build"}),
        else: Map.put(first, "step", "draining")
    else
      %{}
    end
  end

  defp next(_values, _input, %{"step" => "draining"} = report),
    do: %{"step" => "draining", "busy" => Enum.join(report["busy"] || [], ", ")}

  defp next(_values, _input, %{"step" => "updating"}), do: %{"step" => "updating", "busy" => ""}

  defp next(_values, _input, %{"step" => "failed"} = report) do
    %{
      "step" => "failed",
      "failed_step" => report["failed_step"] || "update",
      "reason" => String.slice(report["reason"] || "the Runtime gave no reason", 0, 2_000)
    }
  end

  defp next(values, input, %{"step" => "restarted"} = report) do
    cond do
      input["build"] != values["build"] ->
        %{
          "step" => "failed",
          "failed_step" => "verify",
          "reason" => "the Runtime came back on build #{input["build"]}, not #{values["build"]}"
        }

      input["incarnation"] != values["from_incarnation"] and report["mode"] == "open" and
          offers?(input["offer"]) ->
        %{"step" => "done", "incarnation" => input["incarnation"], "busy" => ""}

      true ->
        %{"step" => "verifying"}
    end
  end

  defp next(_values, _input, _unknown), do: %{}

  defp offers?(offer) when is_map(offer),
    do: Enum.any?(offer, fn {_, n} -> is_integer(n) and n > 0 end)

  defp offers?(_none), do: false

  # The open upgrade of the machinery, the oldest when (against the limit) there are more.
  defp open(runtime_id) do
    case Talk.read(@upgrade, %{"linked" => %{@upgrades => runtime_id}, "plain" => true}) do
      %{"facts" => facts} when is_list(facts) ->
        facts
        |> Enum.filter(&(is_map(&1["values"]) and &1["values"]["step"] not in @ended))
        |> Enum.filter(&(&1["values"]["state"] != "ended"))
        |> Enum.filter(&is_binary(&1["values"]["build"]))
        |> Enum.sort_by(& &1["key"])
        |> case do
          [first | _] -> {:ok, first}
          [] -> :none
        end

      other ->
        {:error, other}
    end
  end

  defp record(fact, wanted, by) do
    values = fact["values"]
    changed = Map.filter(wanted, fn {field, value} -> values[field] != value end)

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
          :ok

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

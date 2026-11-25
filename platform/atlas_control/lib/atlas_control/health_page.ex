defmodule AtlasControl.HealthPage do
  @moduledoc """
  The core's health (`/health`, IS-Atlas-117), reached from the Workers page and readable
  in any client, so a stall is seen without attaching to the prod machine. One row per
  check, each marked late once it passes its limit:

  - **Syncs**: each rela sync task's last success and last failure. Atlas keeps no run
    history of its own (D-0100): these come from rela or not at all. Until rela reports a
    scheduled task's runs to the core, the row says so ("not reported by rela") and is
    never marked late.
  - **Flow**: its lag, how far its round is behind when it was due: the round stepping
    now, or one due whose timer the Engine has not yet taken, counts from when it was due
    until now; otherwise the last finished round, from its due to its end. Late past
    2 min. A Flow that does not answer is late.
  - **Facts' queue**: the requests waiting at Facts' endpoint, unread
    (`AtlasBus.waiting/1`), counted without asking Facts. No limit yet: shown only.
  - **Runtimes**: each Runtime's last poll of Dispatch, late past 10 min. Only Runtimes
    that polled since the core started are known.

  `report` is what the session gathered: `%{flow: Flow's `_health` answer or nil,
  facts_waiting: integer or nil}`. `now` is when the page is made.

  ## Alerts (IS-Atlas-117, second slice)

  The decider is alerted where they get work: on their start page in Control, one alert
  per late row (`alerts/2`, `alert_view/1`), each naming what fell behind and since when,
  with the Health action. An alert is worked out from the same report each time the
  start page is made, so it is one per stall, never one per check, and it is gone once
  its row recovers; a healthy core raises none. Since when is the row's own moment, so
  the same stall reads the same on every page: Flow's round's due, a Runtime's last poll.
  A Flow that does not answer is one alert: its Runtimes are not alerted on as well.

  Nothing is stored or scheduled for an alert (D-0100): no fact, no timer. The page
  says when it is to be read again (`until/2`): at once while an alert is open, so a
  reconcile clears it once the row recovers; otherwise the moment the first healthy
  row would pass its limit. The syncs raise no alert until rela reports their runs.
  """

  require AtlasControl.Blocks, as: Blocks

  alias AtlasControl.Pages

  @flow_limit 2 * 60
  @runtime_limit 10 * 60
  @sync_limit 15 * 60

  @doc "The limits, in seconds: `sync`, `flow` and `runtime`."
  def limits, do: %{sync: @sync_limit, flow: @flow_limit, runtime: @runtime_limit}

  @doc """
  The rows of the page: `%{core: [row], syncs: [row], runtimes: [row]}`, each row
  `%{key, label, late, text, since}`: `key` names the check (`flow`, `facts`, `syncs`,
  `runtimes`, `runtime:<id>`); `since` is the moment it fell behind from (a DateTime, or
  nil when none is known); `due`, for a row not late yet, the moment it passes its limit.
  """
  def rows(report, now) do
    flow = report[:flow]

    %{
      core: [flow_row(flow, now), facts_row(report[:facts_waiting])],
      syncs: [
        %{
          key: "syncs",
          label: "rela syncs",
          late: false,
          text:
            "not reported by rela: rela does not yet tell the core when a scheduled task " <>
              "last succeeded or failed (limit #{span(@sync_limit)})"
        }
      ],
      runtimes: runtime_rows(flow, now)
    }
  end

  @doc "The page, as Control sends it."
  def render(report, now \\ DateTime.utc_now()) do
    rows = rows(report, now)

    groups = [
      {"health-core", "Core", rows.core},
      {"health-syncs", "Syncs", rows.syncs},
      {"health-runtimes", "Runtimes", rows.runtimes}
    ]

    all = rows.core ++ rows.syncs ++ rows.runtimes
    late = Enum.count(all, & &1.late)

    summary = Pages.summary([{"Checks", length(all)}, {"Late", late}], [workers_action()])

    blocks =
      [{"summary", summary}] ++
        for {id, title, rows} <- groups do
          {id,
           Blocks.item(
             title: title,
             fields: for(row <- rows, do: Blocks.pair(label: row.label, value: value(row)))
           )}
        end

    # The groups with a late row, in the error tone.
    markup =
      for {id, _, rows} <- groups,
          Enum.any?(rows, & &1.late),
          do: Blocks.highlight(id, id, tone: "error")

    Map.merge(
      %{title: "Health", back: Pages.path({:worker_page, :workers, %{}})},
      Blocks.view_model(blocks, markup)
    )
  end

  @doc """
  The decider's alerts: one per late row (a stall), `%{key, what, since, text}`, in page
  order. `what` names what fell behind, `since` is when (a DateTime, or nil when the
  core cannot tell), `text` says both. A healthy core has none.
  """
  def alerts(report, now) do
    rows = rows(report, now)

    for row <- rows.core ++ rows.syncs ++ rows.runtimes, row.late, row[:of] == nil do
      what = what(row)
      since = row[:since]

      %{key: row.key, what: what, since: since, text: alert_text(what, since, row.text)}
    end
  end

  @doc """
  When the decider's page is to be read again for its alerts (ISO 8601, UTC): `now`
  while an alert is open, so it goes once its row recovers; else the first moment a
  healthy row passes its limit; nil when none can.
  """
  def until(report, now) do
    rows = rows(report, now)
    all = rows.core ++ rows.syncs ++ rows.runtimes

    if Enum.any?(all, & &1.late) do
      iso(now)
    else
      all
      |> Enum.map(&row_due/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.min(DateTime, fn -> nil end)
      |> iso()
    end
  end

  defp row_due(%{due: %DateTime{} = due}), do: due
  defp row_due(_row), do: nil

  @doc """
  The alerts as blocks for the top of the decider's start page: `%{blocks, markup}`, an
  `item` `alerts` titled "Alerts", one field per alert, with the Health action, in the
  error tone. No alerts, no blocks.
  """
  def alert_view([]), do: %{blocks: [], markup: []}

  def alert_view(alerts) do
    item =
      Blocks.item(
        title: "Alerts",
        fields: for(a <- alerts, do: Blocks.pair(label: a.what, value: a.text)),
        actions: [health_action()]
      )

    Blocks.view_model([{"alerts", item}], [Blocks.highlight("alerts", "alerts", tone: "error")])
  end

  defp what(%{key: "flow"}), do: "Flow"
  defp what(%{key: "syncs", label: label}), do: label
  defp what(%{key: "runtime:" <> _, label: label}), do: "Runtime #{label}"
  defp what(%{label: label}), do: label

  defp alert_text(what, nil, text), do: "#{what} fell behind: #{text}"

  defp alert_text(what, since, text),
    do: "#{what} behind since #{moment(since)}: #{text}"

  defp health_action,
    do:
      Blocks.action(label: "Health", key: "h", to: Pages.path({:worker_page, :health, %{}}))
      |> Map.put("page", true)

  defp iso(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp iso(_), do: nil

  defp workers_action,
    do: Blocks.action(label: "Workers", key: "w", to: Pages.path({:worker_page, :workers, %{}}))

  defp value(%{late: true, text: text}), do: "late · " <> text
  defp value(%{text: text}), do: text

  defp flow_row(nil, _now),
    do: %{key: "flow", label: "Flow", late: true, text: "Flow did not answer"}

  defp flow_row(flow, now) do
    f = flow["flow"] || %{}
    due = at(f["due"])
    next_due = at(f["next_due"])
    last_due = at(f["last_due"])
    finished = at(f["last_finished"])

    # `since`: the due the lag counts from. `due`: when the round to come (or the one
    # stepping) passes the limit, if it has not yet.
    {lag, since, about} =
      cond do
        due ->
          {seconds(due, now), due, "its round, due #{moment(due)}, is still running"}

        next_due && DateTime.compare(next_due, now) == :lt ->
          {seconds(next_due, now), next_due,
           "its round, due #{moment(next_due)}, has not started"}

        last_due && finished ->
          {seconds(last_due, finished), last_due, "its last round finished #{moment(finished)}"}

        true ->
          {nil, nil, "no round has finished since the core started"}
      end

    coming = due || next_due
    passes = coming && DateTime.add(coming, @flow_limit + 1, :second)

    case lag do
      nil ->
        %{key: "flow", label: "Flow", late: false, text: about, due: passes}

      lag ->
        late = lag > @flow_limit

        %{
          key: "flow",
          label: "Flow",
          late: late,
          since: if(late, do: since),
          due: passes,
          text: "#{span(lag)} behind (limit #{span(@flow_limit)}): #{about}"
        }
    end
  end

  defp facts_row(nil),
    do: %{key: "facts", label: "Facts' queue", late: false, text: "Facts is not attached"}

  defp facts_row(n),
    do: %{key: "facts", label: "Facts' queue", late: false, text: "#{n} waiting"}

  # Flow's own row says it did not answer; this one is not a stall of its own.
  defp runtime_rows(nil, _now),
    do: [
      %{key: "runtimes", label: "Runtimes", late: true, text: "Flow did not answer", of: "flow"}
    ]

  defp runtime_rows(flow, now) do
    case flow["runtimes"] || [] do
      [] ->
        [
          %{
            key: "runtimes",
            label: "Runtimes",
            late: false,
            text: "no Runtime has polled since the core started"
          }
        ]

      runtimes ->
        for r <- runtimes do
          polled = at(r["polled_at"])
          ago = polled && seconds(polled, now)

          late = ago == nil or ago > @runtime_limit

          %{
            key: "runtime:#{r["runtime"]}",
            label: r["runtime"],
            late: late,
            since: if(late, do: polled),
            due: polled && DateTime.add(polled, @runtime_limit + 1, :second),
            text:
              if(ago,
                do: "polled #{span(ago)} ago, #{moment(polled)} (limit #{span(@runtime_limit)})",
                else: "no poll known"
              )
          }
        end
    end
  end

  defp at(nil), do: nil

  defp at(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _} -> at
      _ -> nil
    end
  end

  defp seconds(from, to), do: max(DateTime.diff(to, from), 0)

  # A stretch of time as a reader reads it: 45 s, 9 min 5 s, 2 min, 1 h 05 min.
  defp span(s) when s < 60, do: "#{s} s"

  defp span(s) when s < 3600 do
    case rem(s, 60) do
      0 -> "#{div(s, 60)} min"
      r -> "#{div(s, 60)} min #{r} s"
    end
  end

  defp span(s),
    do: "#{div(s, 3600)} h #{String.pad_leading(to_string(div(rem(s, 3600), 60)), 2, "0")} min"

  # A moment in UTC: 23 Nov 10:01:00 UTC.
  defp moment(at), do: Calendar.strftime(DateTime.truncate(at, :second), "%-d %b %H:%M:%S UTC")
end

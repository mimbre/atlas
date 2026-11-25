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
  """

  require AtlasControl.Blocks, as: Blocks

  alias AtlasControl.Pages

  @flow_limit 2 * 60
  @runtime_limit 10 * 60
  @sync_limit 15 * 60

  @doc "The limits, in seconds: `sync`, `flow` and `runtime`."
  def limits, do: %{sync: @sync_limit, flow: @flow_limit, runtime: @runtime_limit}

  @doc "The rows of the page: `%{core: [row], syncs: [row], runtimes: [row]}`, each row `%{label, late, text}`."
  def rows(report, now) do
    flow = report[:flow]

    %{
      core: [flow_row(flow, now), facts_row(report[:facts_waiting])],
      syncs: [
        %{
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

  defp workers_action,
    do: Blocks.action(label: "Workers", key: "w", to: Pages.path({:worker_page, :workers, %{}}))

  defp value(%{late: true, text: text}), do: "late · " <> text
  defp value(%{text: text}), do: text

  defp flow_row(nil, _now),
    do: %{label: "Flow", late: true, text: "Flow did not answer"}

  defp flow_row(flow, now) do
    f = flow["flow"] || %{}
    due = at(f["due"])
    next_due = at(f["next_due"])
    last_due = at(f["last_due"])
    finished = at(f["last_finished"])

    {lag, about} =
      cond do
        due ->
          {seconds(due, now), "its round, due #{moment(due)}, is still running"}

        next_due && DateTime.compare(next_due, now) == :lt ->
          {seconds(next_due, now), "its round, due #{moment(next_due)}, has not started"}

        last_due && finished ->
          {seconds(last_due, finished), "its last round finished #{moment(finished)}"}

        true ->
          {nil, "no round has finished since the core started"}
      end

    case lag do
      nil ->
        %{label: "Flow", late: false, text: about}

      lag ->
        %{
          label: "Flow",
          late: lag > @flow_limit,
          text: "#{span(lag)} behind (limit #{span(@flow_limit)}): #{about}"
        }
    end
  end

  defp facts_row(nil),
    do: %{label: "Facts' queue", late: false, text: "Facts is not attached"}

  defp facts_row(n),
    do: %{label: "Facts' queue", late: false, text: "#{n} waiting"}

  defp runtime_rows(nil, _now),
    do: [%{label: "Runtimes", late: true, text: "Flow did not answer"}]

  defp runtime_rows(flow, now) do
    case flow["runtimes"] || [] do
      [] ->
        [%{label: "Runtimes", late: false, text: "no Runtime has polled since the core started"}]

      runtimes ->
        for r <- runtimes do
          polled = at(r["polled_at"])
          ago = polled && seconds(polled, now)

          %{
            label: r["runtime"],
            late: ago == nil or ago > @runtime_limit,
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

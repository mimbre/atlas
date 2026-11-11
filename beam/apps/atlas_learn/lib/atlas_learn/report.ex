defmodule AtlasLearn.Report do
  @moduledoc """
  The window's report, in markdown: which sources were read, a summary of what each
  observation saw, the patterns with the records they cite, and what this report cannot see.
  It proposes and applies nothing.
  """

  @limits [
    "Learn v1 only observes; it calls no model and creates or changes nothing.",
    "Gate verdicts, conversations and the audit history of facts are not read yet.",
    "Learn v1 makes no outside calls, so CI outcomes Code does not know stay unseen."
  ]

  def render(window, observations, patterns) do
    [
      "# Learn report: #{moment(window.from)} to #{moment(window.until)}\n\n",
      "Deterministic patterns from recorded outcomes. No model was asked and nothing was ",
      "applied; act on a pattern through the normal flow.\n\n",
      sources(observations),
      "\n## Observations\n",
      Enum.map(observations, &observation/1),
      "\n## Patterns\n",
      Enum.map(patterns, &pattern/1),
      "\n## What this report cannot see\n\n",
      Enum.map(Enum.flat_map(observations, & &1.notes) ++ @limits, &"- #{&1}\n")
    ]
    |> IO.iodata_to_binary()
  end

  defp sources(observations) do
    rows =
      for o <- observations,
          do: [o.name, o.source || "", status(o.status), length(o.records), length(o.context)]

    table(["Observation", "Source", "Read", "In window", "Outside window"], rows)
  end

  defp status(:read), do: "read"
  defp status(:not_asked), do: "not asked"
  defp status({:unavailable, why}), do: "unavailable: #{why}"

  defp observation(%{status: :read, records: []} = o),
    do: "\n### #{o.name}\n\nNothing in this window.\n"

  defp observation(%{status: :read} = o),
    do: ["\n### #{o.name}\n\n", summary(o), "\n", records(o)]

  defp observation(o), do: "\n### #{o.name}\n\nNot observed (#{status(o.status)}).\n"

  defp summary(%{records: records}) do
    counts =
      records
      |> Enum.frequencies_by(&joined([type(&1), &1[:state] || &1[:phase] || &1[:status]], " "))
      |> Enum.sort()
      |> Enum.map_join(", ", fn {what, n} -> "#{what} #{n}" end)

    "#{length(records)} records: #{counts}.\n"
  end

  defp joined(parts, separator), do: parts |> Enum.reject(&is_nil/1) |> Enum.join(separator)

  defp type(%{type: type}), do: Atom.to_string(type)
  defp type(_), do: nil

  defp records(%{name: "Worker passes", records: turns}) do
    table(
      [
        "Turn",
        "Worker",
        "State",
        "Backend / model",
        "Started",
        "Ended",
        "Continues",
        "Result or error"
      ],
      Enum.map(Enum.sort_by(turns, &{&1.started_at || "", &1.id}), fn t ->
        [
          code(t.id),
          t.worker,
          t.state,
          joined([t.backend, t.model], " / "),
          t.started_at,
          t.ended_at,
          t.source && code(t.source),
          t.error || t.result
        ]
      end)
    )
  end

  defp records(%{name: "Changes through Code", records: records}) do
    table(
      ["Record", "Phase", "Repository", "About", "Last changed"],
      Enum.map(
        Enum.sort_by(records, &{DateTime.to_unix(&1.at), &1.id}),
        &[code(&1.id), &1.phase, &1.repository, about(&1), moment(&1.at)]
      )
    )
  end

  defp records(%{records: facts}) do
    table(
      ["Fact", "Status", "Decided", "Title"],
      Enum.map(Enum.sort_by(facts, & &1.id), &[code(&1.id), &1.status, &1.at, &1.title])
    )
  end

  defp about(%{type: :review} = r), do: "#{r.title} → #{r.target} (change #{r.change_id})"
  defp about(%{type: :integration} = r), do: "review #{r.review_id} → #{r.target}"
  defp about(_), do: ""

  defp pattern(%{status: :read, findings: []} = p),
    do: "\n### #{p.title}\n\nNone in this window.\n"

  defp pattern(%{status: :read} = p),
    do: [
      "\n### #{p.title}\n\n",
      Enum.map(
        p.findings,
        &"- #{&1.text}. Evidence: #{Enum.map_join(&1.evidence, ", ", fn id -> code(id) end)}\n"
      )
    ]

  defp pattern(p), do: "\n### #{p.title}\n\nNot looked for: its source was #{status(p.status)}.\n"

  defp table(header, rows) do
    line = fn cells -> "| " <> Enum.map_join(cells, " | ", &cell/1) <> " |\n" end
    [line.(header), line.(Enum.map(header, fn _ -> "---" end)), Enum.map(rows, line)]
  end

  defp cell(nil), do: ""

  defp cell(value),
    do: value |> to_string() |> String.replace("|", "\\|") |> String.replace("\n", " ")

  defp code(id), do: "`#{id}`"

  defp moment(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end

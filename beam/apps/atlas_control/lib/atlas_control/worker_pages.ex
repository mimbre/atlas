defmodule AtlasControl.WorkerPages do
  @moduledoc """
  Worker content uses ordinary BFF blocks; Console owns its renderer and shell.
  The Worker and Conversation parts retain stable boundaries. Internal Console
  declarations fix the execution and keep durable history separate from output.
  An optional `:output_capability` render callback supplies authorized output
  availability; absent capability never implies an available stream.
  """
  alias AtlasControl.{Pages, Workers}
  require AtlasControl.Blocks, as: Blocks

  def target(params) do
    %{
      "worker" => %{
        "environment" => AtlasBus.environment(),
        "machine" => params.machine,
        "worker" => params.worker
      },
      "turn" => params.turn,
      "attempt" => params.attempt
    }
  end

  # Running first, in a list of its own, newest activity first; then the turns that
  # finished most recently (`Workers.board/3`). Each row is the turn: its key and the
  # worker page of its exact execution.
  def render({:worker_page, :workers, _}, m, actor, read, _form) do
    case Workers.board(m, actor, read) do
      {:ok, %{"running" => running, "finished" => finished}} ->
        page("Workers", "/", [
          {"workers-running",
           Blocks.list(
             title: "Running",
             rows: Enum.map(running, &worker_row(&1, [&1["state"]])),
             empty: "No worker is running."
           )},
          {"workers-finished",
           Blocks.list(
             title: "Finished",
             rows:
               Enum.map(finished, &worker_row(&1, [&1["reason"] || &1["state"], &1["ended_at"]])),
             empty: "No worker has finished."
           )}
        ])

      {:error, reason} ->
        error(reason, "/")
    end
  end

  def render({:worker_page, mode, params}, m, actor, read, form) do
    execution = target(params)

    case Workers.about(m, actor, execution, read) do
      {:ok, view, about} ->
        if mode == :worker_guidance do
          guidance(view, execution, form)
        else
          view =
            case form[:output_capability] do
              capability when is_function(capability, 1) ->
                Map.put(view, "output", capability.(execution))

              _ ->
                view
            end

          detail(view, about, execution, m, actor, read)
        end

      {:error, reason} ->
        error(reason, "/workers")
    end
  end

  defp worker_row(worker, about) do
    execution = worker["execution"]
    identity = execution["worker"]

    Blocks.row(
      id: execution["turn"],
      label: identity["worker"],
      detail:
        Enum.join(
          [identity["machine"], execution["turn"] | Enum.reject(about, &(&1 in [nil, ""]))],
          " · "
        ),
      to: path(execution)
    )
  end

  # The page leads with what the worker is doing (Worker), and in Conversation with what
  # it said; guidance, the execution record and the output stream's own state are in a
  # collapsible Details section, behind one key. A field nothing says is left out.
  defp detail(view, about, execution, m, actor, read) do
    identity = execution["worker"]
    descriptor = view["descriptor"] || %{}
    item = present(view["item"])
    running = about["status"] == "running"
    # Why it is in its state, unless the state says it plainly.
    reason =
      if about["status"] not in ["running", "finished", "stopped"], do: present(view["reason"])

    pairs = [
      {"State", about["status"]},
      {"State reason", reason},
      {"Started", time(about["started_at"])},
      {"Ended", if(not running, do: time(about["ended_at"]))},
      {"Duration",
       duration(
         about["started_at"],
         if(running, do: view["confirmed_at"], else: about["ended_at"])
       )},
      {"Backend", known(descriptor["harness"])},
      {"Model", about["model"]},
      {"Activity", if(running, do: present(view["activity"]))},
      {"Worker", identity["worker"]},
      {"Machine", identity["machine"]},
      {"Environment", identity["environment"]},
      {"Turn", execution["turn"]},
      {"Item", item},
      {"Item title",
       if(item && view["item_title"] != about["title"], do: present(view["item_title"]))}
    ]

    actions =
      if view["guidance"]["available"],
        do: [
          Blocks.action(
            label: "Queue guidance for this turn",
            key: "g",
            to: path(execution, :worker_guidance)
          )
        ],
        else: []

    actions =
      if view["item_to"],
        do: actions ++ [Blocks.action(label: "Open current item", key: "i", to: view["item_to"])],
        else: actions

    content =
      Blocks.item(
        title: about["title"] || "Worker #{identity["worker"]}",
        fields: fields(pairs),
        actions: actions
      )

    newer =
      case about["newer"] do
        %{"execution" => newer} = turn ->
          [
            {"worker-newer",
             Blocks.list(
               title: "Newer turn",
               rows: [
                 Blocks.row(
                   label: newer["turn"],
                   detail: turn["status"],
                   to: path(newer)
                 )
               ]
             )}
          ]

        _ ->
          []
      end

    {history, history_actions} = history(execution, m, actor, read)
    {output, output_details, output_actions} = output(view, execution)

    record =
      Blocks.item(
        title: "Execution",
        fields:
          fields([
            {"Attempt", execution["attempt"]},
            {"Guidance",
             if(view["guidance"]["available"], do: "available", else: view["guidance"]["reason"])},
            {"State value", present(view["state"])},
            {"State reason", if(reason == nil, do: present(view["reason"]))},
            {"Harness version", known(descriptor["harness_version"])},
            {"Configured model", known(descriptor["configured_model"])},
            {"Reported model", known(descriptor["reported_model"])},
            {"Lease until", present(view["lease_until"])},
            {"Confirmed at", present(view["confirmed_at"])}
          ])
      )

    main_end = if newer == [], do: "worker", else: "worker-newer"

    page(
      "Worker #{identity["worker"]}",
      "/workers",
      [{"worker", content}] ++
        newer ++
        [{"worker-output", output}, {"worker-output-details", output_details}] ++
        history ++ [{"worker-record", record}],
      [
        Blocks.part("worker", main_end, title: "Worker", role: "main"),
        Blocks.part("worker-output", "worker-record", title: "Conversation", role: "related"),
        Blocks.section("worker-output-details", "worker-record",
          title: "Details",
          collapsible: true
        )
      ]
    )
    |> Map.put(
      :console_actions,
      [details_action()] ++ history_actions ++ output_actions
    )
  end

  defp details_action,
    do: %{
      label: "Show or hide details",
      keys: ["d"],
      operation: %{"name" => "sections_toggle"},
      on: nil,
      row: nil,
      available: true,
      reason: nil
    }

  defp history(execution, m, actor, read) do
    case call("worker_history", %{"execution" => execution}, m, actor, read) do
      {:ok, data} ->
        {rows, fields} =
          Enum.map_reduce(data["interactions"], [], fn interaction, fields ->
            projection = interaction["projection"]

            status =
              projection["proven"] <> if(projection["uncertain"], do: " (uncertain)", else: "")

            row =
              Blocks.row(
                id: interaction["key"],
                label: interaction["body"],
                detail: "#{interaction["actor"]} · #{status}",
                to: path(execution)
              )

            body =
              Blocks.pair(
                label: "#{interaction["key"]} · #{interaction["actor"]} · #{status}",
                value: interaction["body"]
              )

            evidence =
              Blocks.pair(
                label: "#{interaction["key"]} · Recorded evidence",
                value: JSON.encode!(Map.delete(interaction, "body"))
              )

            {row, [evidence, body | fields]}
          end)

        note =
          if data["more"],
            do: "First history page; full bounded history is available through worker_history.",
            else: "Durable guidance"

        history = [
          {"guidance-history",
           Blocks.list(title: note, rows: rows, empty: "No durable guidance is recorded.")}
        ]

        details =
          if fields == [],
            do: [],
            else: [
              {"guidance-details",
               Blocks.item(title: "Guidance details", fields: Enum.reverse(fields))}
            ]

        {history ++ details, history_actions(execution, data)}

      {:error, reason} ->
        {[
           {"guidance-history",
            Blocks.item(
              title: "History unavailable",
              fields: [Blocks.pair(label: "Reason", value: reason)]
            )}
         ], []}
    end
  end

  defp history_actions(execution, data) do
    receipts =
      worker_action("Inspect selected guidance receipts", "e", "guidance-history", %{
        "name" => "worker_receipts",
        "execution" => execution,
        "interaction_source" => "selected_history"
      })
      |> Map.merge(%{
        available: data["interactions"] != [],
        reason:
          if(data["interactions"] == [], do: "No correlated guidance is available to select.")
      })

    if data["more"] do
      [
        worker_action("More guidance history", "h", "guidance-history", %{
          "name" => "worker_history",
          "execution" => execution,
          "cursor" => data["cursor"]
        }),
        receipts
      ]
    else
      [receipts]
    end
  end

  # What the worker said leads the conversation; Console fills it from the exact
  # execution's output once it reads it. The stream's own state is a detail.
  defp output(view, execution) do
    case view["output"] do
      %{"available" => true} ->
        {Blocks.item(
           title: "Worker messages",
           fields: [Blocks.pair(label: "", value: "Reading the worker's output…")]
         ),
         Blocks.item(
           title: "Output stream",
           fields: [Blocks.pair(label: "Status", value: "available for this exact execution")]
         ),
         [
           worker_action("Connect or retry output", "o", "worker-output", %{
             "name" => "worker_output_subscribe",
             "execution" => execution
           })
         ]}

      capability ->
        reason = if is_map(capability), do: capability["reason"]

        {Blocks.item(
           title: "Worker messages",
           fields: [Blocks.pair(label: "", value: "No output can be read for this turn.")]
         ),
         Blocks.item(
           title: "Output stream",
           fields: [
             Blocks.pair(
               label: "Reason",
               value: reason || "Output support has not been established for this execution."
             )
           ]
         ), []}
    end
  end

  defp worker_action(label, key, on, operation) do
    %{
      label: label,
      keys: [key],
      operation: operation,
      on: on,
      row: nil,
      available: true,
      reason: nil
    }
  end

  defp guidance(view, execution, form) do
    if view["guidance"]["available"] do
      values = form[:values] || %{}
      key = values["client_key"] || form[:worker_client_key]

      inputs = [
        Blocks.input(
          name: "client_key",
          label: "Submission key",
          kind: "readonly",
          value: key,
          required: true
        ),
        Blocks.input(
          name: "body",
          label: "Literal guidance for #{execution["turn"]}",
          kind: "multiline",
          value: values["body"] || "",
          required: true
        ),
        Blocks.input(
          name: "cause",
          label: "Why",
          kind: "text",
          value: values["cause"] || "",
          required: true
        )
      ]

      params =
        Map.merge(execution["worker"], Map.take(execution, ~w(turn attempt)))
        |> Map.delete("environment")

      block =
        Blocks.form(
          title: "Queue guidance — not a machine control",
          inputs: inputs,
          submit_label: "Queue for this exact turn",
          submit_to: Blocks.call(endpoint: "queue_worker_guidance", params: params),
          cancel_to: path(execution),
          errors: form[:errors] || []
        )

      page("Guidance", path(execution), [block])
    else
      page("Worker unavailable", path(execution), [
        Blocks.item(
          title: "Worker unavailable",
          fields: [
            Blocks.pair(label: "Reason", value: view["guidance"]["reason"]),
            Blocks.pair(label: "State", value: view["state"]),
            Blocks.pair(label: "State reason", value: view["reason"])
          ]
        )
      ])
    end
  end

  def path(execution, mode \\ :worker) do
    params = %{
      machine: execution["worker"]["machine"],
      worker: execution["worker"]["worker"],
      turn: execution["turn"],
      attempt: execution["attempt"]
    }

    Pages.path({:worker_page, mode, params})
  end

  defp call(op, request, m, actor, read),
    do:
      Workers.handle(op, request, m, actor, read, fn _, _ ->
        raise "rendering cannot write"
      end)

  def error(reason, back),
    do:
      page("Worker unavailable", back, [
        Blocks.item(
          title: "Worker unavailable",
          fields: [Blocks.pair(label: "Reason", value: reason)]
        )
      ])

  defp fields(pairs),
    do: for({label, value} <- pairs, value != nil, do: Blocks.pair(label: label, value: value))

  defp present(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp present(_), do: nil

  defp known(value), do: if(present(value) in [nil, "unknown"], do: nil, else: value)

  # A moment as a reader reads it, in UTC: 13 Nov 2026 12:37:05 UTC.
  defp time(value) do
    case DateTime.from_iso8601(to_string(value || "")) do
      {:ok, at, _} -> Calendar.strftime(DateTime.truncate(at, :second), "%-d %b %Y %H:%M:%S UTC")
      _ -> nil
    end
  end

  # How long from one moment to another: 1 h 05 min, 4 min 10 s, 12 s.
  defp duration(from, to) do
    with {:ok, from, _} <- DateTime.from_iso8601(to_string(from || "")),
         {:ok, to, _} <- DateTime.from_iso8601(to_string(to || "")),
         seconds when seconds >= 0 <- DateTime.diff(to, from) do
      h = div(seconds, 3600)
      min = div(rem(seconds, 3600), 60)
      s = rem(seconds, 60)

      cond do
        h > 0 -> "#{h} h #{String.pad_leading(to_string(min), 2, "0")} min"
        min > 0 -> "#{min} min #{s} s"
        true -> "#{s} s"
      end
    else
      _ -> nil
    end
  end

  defp page(title, back, blocks, markup \\ []) do
    content =
      Enum.with_index(blocks, fn block, index ->
        case block do
          {id, value} -> {id, value}
          value -> {"worker-#{index}", value}
        end
      end)

    Map.merge(%{title: title, back: back}, Blocks.view_model(content, markup))
  end
end

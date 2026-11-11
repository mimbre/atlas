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

  def render({:worker_page, :workers, _}, description, actor, read, _form) do
    case call("worker_overview", %{}, description, actor, read) do
      {:ok, %{"workers" => workers}} ->
        rows =
          for worker <- workers do
            execution = worker["execution"]
            identity = execution["worker"]

            Blocks.row(
              label: identity["worker"],
              detail: "#{identity["machine"]} · #{execution["turn"]} · #{worker["state"]}",
              to: path(execution)
            )
          end

        page("Workers", "/", [
          Blocks.list(
            title: "Running executions",
            rows: rows,
            empty: "No running execution is recorded."
          )
        ])

      {:error, reason} ->
        error(reason, "/")
    end
  end

  def render({:worker_page, mode, params}, description, actor, read, form) do
    execution = target(params)

    case call("worker_inspect", %{"execution" => execution}, description, actor, read) do
      {:ok, %{"view" => view}} ->
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

          detail(view, execution, description, actor, read)
        end

      {:error, reason} ->
        error(reason, "/workers")
    end
  end

  defp detail(view, execution, description, actor, read) do
    descriptor = view["descriptor"]

    pairs = [
      {"Environment", execution["worker"]["environment"]},
      {"Machine", execution["worker"]["machine"]},
      {"Worker", execution["worker"]["worker"]},
      {"Turn", execution["turn"]},
      {"Attempt", execution["attempt"]},
      {"Item", view["item"]},
      {"Item title", view["item_title"]},
      {"State", view["state"]},
      {"State reason", view["reason"]},
      {"Harness", descriptor["harness"]},
      {"Harness version", descriptor["harness_version"]},
      {"Configured model", descriptor["configured_model"]},
      {"Reported model", descriptor["reported_model"]},
      {"Activity", view["activity"]},
      {"Activity timestamp", view["activity_at"]},
      {"Lease until", view["lease_until"]},
      {"Confirmed at", view["confirmed_at"]},
      {"Guidance",
       if(view["guidance"]["available"], do: "Available", else: view["guidance"]["reason"])}
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
        title: "Worker #{execution["worker"]["worker"]}",
        fields: Enum.map(pairs, fn {k, v} -> Blocks.pair(label: k, value: text(v)) end),
        actions: actions
      )

    {history, history_actions} =
      case call("worker_history", %{"execution" => execution}, description, actor, read) do
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

    {output, output_actions} = output(view, execution)

    page(
      "Worker #{execution["worker"]["worker"]}",
      "/workers",
      [{"worker", content}] ++ history ++ [{"worker-output", output}],
      [
        Blocks.part("worker", "worker", title: "Worker", role: "main"),
        Blocks.part("guidance-history", "worker-output", title: "Conversation", role: "related")
      ]
    )
    |> Map.put(:console_actions, history_actions ++ output_actions)
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

  defp output(view, execution) do
    case view["output"] do
      %{"available" => true} ->
        {Blocks.item(
           title: "Worker output",
           fields: [
             Blocks.pair(
               label: "Ephemeral output",
               value: "Output is available for this exact execution; connect to read it."
             )
           ]
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
           title: "Output unavailable",
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

  defp call(op, request, description, actor, read),
    do:
      Workers.handle(op, request, description, actor, read, fn _, _ ->
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

  defp text(nil), do: "Unknown"
  defp text(""), do: "—"
  defp text(value), do: to_string(value)

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

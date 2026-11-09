defmodule AtlasTui.WorkerConversation do
  @moduledoc "Exact-execution durable conversation state behind ordinary worker pages and forms."
  alias AtlasTui.{Blocks, Console, Model, WorkerGuidance, WorkerHistory, WorkerOutput}

  # Backoff for transiently unavailable output, reset when a subscription succeeds.
  @retry 2_000
  @retry_limit 16_000

  defstruct execution: nil,
            mode: nil,
            active: false,
            history: nil,
            guidance: nil,
            output: nil,
            source: nil

  def target(path, environment) when is_binary(path) do
    case Blocks.match(path) do
      {:ok, mode, params} when mode in [:worker, :worker_guidance] ->
        {:ok, execution(params, environment), mode}

      _ ->
        :none
    end
  end

  def target(_, _), do: :none

  def redirected?(model, message) do
    case target(model.console.expected, model.env) do
      {:ok, expected, _} ->
        case target(message["path"], model.env) do
          {:ok, ^expected, _} -> false
          _ -> message["path"] != model.console.expected
        end

      :none ->
        false
    end
  end

  def capture(%{conversation: %{guidance: guidance, execution: execution}} = model)
      when guidance != nil do
    case {target(model.path, model.env), Model.form(model)} do
      {{:ok, ^execution, :worker_guidance}, %Blocks.Form{}} ->
        guidance = WorkerGuidance.update(guidance, guidance.attempted || model.values)

        %{
          model
          | values: guidance.values,
            conversation: %{model.conversation | guidance: guidance}
        }

      _ ->
        model
    end
  end

  def capture(model), do: model

  def install(model, previous) do
    previous = capture(previous)

    case target(model.path, model.env) do
      {:ok, execution, mode} ->
        same = previous.conversation != nil and previous.conversation.execution == execution

        conversation =
          if same,
            do: previous.conversation,
            else: %__MODULE__{
              execution: execution,
              history: WorkerHistory.new(execution),
              output: WorkerOutput.new(execution)
            }

        conversation = %{
          conversation
          | active: true,
            mode: mode,
            source: Map.take(model, [:blocks, :ids, :markup])
        }

        model = %{model | conversation: conversation}

        model =
          if same and model.path == previous.path and selected_history(previous) != nil,
            do: %{model | selected: previous.selected},
            else: model

        model = install_guidance(model)
        restoring = previous.console.restoring

        {history, requests} =
          cond do
            not same ->
              WorkerHistory.load(model.conversation.history)

            restoring ->
              WorkerHistory.refresh(model.conversation.history)

            map_size(model.conversation.history.pending) == 0 ->
              WorkerHistory.refresh(model.conversation.history)

            true ->
              {model.conversation.history, []}
          end

        model = put_in(model.conversation.history, history)

        {model, recovery} =
          if restoring and model.conversation.guidance != nil do
            {guidance, outgoing} = WorkerGuidance.reconnect(model.conversation.guidance)
            {put_in(model.conversation.guidance, guidance), outgoing}
          else
            {model, []}
          end

        {project(model), effects(requests ++ recovery)}

      :none ->
        conversation = previous.conversation
        conversation = if conversation, do: %{conversation | active: false}, else: nil
        {%{model | conversation: conversation}, []}
    end
  end

  def submit(model, params, values) do
    model = capture(model)
    conversation = model.conversation
    supplied = execution(params || %{}, model.env)

    if conversation != nil and conversation.active and conversation.mode == :worker_guidance and
         conversation.execution == supplied and conversation.guidance != nil do
      {guidance, requests} = WorkerGuidance.submit(conversation.guidance, values)
      model = put_in(model.conversation.guidance, guidance)
      {project(model), effects(requests)}
    else
      {%{
         model
         | notice: %{tone: "error", text: "Guidance target changed; open the exact turn again."}
       }, []}
    end
  end

  def receive(%{conversation: nil} = model, _message), do: {model, []}

  def receive(model, message) do
    conversation = model.conversation
    {history, history_requests} = WorkerHistory.receive(conversation.history, message)

    {guidance, guidance_requests} =
      if conversation.guidance,
        do: WorkerGuidance.receive(conversation.guidance, message),
        else: {nil, []}

    accepted =
      guidance != nil and guidance.status == :accepted and
        conversation.guidance.status != :accepted

    conversation = %{conversation | history: history, guidance: guidance}
    model = %{model | conversation: conversation}
    outgoing = effects(history_requests ++ guidance_requests)

    if accepted and conversation.active and conversation.mode == :worker_guidance do
      {history, requests} = WorkerHistory.refresh(history)
      model = put_in(model.conversation.history, history)
      {model, navigation} = Console.navigate(project(model), detail_path(conversation.execution))
      {model, outgoing ++ effects(requests) ++ navigation}
    else
      {project(model), outgoing}
    end
  end

  def history_next(%{conversation: %{active: true}} = model) do
    {history, requests} = WorkerHistory.next(model.conversation.history)
    {project(put_in(model.conversation.history, history)), effects(requests)}
  end

  def history_next(model), do: {model, []}

  def receipts(%{conversation: %{active: true}} = model, interaction) do
    {history, requests} = WorkerHistory.receipts(model.conversation.history, interaction)
    {project(put_in(model.conversation.history, history)), effects(requests)}
  end

  def receipts(model, _interaction), do: {model, []}

  def action(%{conversation: %{active: true} = conversation} = model, operation) do
    if operation["execution"] == conversation.execution do
      case operation["name"] do
        "worker_history" ->
          if operation["cursor"] do
            history_next(model)
          else
            {history, requests} = WorkerHistory.refresh(conversation.history)
            {project(put_in(model.conversation.history, history)), effects(requests)}
          end

        "worker_receipts" ->
          if operation["interaction_source"] == "selected_history",
            do: receipts(model, selected_history(model)),
            else: {model, []}

        "worker_output_subscribe" ->
          output = WorkerOutput.disconnect(conversation.output)
          {project(put_in(model.conversation.output, output)), [:worker_output_restart]}
      end
    else
      {%{
         model
         | notice: %{
             tone: "error",
             text: "Worker action does not target the displayed execution."
           }
       }, []}
    end
  end

  def action(model, _operation), do: {model, []}

  def action_available?(
        %{conversation: %{active: true} = conversation} = model,
        %{"name" => name} = operation
      )
      when name in ["worker_history", "worker_receipts", "worker_output_subscribe"] do
    history = conversation.history

    operation["execution"] == conversation.execution and
      case name do
        "worker_history" ->
          map_size(history.pending) == 0 and
            (operation["cursor"] == nil or (history.loaded and history.more))

        "worker_receipts" ->
          key = selected_history(model)
          page = history.receipt_pages[key]

          operation["interaction_source"] == "selected_history" and key != nil and
            map_size(history.pending) == 0 and
            (page == nil or not page.loaded or page.more or page.stale)

        "worker_output_subscribe" ->
          true
      end
  end

  def action_available?(_model, %{"name" => name}),
    do: name not in ["worker_history", "worker_receipts", "worker_output_subscribe"]

  defp selected_history(model) do
    selected =
      Enum.flat_map(Model.lists(model), fn {id, %Blocks.List{rows: rows}} ->
        Enum.map(rows || [], &{id, &1.id})
      end)
      |> Enum.at(model.selected)

    case selected do
      {"guidance-history", key} ->
        if Enum.any?(model.conversation.history.interactions, &(&1["key"] == key)),
          do: key

      _ ->
        nil
    end
  end

  def output_target(
        %{
          connected: true,
          console: %{phase: :ready},
          conversation: %{active: true} = conversation
        } = model
      ) do
    expected = target(model.console.expected, model.env)

    if (conversation.output.status not in [:unsupported, :unavailable, :error, :ended] or
          WorkerOutput.retryable?(conversation.output)) and
         (model.console.expected == nil or
            match?({:ok, execution, _} when execution == conversation.execution, expected)),
       do: conversation.execution,
       else: nil
  end

  def output_target(_model), do: nil

  def output_connected(model) do
    model =
      if model.notice && model.notice[:source] == :worker_output,
        do: %{model | notice: nil},
        else: model

    {output, requests} = WorkerOutput.connect(model.conversation.output)
    {project(put_in(model.conversation.output, output)), output_effects(requests)}
  end

  def output_receive(model, message) do
    {output, requests} = WorkerOutput.receive(model.conversation.output, message)
    model = project(put_in(model.conversation.output, output))

    poll =
      cond do
        output.status == :ready and map_size(output.pending) == 0 ->
          [{:worker_output_poll, if(output.more, do: 0, else: 250)}]

        WorkerOutput.retryable?(output) ->
          [{:worker_output_retry, min(@retry * 2 ** output.retries, @retry_limit)}]

        true ->
          []
      end

    {model, output_effects(requests) ++ poll}
  end

  def output_next(model) do
    {output, requests} = WorkerOutput.next(model.conversation.output)
    {put_in(model.conversation.output, output), output_effects(requests)}
  end

  def output_disconnected(%{conversation: %{output: output}} = model) when output != nil do
    if output.status in [:unsupported, :unavailable, :error, :ended],
      do: model,
      else: project(put_in(model.conversation.output, WorkerOutput.disconnect(output)))
  end

  def output_disconnected(model), do: model

  defp output_effects(requests), do: Enum.map(requests, &{:worker_output_send, &1})

  defp install_guidance(model) do
    case Model.form(model) do
      %Blocks.Form{submit_to: %Blocks.Call{endpoint: "queue_worker_guidance", params: params}} ->
        conversation = model.conversation

        if execution(params || %{}, model.env) == conversation.execution do
          guidance = conversation.guidance

          guidance =
            if guidance == nil or guidance.status == :accepted,
              do: WorkerGuidance.new(conversation.execution, model.values),
              else: guidance

          %{model | values: guidance.values, conversation: %{conversation | guidance: guidance}}
        else
          model
        end

      _ ->
        model
    end
  end

  defp project(%{conversation: %{active: false}} = model), do: model
  defp project(%{conversation: nil} = model), do: model

  defp project(model) do
    conversation = model.conversation
    model = struct(model, conversation.source)
    guidance = conversation.guidance
    status = guidance_blocks(guidance)

    history =
      if conversation.history.loaded,
        do: history_blocks(conversation),
        else: []

    history_error =
      if not conversation.history.loaded and map_size(conversation.history.errors) > 0,
        do: WorkerHistory.blocks(conversation.history),
        else: []

    model =
      cond do
        history != [] and "guidance-history" in model.ids and "guidance-details" in model.ids ->
          model
          |> replace("guidance-history", [hd(history)])
          |> replace("guidance-details", tl(history) ++ status)

        "guidance-history" in model.ids ->
          entries =
            if history == [],
              do: [
                {"guidance-history",
                 Enum.at(model.blocks, Enum.find_index(model.ids, &(&1 == "guidance-history")))}
              ],
              else: history

          replace(model, "guidance-history", entries ++ history_error ++ status)

        true ->
          append(model, status)
      end

    # Control places what the worker said (`worker-output`) and the output's own state
    # (`worker-output-details`); this fills both from the exact execution's output.
    model =
      if "worker-output" in model.ids and
           (conversation.output.cursor != nil or conversation.output.status != :detached) do
        placeholder =
          case block(model, "worker-output") do
            %Blocks.Item{} = item -> item
            _ -> nil
          end

        model =
          replace(
            model,
            "worker-output",
            WorkerOutput.conversation(conversation.output, placeholder)
          )

        if "worker-output-details" in model.ids,
          do: replace(model, "worker-output-details", WorkerOutput.details(conversation.output)),
          else: model
      else
        model
      end

    model =
      if guidance != nil and conversation.mode == :worker_guidance and Model.form(model) == nil do
        append(model, [
          {"worker-retained-draft",
           %Blocks.Item{
             title: "Retained guidance draft — no available form for this exact turn",
             fields: [
               %Blocks.Pair{label: "Exact target", value: target_text(conversation.execution)},
               %Blocks.Pair{label: "Submission key", value: guidance.values["client_key"]},
               %Blocks.Pair{label: "Literal guidance", value: guidance.values["body"]},
               %Blocks.Pair{label: "Why", value: guidance.values["cause"]}
             ]
           }}
        ])
      else
        model
      end

    if guidance != nil and conversation.mode == :worker_guidance,
      do: %{model | values: guidance.values, waiting: guidance.status in [:submitting, :querying]},
      else: model
  end

  defp history_blocks(conversation) do
    rows =
      Enum.map(conversation.history.interactions, fn interaction ->
        %Blocks.Row{
          id: interaction["key"],
          label: interaction["body"],
          detail: interaction["actor"] <> " · " <> interaction["projection"]["proven"],
          to: detail_path(conversation.execution)
        }
      end)

    [
      {"guidance-history",
       %Blocks.List{title: "Recorded guidance", rows: rows, empty: "No recorded guidance"}}
      | WorkerHistory.blocks(conversation.history)
    ]
  end

  defp guidance_blocks(nil), do: []
  defp guidance_blocks(%{status: :draft, error: nil}), do: []

  defp guidance_blocks(guidance) do
    status =
      case guidance.status do
        :submitting -> "Awaiting durable confirmation; this is not delivery evidence."
        :querying -> "Checking the exact submission key before any retry."
        :retryable -> "Not recorded. An explicit submit retries the same payload and key."
        :unknown -> "Outcome unknown. Query is required before any retry."
        :accepted -> "Recorded; delivery and consumption require separate receipt evidence."
        :error -> "Submission refused. The draft and exact target are retained."
        :draft -> "Draft retained."
      end

    fields = [
      %Blocks.Pair{label: "Status", value: status},
      %Blocks.Pair{label: "Exact target", value: target_text(guidance.execution)},
      %Blocks.Pair{label: "Submission key", value: guidance.values["client_key"]}
    ]

    fields =
      if guidance.error,
        do:
          fields ++
            [
              %Blocks.Pair{
                label: "Reason",
                value: guidance.error["message"] || guidance.error["code"]
              }
            ],
        else: fields

    [{"worker-guidance-status", %Blocks.Item{title: "Exact-turn guidance", fields: fields}}]
  end

  defp target_text(execution) do
    worker = execution["worker"]

    Enum.join(
      [
        worker["environment"],
        worker["machine"],
        worker["worker"],
        execution["turn"],
        execution["attempt"]
      ],
      " / "
    )
  end

  defp block(model, id) do
    case Enum.find_index(model.ids, &(&1 == id)) do
      nil -> nil
      at -> Enum.at(model.blocks, at)
    end
  end

  defp replace(model, id, entries) do
    at = Enum.find_index(model.ids, &(&1 == id))
    ids = Enum.map(entries, &elem(&1, 0))
    blocks = Enum.map(entries, &elem(&1, 1))

    markup =
      Enum.map(model.markup, fn entry ->
        entry = if entry["start"] == id, do: Map.put(entry, "start", hd(ids)), else: entry
        if entry["end"] == id, do: Map.put(entry, "end", List.last(ids)), else: entry
      end)

    %{
      model
      | ids: Enum.take(model.ids, at) ++ ids ++ Enum.drop(model.ids, at + 1),
        blocks: Enum.take(model.blocks, at) ++ blocks ++ Enum.drop(model.blocks, at + 1),
        markup: markup
    }
  end

  defp append(model, entries) do
    %{
      model
      | ids: model.ids ++ Enum.map(entries, &elem(&1, 0)),
        blocks: model.blocks ++ Enum.map(entries, &elem(&1, 1))
    }
  end

  defp execution(params, environment) do
    get = fn key -> Map.get(params, key) || Map.get(params, Atom.to_string(key)) end

    %{
      "worker" => %{
        "environment" => environment,
        "machine" => get.(:machine),
        "worker" => get.(:worker)
      },
      "turn" => get.(:turn),
      "attempt" => get.(:attempt)
    }
  end

  defp detail_path(execution) do
    Blocks.path(:worker, %{
      machine: execution["worker"]["machine"],
      worker: execution["worker"]["worker"],
      turn: execution["turn"],
      attempt: execution["attempt"]
    })
  end

  defp effects(requests), do: Enum.map(requests, &{:send, &1})
end

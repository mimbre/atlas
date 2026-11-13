defmodule AtlasBFFContract.Console do
  @moduledoc "Console presentation vocabulary. Operations are data, never dynamic calls."

  @contexts ~w(browse form confirm ask plan_planning plan_proposed plan_running plan_done step_form legend)
  @tokens ~w(Tab Shift+Tab Up Down Left Right Home End PageUp PageDown Enter Esc Backspace Space Ctrl+C Ctrl+S)
  @local ~w(list_next list_previous open_selected scroll_up scroll_down submit cancel tab_next tab_previous move_next move_previous select_first select_last page_next page_previous part_next part_previous back refresh quit legend_open legend_close sections_toggle focus_next focus_previous submit_form cancel_form form_enter input_up input_down input_left input_right input_home input_end input_backspace ask_send ask_cancel plan_cancel plan_run plan_toggle plan_edit plan_previous plan_next plan_stop plan_close step_save step_cancel)
  @worker ~w(worker_history worker_receipts worker_output_subscribe)

  defdelegate compile(page), to: AtlasBFFContract.Console.Projection
  defdelegate active(projection, current), to: AtlasBFFContract.Console.Projection
  defdelegate bindings(projection, current), to: AtlasBFFContract.Console.Projection
  defdelegate capture(projection, token, current), to: AtlasBFFContract.Console.Projection
  defdelegate resolve(projection, event, current), to: AtlasBFFContract.Console.Projection

  def presentation_names, do: %{blocks: ["console_action"], markup: ["legend"]}

  def contexts, do: @contexts
  def named_keys, do: @tokens
  def operations, do: @local ++ ~w(open open_url agent_ask) ++ @worker

  def key?(key) when is_binary(key),
    do:
      key in @tokens or
        (String.valid?(key) and String.length(key) == 1 and String.printable?(key) and
           not String.match?(key, ~r/[\x00-\x1f\x7f]/))

  def key?(_), do: false

  def operation?(%{"name" => name, "execution" => execution} = op) when name in @worker do
    allowed =
      if name == "worker_receipts",
        do: ~w(name execution interaction_source),
        else: ~w(name execution cursor)

    Map.keys(op) -- allowed == [] and execution?(execution) and
      if name == "worker_receipts" do
        op["interaction_source"] == "selected_history"
      else
        not Map.has_key?(op, "cursor") or text?(op["cursor"], 2_048)
      end
  end

  def operation?(%{"name" => name} = op) do
    {required, optional} =
      cond do
        name == "open" -> {["name", "to"], []}
        name == "open_url" -> {["name", "url"], []}
        name == "agent_ask" -> {["name"], ["intent"]}
        name in @local -> {["name"], []}
        true -> {[], []}
      end

    required != [] and Map.keys(op) -- (required ++ optional) == [] and
      Enum.all?(required, &text?(op[&1], 2_048)) and
      Enum.all?(optional, &(not Map.has_key?(op, &1) or text?(op[&1], 128))) and
      destination?(name, op)
  end

  def operation?(_), do: false

  defp execution?(%{"worker" => worker, "turn" => turn, "attempt" => attempt} = execution)
       when map_size(execution) == 3 and is_map(worker) and map_size(worker) == 3 do
    Enum.all?(
      [worker["environment"], worker["machine"], worker["worker"], turn, attempt],
      &text?(&1, 2_048)
    )
  end

  defp execution?(_), do: false

  defp destination?("open", op) do
    schema = AtlasBFFContract.Contract.__schema__()

    if String.starts_with?(op["to"], "/") do
      case AtlasBFF.Paths.match(schema.pages, op["to"]) do
        {:ok, name, params} ->
          Enum.all?(Map.values(params), &(is_binary(&1) and String.valid?(&1) and &1 != "")) and
            AtlasBFF.Paths.build(schema.pages, name, params) == op["to"]

        _ ->
          false
      end
    else
      false
    end
  end

  defp destination?("open_url", op) do
    case URI.new(op["url"]) do
      {:ok, uri} ->
        uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
          not String.match?(op["url"], ~r/[\s\x00-\x1f\x7f]/)

      _ ->
        false
    end
  end

  defp destination?(_, _), do: true

  defp text?(value, max),
    do:
      is_binary(value) and byte_size(value) <= max and String.valid?(value) and
        String.trim(value) != ""
end

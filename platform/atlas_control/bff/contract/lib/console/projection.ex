defmodule AtlasBFFContract.Console.Projection do
  @moduledoc "Validated current-projection index. Bindings and legends retain the same action blocks."
  alias AtlasBFFContract.Console
  defstruct [:path, :revision, actions: [], groups: [], ids: []]

  def compile(page) when is_map(page) do
    blocks = page["blocks"]
    markup = page["markup"]

    with true <- text?(page["path"], 2_048) and text?(page["actions_revision"], 128),
         true <- is_list(blocks) and length(blocks) <= 512,
         true <- is_list(markup) and length(markup) <= 256,
         true <- Enum.all?(blocks, &block_shape?/1),
         true <- Enum.all?(markup, &markup_shape?/1),
         true <- byte_size(JSON.encode!(page)) <= 3_000_000,
         ids = Enum.map(blocks, & &1["id"]),
         :ok <- AtlasBFF.Markup.check(ids, markup),
         actions = Enum.filter(blocks, &(&1["type"] == "console_action")),
         native = Enum.reject(blocks, &(&1["type"] == "console_action")),
         groups = Enum.filter(markup, &(&1["kind"] == "legend")),
         true <- length(actions) in 1..256 and groups != [],
         true <- Enum.all?(actions, &action?(&1, native, page)),
         true <- groups?(groups, blocks, actions),
         true <- unique_bindings?(actions) do
      {:ok,
       %__MODULE__{
         path: page["path"],
         revision: page["actions_revision"],
         actions: actions,
         groups: groups,
         ids: ids
       }}
    else
      _ -> {:error, :invalid_console_projection}
    end
  end

  def compile(_), do: {:error, :invalid_console_projection}

  def active(%__MODULE__{} = p, current) when is_map(current) do
    if current[:context] in Console.contexts() and current[:path] == p.path and
         is_integer(current[:generation]) and current.generation >= 0 do
      {:ok,
       Enum.filter(p.actions, fn action ->
         scope = action["props"]["scope"]

         scope["context"] == current.context and
           (scope["row"] == nil or {scope["on"], scope["row"]} == {current[:on], current[:row]})
       end)}
    else
      {:error, :stale_context}
    end
  end

  def active(_, _), do: {:error, :invalid_console_projection}

  def bindings(p, current) do
    with {:ok, actions} <- active(p, current) do
      {:ok,
       for(
         a <- actions,
         a["props"]["available"],
         key <- a["props"]["keys"],
         into: %{},
         do: {key, a}
       )}
    end
  end

  def capture(p, token, current) do
    with true <- Console.key?(token),
         {:ok, bindings} <- bindings(p, current),
         action when is_map(action) <- bindings[token] do
      {:ok,
       %{
         id: action["id"],
         revision: p.revision,
         path: p.path,
         context: current.context,
         generation: current.generation,
         selected: {current[:on], current[:row]}
       }}
    else
      _ -> {:error, :unavailable_binding}
    end
  end

  def resolve(%__MODULE__{} = p, event, current) when is_map(event) and is_map(current) do
    with true <- event[:revision] == p.revision and event[:path] == p.path,
         true <-
           event[:context] == current[:context] and event[:generation] == current[:generation],
         true <- event[:selected] == {current[:on], current[:row]},
         {:ok, actions} <- active(p, current),
         action when is_map(action) <- Enum.find(actions, &(&1["id"] == event[:id])),
         true <- action["props"]["available"] do
      {:ok, action}
    else
      _ -> {:error, :stale_or_unavailable_action}
    end
  end

  def resolve(_, _, _), do: {:error, :stale_or_unavailable_action}

  defp action?(%{"props" => p}, native, page) do
    scope = p["scope"]
    keys = p["keys"]

    is_map(p) and Map.keys(p) -- ~w(label keys operation scope available reason) == [] and
      text?(p["label"], 256) and p["available"] in [true, false] and
      (p["reason"] == nil or text?(p["reason"], 512)) and
      is_list(keys) and length(keys) in 1..8 and Enum.uniq(keys) == keys and
      Enum.all?(keys, &Console.key?/1) and
      Console.operation?(p["operation"]) and is_map(scope) and
      Map.keys(scope) -- ~w(page revision context on row) == [] and
      scope["page"] == page["path"] and scope["revision"] == page["actions_revision"] and
      scope["context"] in Console.contexts() and reference?(scope, native) and
      (p["operation"]["name"] != "worker_receipts" or scope["on"] == "guidance-history")
  end

  defp reference?(scope, native) do
    case {scope["on"], scope["row"]} do
      {nil, nil} ->
        true

      {on, row} ->
        text?(on, 2_048) and
          case Enum.find(native, &(&1["id"] == on)) do
            nil ->
              false

            block when row == nil ->
              is_map(block)

            %{"type" => "list", "props" => %{"rows" => rows}} when is_list(rows) ->
              text?(row, 2_048) and
                Enum.any?(rows, &(is_map(&1) and (&1["id"] || &1["to"]) == row))

            _ ->
              false
          end
    end
  end

  defp groups?(groups, blocks, actions) do
    ids = Enum.map(blocks, & &1["id"])

    memberships =
      Enum.flat_map(groups, fn group ->
        p = group["props"]
        from = Enum.find_index(ids, &(&1 == group["start"]))
        finish = Enum.find_index(ids, &(&1 == group["end"]))

        if text?(p["title"], 128) and p["context"] in Console.contexts() do
          for b <- Enum.slice(blocks, from..finish), do: {b["id"], b["type"], p["context"]}
        else
          [{nil, nil, nil}]
        end
      end)

    Enum.all?(memberships, fn {id, type, context} ->
      type == "console_action" and
        Enum.any?(actions, &(&1["id"] == id and &1["props"]["scope"]["context"] == context))
    end) and
      Enum.sort(Enum.map(memberships, &elem(&1, 0))) == Enum.sort(Enum.map(actions, & &1["id"]))
  end

  defp unique_bindings?(actions) do
    Enum.all?(Enum.with_index(actions), fn {a, index} ->
      Enum.all?(Enum.drop(actions, index + 1), fn b ->
        x = a["props"]
        y = b["props"]
        same_context = x["scope"]["context"] == y["scope"]["context"]

        overlap =
          x["scope"]["row"] == nil or y["scope"]["row"] == nil or
            {x["scope"]["on"], x["scope"]["row"]} == {y["scope"]["on"], y["scope"]["row"]}

        not (x["available"] and y["available"] and same_context and overlap and
               Enum.any?(x["keys"], &(&1 in y["keys"])))
      end)
    end)
  end

  defp block_shape?(%{"id" => id, "type" => type, "props" => props}),
    do: text?(id, 128) and text?(type, 64) and is_map(props)

  defp block_shape?(_), do: false

  defp markup_shape?(%{"kind" => k, "start" => a, "end" => b, "props" => p}),
    do: text?(k, 64) and text?(a, 128) and text?(b, 128) and is_map(p)

  defp markup_shape?(_), do: false

  defp text?(v, max),
    do: is_binary(v) and byte_size(v) in 1..max and String.valid?(v) and String.trim(v) != ""
end

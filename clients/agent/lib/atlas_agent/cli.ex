defmodule AtlasAgent.CLI do
  @moduledoc """
  `atlas put|set|get|list --env <env> ...` (or `mix atlas.agent ...` in clients/agent):

      atlas put  <kind> [--in <key>] --<field> <text> ...  create; prints the new item
                 --link <association>=<key>[,<key>]       and link it, right after (repeatable)
      atlas set  <key> <field>=<text> ...                  change; prints the item
                 <association>=<key>                       link (empty: remove the link)
                 --cause <text>                            why (put and set), kept with it
      atlas get  <key>                                     one item, with what hangs under it
      atlas list <kind> [--in <key>]                       the items of a kind (under <key>)
      atlas delete <key>                                   delete; refused while anything hangs under it
      atlas turn                                          its running turn, original item and instructions
      atlas turn end <outcome>                            store its outcome; Runtime ends the turn
      atlas tools                                          the agent's tools: Control's actions
      atlas plan --on <key or path> <request ...>          what the agent proposes; writes nothing

  Every command takes --json: it then prints one JSON value on stdout, the item, the
  list, or `{"refused": [reasons]}` / `{"error": text}`. Without it, short text.
  A failed list also retains `code` when Control supplies a typed Facts failure.
  A value of `-` is read from stdin; `--<field>-file <path>` (put) and `<field>=@<path>`
  (set) read it from a file, for text of several lines. Which kinds exist and which
  fields a form asks for come from Control; a wrong one is answered with what it asks.

  Exit status: 0 done, 1 refused (the reasons also on stderr), 2 a usage or connection
  error. prod is the default environment, as for `atlas`.
  """

  def main(args) do
    {env, args} = take_flag(args, "--env", "prod")

    # The agent behind the TUI's `:` speaks JSON lines with the TUI until its stdin ends.
    if args == ["steer"], do: AtlasAgent.Steer.main(env), else: command(env, args)
  end

  defp command(env, args) do
    {json, args} = take_switch(args, "--json")

    result =
      with {:ok, command} <- parse(args),
           {:ok, client} <- AtlasAgent.connect(env) do
        try do
          run(command, client)
        after
          AtlasAgent.Client.close(client)
        end
      end

    show(result, json)
  end

  # Commands

  # Help asks Control what can be made: the kinds come from rela's description, never
  # from this code. `atlas help [<kind>]`, `atlas <command> [<kind>] --help`.
  # `atlas help` prints bin/atlas's own usage first, so only the kinds come from here.
  defp parse(["runtime-discover" | args]) do
    case AtlasAgent.Protocol.options(:runtime_discovery_options, args) do
      {:ok, options} -> {:ok, {:runtime_discovery, options["machine"]}}
      {:invalid, why} -> {:error, why}
    end
  end

  defp parse(["help" | rest]), do: {:ok, {:help, List.first(rest), false}}

  defp parse(["turn"]), do: {:ok, :turn}
  defp parse(["turn", "end", outcome]), do: {:ok, {:turn_end, outcome}}

  defp parse(["tools"]), do: {:ok, :tools}

  defp parse(["plan" | rest]) do
    case take_flag(rest, "--on", nil) do
      {nil, _} ->
        {:error, "plan needs --on <key or path>: the page the request is made on\n" <> usage()}

      {on, words} when words != [] ->
        with {:ok, request} <- read(Enum.join(words, " ")), do: {:ok, {:plan, on, request}}

      _ ->
        {:error, "plan needs a request\n" <> usage()}
    end
  end

  defp parse(["delete", key]), do: {:ok, {:delete, key}}

  defp parse([command | rest]) when command in ~w(put set get list) do
    if "--help" in rest or "-h" in rest,
      do:
        {:ok,
         {:help, if(command in ~w(put list), do: List.first(rest -- ["--help", "-h"])), true}},
      else: parse_command([command | rest])
  end

  defp parse(_), do: {:error, usage()}

  defp parse_command(["put", kind | rest]) do
    {parent, rest} = take_flag(rest, "--in", nil)
    {cause, rest} = take_flag(rest, "--cause", nil)

    with {:ok, links, rest} <- links(rest, %{}, []),
         {:ok, values} <- options(rest, %{}),
         do: {:ok, {:put, kind, values, parent, cause, links}}
  end

  defp parse_command(["set", key | assignments]) when assignments != [] do
    {cause, assignments} = take_flag(assignments, "--cause", nil)

    with {:ok, values} <- assignments(assignments, %{}),
         do: {:ok, {:set, key, values, cause}}
  end

  defp parse_command(["get", key]), do: {:ok, {:get, key}}

  defp parse_command(["list", kind | rest]) do
    case take_flag(rest, "--in", nil) do
      {parent, []} -> {:ok, {:list, kind, parent}}
      {_, more} -> {:error, "unexpected #{Enum.join(more, " ")}\n" <> usage()}
    end
  end

  defp parse_command(_), do: {:error, usage()}

  # A write answers with the item as it is now stored.
  defp run({:runtime_discovery, machine}, client),
    do: AtlasAgent.RuntimeDiscovery.read(client, machine)

  # Links go through each association's own form once the fact is there; when one is
  # refused, the fact stays made and the refusal names its key, so it can be linked again.
  defp run({:put, kind, values, parent, cause, links}, client) do
    case AtlasAgent.put(client, kind, values, parent, cause) do
      {:ok, key} when links == %{} ->
        then_get({:ok, key}, client)

      {:ok, key} ->
        case AtlasAgent.set(client, key, links, cause) do
          {:ok, key} -> then_get({:ok, key}, client)
          {:refused, reasons} -> {:refused, ["#{key} is made, but not linked" | reasons]}
          {:error, text} -> {:error, "#{key} is made, but not linked: #{text}"}
          other -> other
        end

      other ->
        other
    end
  end

  defp run({:set, key, values, cause}, client),
    do: client |> AtlasAgent.set(key, values, cause) |> then_get(client)

  defp run({:get, key}, client), do: client |> AtlasAgent.get(key) |> as(:item)

  defp run({:help, kind, usage?}, client) do
    with {:ok, kinds} <- AtlasAgent.kinds(client) do
      chosen = if kind, do: Enum.filter(kinds, &(&1["kind"] == kind)), else: kinds

      if kind && chosen == [] do
        names = Enum.map_join(kinds, ", ", & &1["kind"])
        {:error, "Atlas has no kind #{inspect(kind)}; it has #{names}"}
      else
        {:help, chosen, usage?}
      end
    end
  end

  defp run({:list, kind, nil}, client),
    do: client |> AtlasAgent.list(kind, nil, typed_errors: true) |> as(:list)

  defp run({:list, kind, parent}, client),
    do: client |> AtlasAgent.list(kind, parent) |> as(:list)

  defp run({:delete, key}, client), do: client |> AtlasAgent.delete(key) |> as(:deleted)

  defp run(:turn, client) do
    with {:ok, context} <- AtlasAgent.Client.turn(client),
         {:ok, item} <- AtlasAgent.get(client, context["on"]) do
      {:turn, Map.put(context, "item", item)}
    end
  end

  defp run({:turn_end, outcome}, client) do
    with {:ok, context} <- AtlasAgent.Client.turn(client),
         {:ok, _} <-
           AtlasAgent.Client.turn(
             client,
             AtlasAgent.Protocol.message(:turn_end, :turn_end,
               key: context["key"],
               outcome: outcome
             )
           ) do
      {:outcome, %{"turn" => context["key"], "outcome" => outcome}}
    end
  end

  defp run(:tools, client), do: client |> AtlasAgent.Tools.list() |> as(:tools)

  defp run({:plan, on, request}, client) do
    with {:ok, settings} <- AtlasAgent.settings(client.env),
         do: client |> AtlasAgent.Plan.make(settings, on, request) |> as(:plan)
  end

  defp then_get({:ok, key}, client), do: client |> AtlasAgent.get(key) |> as(:item)
  defp then_get(other, _client), do: other

  defp as({:ok, value}, what), do: {what, value}
  defp as(other, _what), do: other

  # Output

  defp show({:runtime_discovery, reply, code}, true), do: json(reply, code)

  defp show({:runtime_discovery, reply, code}, false) do
    if code == 0,
      do:
        IO.puts(
          "Runtime #{reply["target"]["machine"]}: endpoint #{if reply["availability"]["registered"], do: "registered", else: "absent"}; health unproven"
        ),
      else:
        IO.puts(
          :stderr,
          "Runtime discovery: #{reply["error"]["code"]}: #{reply["error"]["message"]}"
        )

    code
  end

  defp show({:turn, context}, true), do: json(context, 0)

  # What the worker reads first (the item's anchors and the standing rules), then the item.
  defp show({:turn, context}, false) do
    first = if context["read_first"], do: context["read_first"] <> "\n\n", else: ""

    IO.puts("Turn #{context["key"]} on #{context["on"]}\n\n" <> first <> text(context["item"])) &&
      0
  end

  defp show({:outcome, outcome}, true), do: json(outcome, 0)

  defp show({:outcome, outcome}, false),
    do: IO.puts("Outcome stored for #{outcome["turn"]}: #{outcome["outcome"]}") && 0

  defp show({:item, item}, true), do: json(item, 0)
  defp show({:list, rows}, true), do: json(rows, 0)
  defp show({:help, kinds, _usage?}, true), do: json(kinds, 0)
  defp show({:deleted, key}, true), do: json(%{"deleted" => key}, 0)
  defp show({:deleted, key}, false), do: IO.puts("Deleted #{key}.") && 0
  defp show({:tools, tools}, true), do: json(tools, 0)
  defp show({:plan, plan}, true), do: json(plan, 0)
  defp show({:tools, tools}, false), do: IO.puts(tools_text(tools)) && 0
  defp show({:plan, plan}, false), do: IO.puts(plan_text(plan)) && 0
  defp show({:help, kinds, usage?}, false), do: IO.puts(help(kinds, usage?)) && 0
  defp show({:item, item}, false), do: IO.puts(text(item)) && 0

  defp show({:list, rows}, false) do
    Enum.each(rows_text(rows, ""), &IO.puts/1)
    0
  end

  defp show({:refused, reasons}, json?) do
    IO.puts(:stderr, "refused: " <> Enum.join(reasons, "; "))
    if json?, do: json(%{"refused" => reasons}, 1), else: 1
  end

  defp show({:error, text}, json?) do
    IO.puts(:stderr, "atlas: " <> text)
    if json?, do: json(%{"error" => text}, 2), else: 2
  end

  defp show({:error, text, code}, true) do
    IO.puts(:stderr, "atlas: " <> text)
    json(%{"error" => text, "code" => code}, 2)
  end

  defp show({:error, text, _code}, false), do: show({:error, text}, false)

  defp json(value, status) do
    IO.puts(JSON.encode!(value))
    status
  end

  defp text(item) do
    fields =
      Enum.map(item["fields"], fn [label, value] ->
        origin = origin_text(item["origins"][label])

        case String.split(value || "", "\n") do
          [line] when origin != "" ->
            "  #{label}: #{line} (#{origin})"

          [line] ->
            "  #{label}: #{line}"

          lines ->
            "  #{label}:\n" <> Enum.map_join(lines, "\n", &String.trim_trailing("    " <> &1))
        end
      end)

    lists =
      Enum.map(item["lists"], fn list ->
        rows = rows_text(list["rows"], "  ")
        rows = if rows == [], do: ["  (none)"], else: rows
        Enum.join(["#{list["title"] || "Under it"}:" | rows], "\n")
      end)

    Enum.join(todo_text(item["todo"]) ++ [item["title"] | fields] ++ lists, "\n")
  end

  # What to do, for its owner, before the rest (IS-Atlas-54).
  defp todo_text(nil), do: []

  defp todo_text(todo) do
    fields =
      Enum.map(todo["fields"], fn [label, value] ->
        case String.split(value || "", "\n") do
          [line] ->
            "  #{label}: #{line}"

          lines ->
            "  #{label}:\n" <> Enum.map_join(lines, "\n", &String.trim_trailing("    " <> &1))
        end
      end)

    [todo["title"] | fields] ++ [""]
  end

  # The fact that set a link: "since 3 Nov 15:10, by melle: why", in local time.
  defp origin_text(nil), do: ""

  defp origin_text(origin) do
    since =
      case DateTime.from_iso8601(origin["since"] || "") do
        {:ok, at, _} ->
          {{y, mo, d}, {h, mi, _}} =
            at
            |> DateTime.to_naive()
            |> NaiveDateTime.to_erl()
            |> :calendar.universal_time_to_local_time()

          "since " <>
            Calendar.strftime(NaiveDateTime.from_erl!({{y, mo, d}, {h, mi, 0}}), "%-d %b %H:%M")

        _ ->
          nil
      end

    by = origin["by"] && "by " <> origin["by"]
    head = [since, by] |> Enum.reject(&is_nil/1) |> Enum.join(", ")

    case origin["cause"] do
      cause when cause in [nil, ""] -> head
      cause -> head <> ": " <> cause
    end
  end

  # Rows as the TUI shows them: the id in a column as wide as the longest, the label in
  # the next (up to 60 wide), then the detail.
  defp rows_text(rows, indent) do
    width = fn field, most ->
      rows |> Enum.map(&String.length(&1[field] || "")) |> Enum.max(fn -> 0 end) |> min(most)
    end

    keys = width.("key", 1_000)
    labels = width.("label", 60)

    for row <- rows do
      key = String.pad_trailing(row["key"] || "", keys)

      line =
        case row["detail"] do
          detail when detail in [nil, ""] -> "#{key}  #{row["label"]}"
          detail -> "#{key}  #{String.pad_trailing(row["label"] || "", labels)}  #{detail}"
        end

      indent <> String.trim_trailing(line)
    end
  end

  defp tools_text(tools) do
    sections =
      for tool <- tools do
        about =
          case tool do
            %{"tool" => "put", "asks" => asks} ->
              asks =
                Enum.map_join(asks, ", ", fn ask ->
                  ask["name"] <> if(ask["required"], do: " (required)", else: "")
                end)

              [
                "  #{tool["title"]}; asks #{asks}"
                | if(tool["in"], do: ["  goes in: #{tool["in"]}"], else: [])
              ]

            %{"tool" => "set", "fields" => fields} ->
              ["  " <> tool["title"] <> ": " <> Enum.map_join(fields, ", ", & &1["name"])]

            _ ->
              ["  " <> tool["title"]]
          end

        Enum.join(["atlas " <> tool["usage"] | about], "\n")
      end

    Enum.join(
      ["Tools (Control's actions, from rela's description, through Control):" | sections],
      "\n\n"
    )
  end

  defp plan_text(plan) do
    steps =
      for step <- plan["steps"] do
        values =
          for input <- step["inputs"] do
            [first | rest] = String.split(input["value"] || "", "\n")

            Enum.join(
              ["       #{input["label"]}: #{first}" | Enum.map(rest, &("         " <> &1))],
              "\n"
            )
          end

        problem = if step["problem"], do: ["     ✗ #{step["problem"]}"], else: []
        why = if step["why"], do: ["     why: #{step["why"]}"], else: []
        Enum.join(["  #{step["n"]}. #{step["label"]}" | values ++ why ++ problem], "\n")
      end

    steps = if steps == [], do: ["  (no steps)"], else: steps

    Enum.join(
      [
        "Plan by #{plan["by"]} for #{inspect(plan["request"])} on #{plan["on"]}:",
        "  " <> (plan["summary"] || ""),
        "" | steps
      ] ++ ["", "Nothing was written."],
      "\n"
    )
  end

  defp help(kinds, usage?) do
    sections =
      for kind <- kinds do
        fields =
          Enum.map(kind["fields"], fn [label, value] ->
            case String.split(value || "", "\n") do
              [line] -> "  #{label}: #{line}"
              lines -> "  #{label}:\n" <> Enum.map_join(lines, "\n", &("    " <> &1))
            end
          end)

        Enum.join([kind["title"] | fields], "\n")
      end

    heading = "Kinds (from rela's description, through Control):"
    Enum.join(if(usage?, do: [usage(), heading], else: [heading]) ++ sections, "\n\n")
  end

  # Arguments

  defp take_flag(args, flag, default) do
    case Enum.split_while(args, &(&1 != flag and not String.starts_with?(&1, flag <> "="))) do
      {before, [^flag, value | rest]} -> {value, before ++ rest}
      {before, [arg | rest]} -> {String.replace_prefix(arg, flag <> "=", ""), before ++ rest}
      {args, []} -> {default, args}
    end
  end

  defp take_switch(args, switch), do: {switch in args, List.delete(args, switch)}

  # Every `--link <association>=<keys>` of a put; the rest are its fields.
  defp links(["--link", link | rest], links, others) do
    case String.split(link, "=", parts: 2) do
      [relation, keys] when relation != "" -> links(rest, Map.put(links, relation, keys), others)
      _ -> {:error, "expected --link <association>=<key>, got #{link}"}
    end
  end

  defp links(["--link"], _links, _others), do: {:error, "expected --link <association>=<key>"}
  defp links([arg | rest], links, others), do: links(rest, links, [arg | others])
  defp links([], links, others), do: {:ok, links, Enum.reverse(others)}

  defp options(["--" <> name, value | rest], values) do
    case String.split(name, ~r/-file$/) do
      [field, ""] ->
        with {:ok, text} <- read_file(value), do: options(rest, Map.put(values, field, text))

      [field] ->
        with {:ok, text} <- read(value), do: options(rest, Map.put(values, field, text))
    end
  end

  defp options([], values), do: {:ok, values}

  defp options(args, _values),
    do: {:error, "expected --<field> <text>, got #{Enum.join(args, " ")}"}

  defp assignments([assignment | rest], values) do
    case String.split(assignment, "=", parts: 2) do
      [field, "@" <> path] ->
        with {:ok, text} <- read_file(path), do: assignments(rest, Map.put(values, field, text))

      [field, value] when field != "" ->
        with {:ok, text} <- read(value), do: assignments(rest, Map.put(values, field, text))

      _ ->
        {:error, "expected <field>=<text>, got #{assignment}"}
    end
  end

  defp assignments([], values), do: {:ok, values}

  defp read("-"), do: {:ok, :stdio |> IO.read(:eof) |> eof() |> String.trim_trailing("\n")}
  defp read(value), do: {:ok, value}

  defp eof(:eof), do: ""
  defp eof(text) when is_binary(text), do: text

  # A relative path is the caller's, not this project's folder `atlas` runs it from.
  defp read_file(path) do
    case path |> Path.expand(AtlasAgent.caller_cwd()) |> File.read() do
      {:ok, text} -> {:ok, String.trim_trailing(text, "\n")}
      {:error, reason} -> {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp usage, do: @moduledoc |> String.split("\n\n") |> Enum.at(1) |> String.trim_trailing()
end

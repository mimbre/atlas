defmodule AtlasAgent.FakeControl do
  @moduledoc """
  An in-process Control for tests of the agent client: a TCP listener on a free port
  that speaks Control's protocol (hello, open, submit) over facts it keeps in memory.
  It knows only what a test gives it: the kinds (as `/_kinds` describes them), their
  forms and the facts. Keys are made as Control makes them: the kind's prefix and one
  more than the highest number of that prefix, two digits at least.

  A kind: `%{kind:, title:, prefix:, under: parent kind or nil, asks: [field],
  required: [field], list_title:, record: "request" | "step" | nil}`.

  `refuse` (a function of the submit message, answering a list of reasons or nil) lets
  a test have State refuse a write. Every submit is kept, in order, in `writes/1`.
  """

  def start(kinds, opts \\ []) do
    {:ok, store} =
      Agent.start_link(fn ->
        %{
          kinds: kinds,
          facts: %{},
          order: [],
          writes: [],
          refuse: opts[:refuse] || fn _ -> nil end,
          hold: nil
        }
      end)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :line, active: false, reuseaddr: true])

    {:ok, {_, port}} = :inet.sockname(listener)
    acceptor = spawn_link(fn -> accept(listener, store) end)
    :ok = :gen_tcp.controlling_process(listener, acceptor)
    %{store: store, port: port, listener: listener}
  end

  @doc "The settings file content for env `test` pointing at this Control."
  def settings(control, extra \\ %{}) do
    Map.merge(
      %{"env" => "test", "control" => %{"host" => "127.0.0.1", "port" => control.port}},
      extra
    )
  end

  @doc "Write the settings to a file and point ATLAS_ENV_FILE at it for the test."
  def use_env_file(control, extra \\ %{}) do
    previous = System.get_env("ATLAS_ENV_FILE")
    file = Path.join(System.tmp_dir!(), "atlas-fake-#{System.unique_integer([:positive])}.json")
    File.write!(file, JSON.encode!(settings(control, extra)))
    System.put_env("ATLAS_ENV_FILE", file)

    ExUnit.Callbacks.on_exit(fn ->
      File.rm(file)

      if previous,
        do: System.put_env("ATLAS_ENV_FILE", previous),
        else: System.delete_env("ATLAS_ENV_FILE")
    end)

    file
  end

  @doc "A client connected to this Control."
  def connect(control) do
    {:ok, client} = AtlasAgent.Client.connect("test", settings(control))
    client
  end

  @doc "Put a fact directly, as if someone else made it. Answers its key."
  def put(control, kind, values, parent \\ nil) do
    Agent.get_and_update(control.store, fn s ->
      {key, s} = store_fact(s, kind, values, parent, nil)
      {key, s}
    end)
  end

  @doc "Delete a fact directly, as if another client deleted it."
  def delete(control, key),
    do: Agent.update(control.store, &%{&1 | facts: Map.delete(&1.facts, key)})

  def fact(control, key), do: Agent.get(control.store, & &1.facts[key])

  @doc "The facts of `kind`, in the order they were made."
  def facts(control, kind) do
    Agent.get(control.store, fn s ->
      for key <- Enum.reverse(s.order),
          f = s.facts[key],
          f.kind == kind,
          do: Map.put(f, :key, key)
    end)
  end

  def writes(control), do: Agent.get(control.store, &Enum.reverse(&1.writes))

  @doc """
  Hold the reply to the next create of a fact with this title until `release/1`: the
  holder is told `{:held, server}` once the write is stored; `release(server)` lets it go.
  """
  def hold(control, title) do
    holder = self()
    Agent.update(control.store, &%{&1 | hold: {title, holder}})
  end

  def release(pid), do: send(pid, :release)

  # Connections

  defp accept(listener, store) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        pid = spawn(fn -> serve(socket, store) end)
        :gen_tcp.controlling_process(socket, pid)
        accept(listener, store)

      {:error, _} ->
        :ok
    end
  end

  defp serve(socket, store) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, line} ->
        line |> JSON.decode!() |> handle(socket, store)
        serve(socket, store)

      {:error, _} ->
        :gen_tcp.close(socket)
    end
  end

  defp handle(%{"op" => "hello"} = hello, socket, store) do
    send_line(socket, %{"op" => "welcome", "env" => hello["env"], "spec" => hello["spec"]})
    send_line(socket, page(store, "/", "open"))
  end

  defp handle(%{"op" => "open", "to" => to}, socket, store),
    do: send_line(socket, page(store, to, "open"))

  defp handle(%{"op" => "submit"} = message, socket, store) do
    {reply, held} =
      Agent.get_and_update(store, fn s ->
        s = %{s | writes: [message | s.writes]}

        case s.refuse.(message) || check(s, message) do
          nil ->
            {path, s} = apply_submit(s, message)
            held = held(s, message)
            s = if held, do: %{s | hold: nil}, else: s
            {{{:stored, path}, held}, s}

          reasons ->
            {{{:refused, reasons}, nil}, s}
        end
      end)

    if held do
      send(held, {:held, self()})

      receive do
        :release -> :ok
      end
    end

    case reply do
      {:stored, path} -> send_line(socket, page(store, path, "stored"))
      {:refused, reasons} -> send_line(socket, refused(reasons))
    end
  end

  defp handle(_message, _socket, _store), do: :ok

  defp held(%{hold: {title, pid}}, %{"endpoint" => "create", "values" => %{"title" => title}}),
    do: pid

  defp held(_s, _message), do: nil

  # What State refuses by its own rules: a write under or to a fact that is not there.
  defp check(s, %{"endpoint" => "create", "params" => %{"parent" => parent}}) do
    if Map.has_key?(s.facts, parent), do: nil, else: ["#{parent} does not exist"]
  end

  defp check(s, %{"params" => %{"key" => key}}) do
    if Map.has_key?(s.facts, key), do: nil, else: ["#{key} does not exist"]
  end

  defp check(_s, _message), do: nil

  defp apply_submit(s, %{"endpoint" => "create", "params" => params} = m) do
    {key, s} = store_fact(s, params["kind"], m["values"], params["parent"], m["cause"])
    {"/k/#{params["kind"]}/#{key}", s}
  end

  defp apply_submit(s, %{"endpoint" => "update", "params" => %{"key" => key}} = m) do
    fact = s.facts[key]
    fact = %{fact | values: Map.merge(fact.values, m["values"]), cause: m["cause"]}
    {"/k/#{fact.kind}/#{key}", %{s | facts: Map.put(s.facts, key, fact)}}
  end

  defp apply_submit(
         s,
         %{"endpoint" => "link", "params" => %{"key" => key, "relation" => rel}} = m
       ) do
    fact = s.facts[key]
    keys = String.split(m["values"]["to"] || "", ",", trim: true)
    fact = Map.update(fact, :links, %{rel => keys}, &Map.put(&1, rel, keys))
    {"/k/#{fact.kind}/#{key}", %{s | facts: Map.put(s.facts, key, fact)}}
  end

  defp apply_submit(s, %{"endpoint" => "delete", "params" => %{"key" => key}}) do
    fact = s.facts[key]
    {"/k/#{fact.kind}", %{s | facts: Map.delete(s.facts, key)}}
  end

  defp store_fact(s, kind, values, parent, cause) do
    prefix = kind(s, kind).prefix

    highest =
      s.order
      |> Enum.flat_map(fn key ->
        case Regex.run(~r/^#{Regex.escape(prefix)}(\d+)$/, key) do
          [_, n] -> [String.to_integer(n)]
          nil -> []
        end
      end)
      |> Enum.max(fn -> 0 end)

    key = prefix <> String.pad_leading(Integer.to_string(highest + 1), 2, "0")
    fact = %{kind: kind, values: values, parent: parent, cause: cause}
    {key, %{s | facts: Map.put(s.facts, key, fact), order: [key | s.order]}}
  end

  defp kind(s, name), do: Enum.find(s.kinds, &(&1.kind == name))

  # Pages

  defp page(store, path, reason), do: store |> Agent.get(& &1) |> render(path) |> as(reason)

  defp as(page, reason),
    do: Map.merge(%{"op" => "page", "reason" => reason, "markup" => []}, page)

  defp refused(reasons) do
    form = %{"id" => "form", "type" => "form", "props" => %{"errors" => reasons}}
    as(%{"path" => "/", "title" => "Refused", "blocks" => [form]}, "refused")
  end

  defp render(_s, "/"), do: %{"path" => "/", "title" => "Atlas", "blocks" => []}

  defp render(s, "/_kinds") do
    blocks =
      for k <- s.kinds do
        fields =
          [
            {"Kind", k.kind},
            {"Create asks", Enum.join(k.asks, ", ")},
            {"Belongs under", k[:under] || "nothing; a top kind"},
            {"Fields", Enum.map_join(k.asks, "\n", &"#{&1}: text")}
          ] ++ if(k[:record], do: [{"Agent record", k.record}], else: [])

        item(k.kind, %{
          "title" => "#{k.title} (#{k.kind})",
          "fields" => Enum.map(fields, fn {l, v} -> %{"label" => l, "value" => v} end),
          "actions" => [
            %{"label" => "Update #{k.kind}", "key" => "u", "to" => "/k/_/<key>/edit"}
          ]
        })
      end

    %{"path" => "/_kinds", "title" => "Kinds", "blocks" => blocks}
  end

  defp render(s, path) do
    case String.split(path, "/", trim: true) |> Enum.map(&URI.decode/1) do
      ["k", "_", key] -> fact_page(s, key)
      ["k", _, key, "edit"] -> edit_page(s, key)
      ["k", "_", key, "delete"] -> delete_page(s, key)
      ["k", "_", key, "links", relation] -> links_page(s, key, relation)
      ["k", kind, "new"] -> create_page(s, kind, nil)
      ["k", kind, "new", "_parent", parent] -> create_page(s, kind, parent)
      ["k", kind, key] -> fact_page(s, key) |> Map.put("path", "/k/#{kind}/#{key}")
      ["k", kind] -> list_page(s, kind)
      _ -> missing(path, path)
    end
  end

  defp missing(path, key),
    do: %{
      "path" => path,
      "title" => "Not found",
      "blocks" => [confirm(%{"title" => "Not found", "text" => "#{key} does not exist"})]
    }

  defp fact_page(s, key) do
    case s.facts[key] do
      nil ->
        missing("/k/_/#{key}", key)

      f ->
        k = kind(s, f.kind)

        fields =
          for name <- k.asks,
              do: %{"label" => String.capitalize(name), "value" => f.values[name] || ""}

        lists =
          for child <- s.kinds, child[:under] == f.kind do
            rows = for c <- children(s, key, child.kind), do: row(c)
            list(child.kind, %{"title" => child.list_title, "rows" => rows})
          end

        page = %{
          "path" => "/k/#{f.kind}/#{key}",
          "title" => "#{k.title} #{key}",
          "blocks" => [
            item("item", %{
              "title" => "#{k.title} #{key}: #{f.values["title"]}",
              "fields" => fields
            })
            | lists
          ]
        }

        if f.parent,
          do: Map.put(page, "back", "/k/#{s.facts[f.parent][:kind] || "_"}/#{f.parent}"),
          else: page
    end
  end

  defp children(s, parent, kind) do
    for key <- Enum.reverse(s.order),
        f = s.facts[key],
        f.parent == parent and f.kind == kind,
        do: Map.put(f, :key, key)
  end

  defp row(f),
    do: %{
      "label" => f.values["title"],
      "detail" => f.values["stage"],
      "to" => "/k/#{f.kind}/#{f.key}"
    }

  defp list_page(s, kind) do
    case kind(s, kind) do
      nil ->
        missing("/k/#{kind}", kind)

      k ->
        rows =
          for key <- Enum.reverse(s.order),
              f = s.facts[key],
              f.kind == kind,
              do: row(Map.put(f, :key, key))

        %{
          "path" => "/k/#{kind}",
          "title" => k.list_title,
          "blocks" => [list(kind, %{"rows" => rows})]
        }
    end
  end

  defp create_page(s, kind, parent) do
    case kind(s, kind) do
      nil ->
        missing("/k/#{kind}/new", kind)

      k ->
        params = if parent, do: %{"kind" => kind, "parent" => parent}, else: %{"kind" => kind}
        title = "Create #{String.downcase(k.title)}#{if parent, do: " in #{parent}", else: ""}"

        form(%{
          "title" => title,
          "submit_to" => %{"endpoint" => "create", "params" => params},
          "inputs" => inputs(k, %{})
        })
        |> then(&%{"path" => "/k/#{kind}/new", "title" => title, "blocks" => [&1]})
    end
  end

  defp edit_page(s, key) do
    case s.facts[key] do
      nil ->
        missing("/k/_/#{key}/edit", key)

      f ->
        title = "Update #{key}"

        form(%{
          "title" => title,
          "submit_to" => %{"endpoint" => "update", "params" => %{"key" => key}},
          "inputs" => inputs(kind(s, f.kind), f.values)
        })
        |> then(&%{"path" => "/k/_/#{key}/edit", "title" => title, "blocks" => [&1]})
    end
  end

  # An association's form, for a kind that names it in `links`.
  defp links_page(s, key, relation) do
    with %{} = f <- s.facts[key],
         true <- relation in (kind(s, f.kind)[:links] || []) do
      title = "#{relation} of #{key}"

      form(%{
        "title" => title,
        "submit_to" => %{
          "endpoint" => "link",
          "params" => %{"key" => key, "relation" => relation}
        },
        "inputs" => [%{"name" => "to", "label" => "To", "kind" => "text", "value" => ""}]
      })
      |> then(&%{"path" => "/k/_/#{key}/links/#{relation}", "title" => title, "blocks" => [&1]})
    else
      _ -> missing("/k/_/#{key}/links/#{relation}", "#{key} #{relation}")
    end
  end

  defp delete_page(s, key) do
    case s.facts[key] do
      nil ->
        missing("/k/_/#{key}/delete", key)

      f ->
        title = "Delete #{kind(s, f.kind).title |> String.downcase()} #{key}?"
        under = Enum.count(s.facts, fn {_, c} -> c.parent == key end)

        props =
          if under == 0,
            do: %{
              "title" => title,
              "confirm_to" => %{"endpoint" => "delete", "params" => %{"key" => key}}
            },
            else: %{
              "title" => title,
              "text" => "#{key} still has #{under} parts. Remove them first."
            }

        %{"path" => "/k/_/#{key}/delete", "title" => title, "blocks" => [confirm(props)]}
    end
  end

  defp inputs(k, values) do
    for name <- k.asks,
        do: %{
          "name" => name,
          "label" => String.capitalize(name),
          "kind" => "text",
          "required" => name in (k[:required] || []),
          "value" => values[name] || ""
        }
  end

  defp item(id, props), do: %{"id" => id, "type" => "item", "props" => props}
  defp list(id, props), do: %{"id" => "list-" <> id, "type" => "list", "props" => props}
  defp form(props), do: %{"id" => "form", "type" => "form", "props" => props}
  defp confirm(props), do: %{"id" => "confirm", "type" => "confirm", "props" => props}

  defp send_line(socket, message), do: :gen_tcp.send(socket, [JSON.encode!(message), "\n"])
end

defmodule AtlasAgent do
  @moduledoc """
  Create, change and read through Control, as an agent: the same pages and forms the TUI
  gets, without a screen. A kind is the name rela's description gives it, passed in by
  the caller; this code names none.

  - `put/4` opens the create form of a kind (under a parent, when given only its key),
    fills the fields it asks, submits, and answers the key Control made, or why it was
    refused.
  - `set/3` changes fields of one fact through its change form, and the links of an
    association (`<association>=<key>`; empty removes them) through that association's form.
  - `delete/2` deletes one fact through the confirm the TUI's d opens.
  - `get/2` reads one fact: its page (fields, and the lists of facts under it) and the
    exact values of its change form.
  - `list/2` reads the list of a kind.

  A key is enough to find a fact: Control works out its kind from the id prefix
  (`/k/_/<key>`), and the relation to a parent from the description
  (`/k/<kind>/new/_parent/<key>`).
  """

  alias AtlasAgent.Client

  @root Path.expand("../../../..", __DIR__)

  @doc """
  Connect to Control of `env`. Its address comes from `products/software_factory/environments/<env>.json`, or from
  `ATLAS_ENV_FILE` (a private instance), whose `"env"` must be the same environment.
  `as` is what the client says it is: `agent`, or `migration`.
  """
  def connect(env, as \\ "agent") do
    with {:ok, settings} <- settings(env), do: Client.connect(env, settings, as)
  end

  @doc "The settings of `env`: `products/software_factory/environments/<env>.json`, or `ATLAS_ENV_FILE` for a private instance."
  def settings(env) do
    file =
      System.get_env("ATLAS_ENV_FILE") ||
        Path.join(root(), "products/software_factory/environments/#{env}.json")

    with {:ok, json} <- File.read(file),
         {:ok, %{"env" => ^env} = settings} <- JSON.decode(json) do
      {:ok, settings}
    else
      {:ok, %{"env" => other}} -> {:error, "#{file} is for #{inspect(other)}, not #{env}"}
      _ -> {:error, "Atlas has no environment #{inspect(env)} (no readable #{file})"}
    end
  end

  @doc "The repository Atlas runs from."
  def root, do: System.get_env("ATLAS_ROOT") || @root

  @doc "The folder `atlas` was called from, which a relative path is read from."
  def caller_cwd, do: System.get_env("ATLAS_CALLER_CWD") || File.cwd!()

  @doc """
  Create a fact of `kind` from `values` (field name to text). `parent` is the key of the
  fact it belongs under, or nil. Answers `{:ok, key}`, `{:refused, reasons}` or
  `{:error, text}`.
  """
  def put(client, kind, values, parent \\ nil, cause \\ nil) do
    with {:ok, form} <- create_form(client, kind, parent),
         :ok <- asked(form, values, :create) do
      case Client.submit(client, form["submit_to"], values, cause) do
        {:stored, page} -> {:ok, Client.key_of(page["path"])}
        other -> other
      end
    end
  end

  @doc """
  Change `values` (field name to text) of the fact with `key`; the rest stays. A name the
  change form does not ask, but that is an association of the fact, sets its links: the
  keys named (separated by commas); none removes them. `cause` says why.
  """
  def set(client, key, values, cause \\ nil) do
    with {:ok, form} <- change_form(client, key) do
      asked = for input <- form["inputs"] || [], input["kind"] != "readonly", do: input["name"]
      {fields, links} = Map.split(values, asked)

      with :ok <- set_links(client, key, form, links, cause) do
        if fields == %{} and links != %{} do
          {:ok, key}
        else
          case Client.submit(client, form["submit_to"], fields, cause) do
            {:stored, _page} -> {:ok, key}
            other -> other
          end
        end
      end
    end
  end

  # Each association through its own form. A name that is no association of the fact is
  # answered with what the change form asks; one Control does not let a client set, with
  # why.
  defp set_links(client, key, change, links, cause) do
    Enum.reduce_while(links, :ok, fn {relation, keys}, :ok ->
      result =
        with {:ok, page} <- Client.open(client, "/k/_/#{enc(key)}/links/#{enc(relation)}") do
          case {Client.blocks(page, "form"), Client.blocks(page, "confirm")} do
            {[form], _} ->
              note = if cause, do: %{"note" => cause}, else: %{}

              case Client.submit(client, form["submit_to"], Map.merge(%{"to" => keys}, note)) do
                {:stored, _} -> :ok
                other -> other
              end

            {[], [%{"text" => text} | _]} ->
              if String.contains?(text, " is not set here"),
                do: {:refused, [text]},
                else: asked(change, %{relation => keys}, :change)

            _ ->
              asked(change, %{relation => keys}, :change)
          end
        end

      if result == :ok, do: {:cont, :ok}, else: {:halt, result}
    end)
  end

  @doc """
  Delete the fact with `key`: the confirm Control shows before a delete, confirmed. When
  Control says it cannot be deleted (something still hangs under it), that is the
  refusal, in Control's words. `{:ok, key}`, `{:refused, reasons}` or `{:error, text}`.
  """
  def delete(client, key) do
    with {:ok, confirm} <- delete_confirm(client, key) do
      case confirm do
        %{"confirm_to" => to} when is_map(to) ->
          case Client.submit(client, to, %{}) do
            {:stored, _page} -> {:ok, key}
            other -> other
          end

        %{"text" => text} ->
          {:refused, [text]}
      end
    end
  end

  @doc "The confirm Control shows before deleting the fact with `key`: `{:ok, props}`."
  def delete_confirm(client, key) do
    with {:ok, page} <- Client.open(client, "/k/_/#{enc(key)}/delete") do
      case Client.blocks(page, "confirm") do
        [confirm] -> {:ok, confirm}
        _ -> {:error, why(page, key)}
      end
    end
  end

  @doc """
  One fact: `%{"key", "path", "title", "fields" => [[label, value]], "todo" => %{"title",
  "fields"}` (only for its owner; a decision as `%{"title", "why", "failure", "options" =>
  [%{"n", "text", "badge", "fields", "answer"}], "answers"}`, or its steps as `%{"title",
  "why", "steps" => [%{"n", "lines"}], "answers"}`), "origins" =>
  %{label => %{"since", "by", "cause"}}, "lists" => [%{"title", "rows"}], "values" =>
  %{name => text}}`. `origins` holds the fact that set a field's value, for a link. `values`
  are what its change form holds, so exactly what was stored; empty when it has no change
  form.
  """
  def get(client, key) do
    with {:ok, page} <- Client.open(client, "/k/_/#{enc(key)}") do
      # The fact's own item; its owner's What to do part, when the client is the owner, is
      # a second one (IS-Atlas-54), or a decision's options, or its instructions as steps.
      items =
        for %{"type" => "item", "props" => props} = b <- page["blocks"] || [],
            do: {b["id"], props}

      todo =
        steps_of(page["blocks"] || []) || options_of(page["blocks"] || []) ||
          Enum.find_value(items, fn {id, props} -> id == "todo" && props end)

      case for({id, props} <- items, id != "todo", do: props) do
        [item] ->
          # The change form holds the exact values; it answers at its path also for a kind
          # that offers no key to change it (one only the agent writes).
          values = edit_values(client, page["path"] <> "/edit")

          # The fact that set a value (a link): since, by, cause, by the field's label.
          origins =
            for %{"origin" => %{} = origin} = pair <- item["fields"] || [],
                into: %{},
                do: {pair["label"], origin}

          {:ok,
           %{
             "key" => key,
             "path" => page["path"],
             "title" => item["title"],
             "fields" =>
               pairs(item["fields"]) ++
                 for(
                   %{"id" => "field:" <> _, "type" => "text",
                     "props" => %{"label" => label, "text" => text}} <- page["blocks"] || [],
                   do: [label, text]
                 ),
             "origins" => origins,
             "lists" => lists(page),
             "values" => values,
             "more" => more(page)
           }
           |> then(&if(todo, do: Map.put(&1, "todo", todo_of(todo)), else: &1))}

        _ ->
          {:error, why(page, key)}
      end
    end
  end

  # A to-do as its steps (the page's `instruction` blocks), headed by its `header` and why
  # (`text`), with its `answers`; nil without steps.
  defp steps_of(blocks) do
    of = fn type -> for %{"type" => ^type, "props" => props} <- blocks, do: props end

    case of.("instruction") do
      [] ->
        nil

      steps ->
        %{
          "title" => Enum.find_value(of.("header"), & &1["title"]),
          "why" => Enum.find_value(of.("text"), & &1["text"]),
          "steps" => steps,
          "answers" => Enum.flat_map(of.("answers"), & &1["answers"])
        }
    end
  end

  # A decision as its options (the page's `option` blocks), headed by its `header`, why
  # and what went wrong (`text`, role error), with its other `answers`; nil without options.
  defp options_of(blocks) do
    of = fn type -> for %{"type" => ^type, "props" => props} <- blocks, do: props end
    {failure, why} = Enum.split_with(of.("text"), &(&1["role"] == "error"))

    case of.("option") do
      [] ->
        nil

      options ->
        %{
          "title" => Enum.find_value(of.("header"), & &1["title"]),
          "why" => Enum.find_value(why, & &1["text"]),
          "failure" => Enum.find_value(failure, & &1["text"]),
          "options" => options,
          "answers" => Enum.flat_map(of.("answers"), & &1["answers"])
        }
    end
  end

  # What to do, as the page words it: its title and its fields.
  defp todo_of(%{"options" => _} = decision), do: decision
  defp todo_of(%{"steps" => _} = steps), do: steps

  defp todo_of(todo),
    do: %{
      "title" => todo["title"],
      "fields" => pairs(todo["fields"])
    }

  @doc """
  The kinds Control describes (`/_kinds`): `[%{"kind", "title", "fields" => [[label,
  value]], "actions" => [%{"label", "key", "to"}]}]`, each telling what a create asks, how
  its id is made, what it belongs under, its fields and what can be done with one, named
  as Control names it everywhere.
  """
  def kinds(client) do
    with {:ok, page} <- Client.open(client, "/_kinds") do
      {:ok,
       for item <- Client.blocks(page, "item") do
         fields = Enum.map(item["fields"] || [], &[&1["label"], &1["value"]])
         kind = Enum.find_value(fields, fn [label, value] -> label == "Kind" && value end)
         actions = Enum.map(item["actions"] || [], &Map.take(&1, ["label", "key", "to"]))
         %{"kind" => kind, "title" => item["title"], "fields" => fields, "actions" => actions}
       end}
    end
  end

  @doc """
  The facts of `kind`, as Control lists them: `[%{"key", "label", "detail", "path"}]`.
  With `parent`, only those that hang under the fact with that key.
  """
  def list(client, kind, parent \\ nil)

  def list(client, kind, nil), do: list(client, kind, nil, [])

  def list(client, kind, parent) do
    with {:ok, item} <- get(client, parent) do
      prefix = "/k/#{enc(kind)}/"

      {:ok,
       for(
         list <- item["lists"],
         row <- list["rows"],
         String.starts_with?(row["path"], prefix),
         do: row
       )}
    end
  end

  @doc "List an unscoped kind; typed_errors retains an optional Control failure code for JSON clients."
  def list(client, kind, nil, opts) do
    with {:ok, page} <- Client.open(client, "/k/#{enc(kind)}") do
      case Client.blocks(page, "list") do
        [list | _] ->
          {:ok, rows(list)}

        [] ->
          code =
            case Client.blocks(page, "confirm") do
              [confirm] -> confirm["code"]
              _ -> nil
            end

          if Keyword.get(opts, :typed_errors, false) and is_binary(code) and code != "",
            do: {:error, why(page, kind), code},
            else: {:error, why(page, kind)}
      end
    end
  end

  # A list inside a section leaves its title to the section's markup.
  defp lists(page) do
    titles =
      for %{"kind" => "section", "start" => id, "end" => id, "props" => %{"title" => title}} <-
            page["markup"] || [],
          into: %{},
          do: {id, title}

    for %{"type" => "list", "props" => list} = block <- page["blocks"] || [],
        do: %{"title" => list["title"] || titles[block["id"]], "rows" => rows(list)}
  end

  defp rows(list) do
    for row <- list["rows"] || [],
        do: %{
          "key" => Client.key_of(row["to"]),
          "label" => row["label"],
          "detail" => row["detail"],
          "path" => row["to"]
        }
  end

  defp edit_values(client, path) do
    with {:ok, page} <- Client.open(client, path),
         [form] <- Client.blocks(page, "form") do
      for input <- form["inputs"] || [],
          input["kind"] != "readonly",
          into: %{},
          do: {input["name"], input["value"] || ""}
    else
      _ -> %{}
    end
  end

  defp form(page, about) do
    case Client.blocks(page, "form") do
      [form] -> {:ok, form}
      _ -> {:error, why(page, about)}
    end
  end

  @doc """
  The form a create of `kind` fills (under the fact with key `parent`, when given), as
  Control sends it: `{:ok, props}`.
  """
  def create_form(client, kind, parent \\ nil) do
    path =
      if parent,
        do: "/k/#{enc(kind)}/new/_parent/#{enc(parent)}",
        else: "/k/#{enc(kind)}/new"

    with {:ok, page} <- Client.open(client, path), do: form(page, kind)
  end

  @doc "The form that changes the fact with `key`, as Control sends it: `{:ok, props}`."
  def change_form(client, key) do
    with {:ok, page} <- Client.open(client, "/k/_/#{enc(key)}/edit"), do: form(page, key)
  end

  @doc """
  The page at `path` (or of the fact with a key), as Control sends it: `%{"path", "title",
  "blocks", "markup"}`, its view model.
  """
  def page(client, "/" <> _ = path) do
    with {:ok, page} <- Client.open(client, path),
         do: {:ok, Map.take(page, ["path", "title", "blocks", "markup"])}
  end

  def page(client, key), do: page(client, "/k/_/#{enc(key)}")

  # The contract's blocks and models, as fields: what a page's props hold and how they nest.
  # Actions, submits and inputs are found by their contract type, never by a block's name.
  @contract AtlasBFFContract.Contract.__schema__()
  @blocks Map.new(@contract.blocks, &{Atom.to_string(&1.name), &1.fields})
  @models Map.new(@contract.models, &{&1.name, &1.fields})

  @doc "The contract's fields of a block (its `type`, a string) or of a model (an atom); nil when unknown."
  def fields(block) when is_binary(block), do: @blocks[block]

  def fields(model), do: @models[model]

  # Label-value pairs as `[label, value]`, texts only: an entry or value of another shape
  # (a newer Control's) is left out, never a crash (D-0105).
  defp pairs(fields) when is_list(fields) do
    for %{} = pair <- fields,
        do: [text(pair["label"]), text(pair["value"])]
  end

  defp pairs(_fields), do: []

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: nil

  # Blocks of a type this client does not know (a newer Control's, D-0105), in plain
  # words: `[%{"title", "lines"}]`, those that say nothing in words left out.
  defp more(page) do
    for %{"type" => type} = block <- page["blocks"] || [],
        is_binary(type) and not Map.has_key?(@blocks, type),
        {title, lines} = AtlasBFF.Targets.Client.plain(block["props"]),
        title != nil or lines != [],
        do: %{"title" => title, "lines" => lines}
  end

  @doc """
  The actions Control offers on `page`: every `action` its blocks hold and every answer
  (`panel_answer`: an option's Choose, Decline, Ask, …), in order. An answer
  is the page's action of its key, as the TUI takes it: its `submit_to`, or its page.
  """
  def actions(page), do: found(page, :offered)

  @doc """
  Do the action labelled (or keyed) `name` on the page at `at` (a key or a path), as the
  TUI does. An action with a `submit_to` is submitted; otherwise its page
  is opened, and the one call that page offers (a form's `submit_to`, a confirm's
  `confirm_to`) is submitted with its inputs' values, `values` (input name to text)
  replacing them. A page that offers no call is answered as it is; so is any page when
  `submit?` is false. `{:page, page}`, `{:refused, reasons}` or `{:error, text}`.
  """
  def act(client, at, name, values, submit? \\ true) do
    with {:ok, page} <- page(client, at),
         {:ok, action} <- action(page, actions(page), name) do
      if action["submit_to"] && submit? do
        submitted(Client.submit(client, action["submit_to"], values))
      else
        with {:ok, target} <- page(client, action["to"]) do
          case calls(target) do
            [{to, inputs}] when submit? ->
              with :ok <- asks(target, inputs, values) do
                given = Map.new(inputs, &{&1["name"], &1["value"] || ""})
                submitted(Client.submit(client, to, Map.merge(given, values)))
              end

            _ ->
              {:page, target}
          end
        end
      end
    end
  end

  # The one action by `name` among those offered.
  defp action(page, offered, name) do
    case Enum.filter(offered, &(name in [&1["label"], &1["key"]])) do
      [action] ->
        {:ok, action}

      _ ->
        labels = Enum.map_join(offered, ", ", &inspect(&1["label"]))
        {:error, "#{page["path"]} offers no single action #{inspect(name)}; it offers #{labels}"}
    end
  end

  # What a block offers to submit: each call among its own fields, with the inputs it holds.
  defp calls(page) do
    for %{"type" => type, "props" => props} <- page["blocks"] || [],
        fields = @blocks[type] || [],
        %{name: name, type: :call} <- fields,
        to = props[Atom.to_string(name)],
        is_map(to),
        do: {to, within(fields, props, :input)}
  end

  defp asks(page, inputs, values) do
    case Map.keys(values) -- Enum.map(inputs, & &1["name"]) do
      [] ->
        :ok

      unknown ->
        asked = Enum.map_join(inputs, ", ", &"--#{&1["name"]} (#{&1["kind"]})")
        asked = if asked == "", do: "nothing", else: asked

        {:error,
         "#{page["title"]} does not ask for #{Enum.join(unknown, ", ")}; it asks #{asked}"}
    end
  end

  defp submitted({:stored, page}), do: {:page, page}
  defp submitted(other), do: other

  # Every value of model `type` the page's blocks hold, however deep.
  defp found(page, type) do
    for %{"type" => block, "props" => props} <- page["blocks"] || [],
        value <- within(@blocks[block] || [], props, type),
        do: value
  end

  defp within(fields, props, type) do
    for %{name: name, type: t} <- fields,
        value <- of(t, props[Atom.to_string(name)], type),
        do: value
  end

  defp of(t, value, :offered) when t in [:action, :panel_answer] and is_map(value), do: [value]
  defp of(type, value, type) when is_map(value), do: [value]

  defp of({:list, t}, values, type) when is_list(values),
    do: Enum.flat_map(values, &of(t, &1, type))

  defp of(t, value, type) when is_map(value), do: within(@models[t] || [], value, type)
  defp of(_t, _value, _type), do: []

  @doc """
  Whether `values` fit `form`: only what it asks, and on a create (`mode` `:create`)
  everything it requires. `:ok`, `{:refused, reasons}` or `{:error, text}`.
  """
  # Only what the form asks reaches Facts; a create fills what the form requires.
  def asked(form, values, mode) do
    inputs = Enum.reject(form["inputs"] || [], &(&1["kind"] == "readonly"))
    names = Enum.map(inputs, & &1["name"])
    unknown = Map.keys(values) -- names

    missing =
      if mode == :create,
        do: for(%{"required" => true, "name" => name} <- inputs, blank?(values[name]), do: name),
        else: []

    cond do
      unknown != [] ->
        {:error,
         "#{form["title"]} does not ask for #{Enum.join(unknown, ", ")}; " <>
           "it asks for #{Enum.join(names, ", ")}"}

      missing != [] ->
        {:refused, Enum.map(missing, &"#{&1} is required")}

      true ->
        :ok
    end
  end

  defp blank?(value), do: value in [nil, ""]

  # What a page without the expected block says: a page that does not exist says so.
  defp why(page, about) do
    text =
      page
      |> Client.blocks("confirm")
      |> Enum.map_join(" ", &(&1["text"] || ""))
      |> String.trim()

    "#{about}: #{page["title"]}#{if text != "", do: ". " <> text, else: ""}"
  end

  defp enc(part), do: URI.encode(part, &URI.char_unreserved?/1)
end

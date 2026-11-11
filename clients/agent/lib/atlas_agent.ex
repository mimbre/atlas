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

  @root Path.expand("../../..", __DIR__)

  @doc """
  Connect to Control of `env`. Its address comes from `env/<env>.json`, or from
  `ATLAS_ENV_FILE` (a private instance), whose `"env"` must be the same environment.
  `as` is what the client says it is: `agent`, or `migration`.
  """
  def connect(env, as \\ "agent") do
    with {:ok, settings} <- settings(env), do: Client.connect(env, settings, as)
  end

  @doc "The settings of `env`: `env/<env>.json`, or `ATLAS_ENV_FILE` for a private instance."
  def settings(env) do
    file = System.get_env("ATLAS_ENV_FILE") || Path.join(root(), "env/#{env}.json")

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
  "fields"}` (only for its owner), "origins" =>
  %{label => %{"since", "by", "cause"}}, "lists" => [%{"title", "rows"}], "values" =>
  %{name => text}}`. `origins` holds the fact that set a field's value, for a link. `values`
  are what its change form holds, so exactly what was stored; empty when it has no change
  form.
  """
  def get(client, key) do
    with {:ok, page} <- Client.open(client, "/k/_/#{enc(key)}") do
      # The fact's own item; its owner's What to do part, when the client is the owner, is
      # a second one (IS-Atlas-54).
      items =
        for %{"type" => "item", "props" => props} = b <- page["blocks"] || [],
            do: {b["id"], props}

      todo = Enum.find_value(items, fn {id, props} -> id == "todo" && props end)

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
             "fields" => Enum.map(item["fields"] || [], &[&1["label"], &1["value"]]),
             "origins" => origins,
             "lists" => lists(page),
             "values" => values
           }
           |> then(&if(todo, do: Map.put(&1, "todo", todo_of(todo)), else: &1))}

        _ ->
          {:error, why(page, key)}
      end
    end
  end

  # What to do, as the page words it: its title and its fields.
  defp todo_of(todo),
    do: %{
      "title" => todo["title"],
      "fields" => Enum.map(todo["fields"] || [], &[&1["label"], &1["value"]])
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

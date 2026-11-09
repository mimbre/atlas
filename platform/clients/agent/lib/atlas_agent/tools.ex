defmodule AtlasAgent.Tools do
  @moduledoc """
  The agent's tools (UC-Atlas-16): the actions Control offers, the same ones the TUI's
  keys open, generated from rela's description through Control. Nothing here is written
  by hand per kind: a kind rela adds is a new tool.

  - `put`, one per kind: the inputs of its create form (as Control sends them) and the
    kind it goes in, when it belongs under one.
  - `set`, one per kind: the fields a user may change, and the associations a client may
    link (`<association>=<key>`); not those only a migration or connector sets.
  - `delete`: one fact by its key, refused while anything hangs under it.
  - `get`, `list` and `help`: reading.

  A tool is a map, so it travels as JSON to whatever plans: `"tool"`, `"kind"`,
  `"title"`, `"about"`, `"in"`, `"asks"` (the form's inputs: name, label, kind,
  required, choices), `"fields"` and `"usage"`, the command line that does the same.
  """

  # How the kinds page (`/_kinds`) says a kind belongs under nothing.
  @top "nothing"
  # How it marks a kind that is no tool.
  @not_tools ["Agent record", "Made with", "By hand"]

  @doc "Every tool Control offers now: `{:ok, tools}`."
  def list(client) do
    with {:ok, kinds} <- AtlasAgent.kinds(client) do
      # The kinds the agent keeps its own record in are not tools (AtlasAgent.Record), nor
      # those Facts makes with a fact (its Assignment): set them through that fact; nor
      # those only a layer writes (a turn: Runtime).
      kinds =
        Enum.reject(kinds, fn kind ->
          Enum.any?(kind["fields"], &match?([label, _] when label in @not_tools, &1))
        end)

      writes =
        Enum.reduce_while(kinds, {:ok, []}, fn kind, {:ok, acc} ->
          case AtlasAgent.create_form(client, kind["kind"]) do
            {:ok, form} -> {:cont, {:ok, acc ++ [put(kind, form), set(kind)]}}
            {:error, _} = error -> {:halt, error}
          end
        end)

      with {:ok, writes} <- writes, do: {:ok, writes ++ [delete()] ++ reads()}
    end
  end

  @doc "The put tool of a kind: what its create form asks, and the kind it goes in."
  def put(kind, form) do
    asks =
      for input <- form["inputs"] || [], input["kind"] != "readonly" do
        choices = for choice <- input["choices"] || [], do: choice["value"]

        %{
          "name" => input["name"],
          "label" => input["label"],
          "kind" => input["kind"],
          "required" => input["required"] == true
        }
        |> then(&if(choices == [], do: &1, else: Map.put(&1, "choices", choices)))
      end

    parent = parent(kind)

    args =
      Enum.map(
        asks,
        &"--#{&1["name"]} <#{if &1["kind"] == "multiline", do: "lines", else: "text"}>"
      )

    in_arg = if parent, do: ["--in <#{parent} key>"], else: []

    %{
      "tool" => "put",
      "kind" => kind["kind"],
      "title" => form["title"],
      "about" => field(kind, "About"),
      "in" => parent,
      "asks" => asks,
      "usage" => Enum.join(["put", kind["kind"]] ++ in_arg ++ args, " ")
    }
  end

  @doc "The set tool of a kind: the fields a user may change, and what each takes."
  def set(kind) do
    fields =
      for line <-
            String.split(field(kind, "Fields") || "", "\n") ++
              String.split(field(kind, "Links") || "", "\n"),
          [name, what] <- [String.split(line, ": ", parts: 2)],
          not String.contains?(what, "never in a form"),
          not String.contains?(what, "never by hand"),
          not String.contains?(what, "never by an agent"),
          do: %{"name" => name, "takes" => what}

    %{
      "tool" => "set",
      "kind" => kind["kind"],
      "title" => update_label(kind),
      "fields" => fields,
      "usage" => "set <#{kind["kind"]} key> <field>=<text> ..."
    }
  end

  defp delete do
    %{
      "tool" => "delete",
      "title" => "Delete an item; refused while anything hangs under it",
      "usage" => "delete <key>"
    }
  end

  # The update action as Control names it on every page ("Update <kind>"); the command's
  # own verb when Control names none.
  defp update_label(kind) do
    Enum.find_value(
      kind["actions"] || [],
      "Set #{kind["kind"]}",
      &(String.ends_with?(&1["to"] || "", "/edit") && &1["label"])
    )
  end

  defp reads do
    [
      %{"tool" => "get", "title" => "One item, and what hangs under it", "usage" => "get <key>"},
      %{
        "tool" => "list",
        "title" => "The items of a kind",
        "usage" => "list <kind> [--in <key>]"
      },
      %{
        "tool" => "help",
        "title" => "Every kind, from rela's description",
        "usage" => "help [<kind>]"
      }
    ]
  end

  @doc "The put tool for `kind`, or nil."
  def find(tools, "put", kind),
    do: Enum.find(tools, &(&1["tool"] == "put" and &1["kind"] == kind))

  def find(tools, tool, _kind), do: Enum.find(tools, &(&1["tool"] == tool))

  @doc "Whether a tool writes."
  def write?(%{"tool" => tool}), do: tool in ["put", "set", "delete"]

  # "Belongs under": a kind (the first, when there are several), or nothing.
  defp parent(kind) do
    case field(kind, "Belongs under") do
      nil -> nil
      @top <> _ -> nil
      under -> under |> String.split(" or ") |> hd()
    end
  end

  defp field(kind, label),
    do: Enum.find_value(kind["fields"] || [], fn [l, value] -> l == label && value end)

  @doc "The kind of the fact a page shows, from its path (`/k/<kind>/<key>`), or nil."
  def kind_of_path(path) do
    case String.split(path || "", "/") do
      ["", "k", kind, _key | _] -> URI.decode(kind)
      _ -> nil
    end
  end
end

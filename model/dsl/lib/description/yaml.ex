defmodule RelaDSL.Description.Yaml do
  @moduledoc """
  The YAML of Rela's inputs, in the one style the description has (Rela DSL design,
  slice 0): two-space block maps; block lists with `- ` at the key's indent; a plain
  scalar where that is safe and a single-quoted one otherwise, never folded across
  lines; multi-line text as a `|` block; no anchors, aliases or blank lines. A plain
  scalar is safe when YAML reads it back as the same string: it does not start with
  an indicator, holds no `: ` or ` #`, has no space at either end, and does not read
  as a boolean, null, number or date (YAML 1.1, as PyYAML and Rela's checks read it).

  A document is `{:ordered, [{key, value}]}`; values are strings, integers, booleans,
  lists of values, or ordered maps.
  """

  @doc "The document `doc` after the `comment` lines (each `# ` text; none when nil)."
  def document(doc, comment \\ nil), do: comments(comment, "") <> block(doc, "")

  @doc "Each line of `text` as a comment at `indent`."
  def comments(nil, _indent), do: ""

  def comments(text, indent) do
    text
    |> String.trim_trailing("\n")
    |> String.split("\n")
    |> Enum.map_join("", fn
      "" -> indent <> "#\n"
      line -> indent <> "# " <> line <> "\n"
    end)
  end

  defp block({:ordered, pairs}, indent), do: Enum.map_join(pairs, "", &pair(&1, indent))

  defp pair({key, {:ordered, []}}, indent), do: "#{indent}#{key}: {}\n"

  defp pair({key, {:ordered, _} = map}, indent),
    do: "#{indent}#{key}:\n" <> block(map, indent <> "  ")

  defp pair({key, []}, indent), do: "#{indent}#{key}: []\n"

  defp pair({key, list}, indent) when is_list(list),
    do: "#{indent}#{key}:\n" <> items(list, indent)

  defp pair({key, value}, indent), do: "#{indent}#{key}:" <> scalar(value, indent) <> "\n"

  defp items(list, indent) do
    Enum.map_join(list, "", fn
      {:ordered, [{_, first} = pair | rest]} when not is_list(first) and not is_tuple(first) ->
        pair(pair, indent <> "- ") <>
          Enum.map_join(rest, "", &pair(&1, indent <> "  "))

      value ->
        "#{indent}-" <> scalar(value, indent) <> "\n"
    end)
  end

  @doc "A scalar after its key's colon (with the separating space), as the style writes it."
  def scalar(true, _indent), do: " true"
  def scalar(false, _indent), do: " false"
  def scalar(n, _indent) when is_integer(n), do: " #{n}"

  def scalar(text, indent) when is_binary(text) do
    if String.contains?(text, "\n") do
      body = String.trim_trailing(text, "\n")
      chomp = if String.ends_with?(text, "\n"), do: "", else: "-"

      " |" <>
        chomp <>
        "\n" <>
        (body
         |> String.split("\n")
         |> Enum.map_join("\n", &if(&1 == "", do: "", else: indent <> "  " <> &1)))
    else
      " " <> quote_scalar(text)
    end
  end

  def scalar(v, _indent), do: raise(ArgumentError, "#{inspect(v)} has no YAML form")

  @doc "`text` as a plain scalar when that is safe, else single-quoted."
  def quote_scalar(text),
    do: if(plain?(text), do: text, else: "'" <> String.replace(text, "'", "''") <> "'")

  @indicators ~c"#,[]{}&*!|>'\"%@`"
  defp implicit,
    do: [
      ~r/\A(?:yes|Yes|YES|no|No|NO|true|True|TRUE|false|False|FALSE|on|On|ON|off|Off|OFF|y|Y|n|N)\z/,
      ~r/\A(?:~|null|Null|NULL)\z/,
      ~r/\A[-+]?(?:0b[0-1_]+|0[0-7_]+|(?:0|[1-9][0-9_]*)|0x[0-9a-fA-F_]+|[1-9][0-9_]*(?::[0-5]?[0-9])+)\z/,
      ~r/\A(?:[-+]?(?:[0-9][0-9_]*)\.[0-9_]*(?:[eE][-+][0-9]+)?|\.[0-9_]+(?:[eE][-+][0-9]+)?|[-+]?[0-9][0-9_]*(?::[0-5]?[0-9])+\.[0-9_]*|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))\z/,
      ~r/\A[0-9][0-9][0-9][0-9]-[0-9][0-9]?-[0-9][0-9]?/,
      ~r/\A(?:<<|=)\z/
    ]

  defp plain?(""), do: false

  defp plain?(text) do
    <<first, rest::binary>> = text
    second = :binary.first(rest <> " ")

    not (first in @indicators or
           (first in ~c"?:-" and (rest == "" or second in ~c" \t")) or
           String.starts_with?(text, ["---", "..."]) or
           String.contains?(text, [": ", " #", "\t"]) or
           String.ends_with?(text, [":", " "]) or
           String.starts_with?(text, " ") or
           not printable?(text) or
           Enum.any?(implicit(), &Regex.match?(&1, text)))
  end

  defp printable?(text),
    do: String.printable?(text) and not String.contains?(text, ["\r", <<0xFEFF::utf8>>])

  # -- acl.yaml ----------------------------------------------------------------------

  @doc """
  `acl.yaml`: the `comment` lines, then `roles` (each after its own comment, with its
  grants as flow lists) and `assignments` (principal: role).
  """
  def acl(comment, roles, assignments) do
    comments(comment, "") <>
      "roles:\n" <>
      Enum.map_join(roles, "", fn role ->
        comments(role.comment, "  ") <>
          "  #{role.name}:\n" <>
          Enum.map_join(
            for(k <- [:read, :create, :update], role[k] != nil, do: {k, role[k]}),
            "",
            fn {k, list} ->
              "    #{k}: [" <> Enum.map_join(list, ", ", &flow_scalar/1) <> "]\n"
            end
          )
      end) <>
      "assignments:\n" <>
      Enum.map_join(assignments, "", fn {principal, role} -> "  #{principal}: #{role}\n" end)
  end

  defp flow_scalar(v) do
    v = to_string(v)
    if Regex.match?(~r/\A[a-z][a-z0-9_-]*\z/, v), do: v, else: JSON.encode!(v)
  end
end

defmodule AtlasChangeset.Validate do
  @moduledoc false
  # Validation and normalisation of plain change-set data. Every accepted map comes out with
  # string keys and without absent (nil) values, so the encoder sees one shape only.

  @sha256 ~r/\A[0-9a-f]{64}\z/
  @kinds %{"file" => ["100644", "100755"], "symlink" => ["120000"]}
  @write_required ~w(kind mode op path sha256 size)
  @write_keys ["target" | @write_required]
  @delete_keys ~w(op path)

  @doc false
  # {:ok, %{"base" => base, "roots" => [%{"root" => root, "entries" => [entry]}]}} | {:error, [message]}
  def change_set(change_set) do
    with {:ok, set} <- normalize(change_set, "change set"),
         [] <- unknown_keys(set, ~w(base roots), "change set") do
      base_errors = string_errors(Map.get(set, "base"), "change set: base")

      {roots, root_errors} =
        case Map.get(set, "roots") do
          roots when is_list(roots) -> roots(roots)
          nil -> {[], ["change set: roots is missing"]}
          _ -> {[], ["change set: roots is not a list"]}
        end

      case base_errors ++ root_errors do
        [] -> {:ok, %{"base" => set["base"], "roots" => roots}}
        errors -> {:error, errors}
      end
    else
      {:error, message} -> {:error, [message]}
      errors when is_list(errors) -> {:error, errors}
    end
  end

  @doc false
  # One root on its own, as `canonical/3` and `fingerprint/3` take it.
  # {:ok, [entry]} | {:error, [message]}
  def root(base, root, entries) do
    errors = string_errors(base, "base") ++ root_name_errors(root, "root")

    {entries, entry_errors} =
      if is_list(entries),
        do: entries(entries, label(root)),
        else: {[], ["entries is not a list"]}

    case errors ++ entry_errors do
      [] -> {:ok, entries}
      errors -> {:error, errors}
    end
  end

  @doc false
  # The one entry `verify_blob/2` checks: a write, with its size and sha256.
  def write_entry(entry) do
    case entry(entry, "entry") do
      {:ok, %{"op" => "write"} = entry} -> {:ok, entry}
      {:ok, _} -> {:error, ["entry: only a write entry has a blob"]}
      {:error, errors} -> {:error, errors}
    end
  end

  defp roots(roots) do
    {roots, errors, _seen} =
      roots
      |> Enum.with_index()
      |> Enum.reduce({[], [], MapSet.new()}, fn {root, i}, {acc, errors, seen} ->
        where = "roots[#{i}]"

        with {:ok, root} <- normalize(root, where),
             [] <- unknown_keys(root, ~w(entries root), where),
             [] <- root_name_errors(Map.get(root, "root"), where <> ": root") do
          name = root["root"]

          duplicate =
            if MapSet.member?(seen, name),
              do: ["#{where}: duplicate root #{inspect(name)}"],
              else: []

          {entries, entry_errors} =
            case Map.get(root, "entries") do
              entries when is_list(entries) -> entries(entries, label(name))
              nil -> {[], ["#{where}: entries is missing"]}
              _ -> {[], ["#{where}: entries is not a list"]}
            end

          {[%{"root" => name, "entries" => entries} | acc], errors ++ duplicate ++ entry_errors,
           MapSet.put(seen, name)}
        else
          {:error, message} -> {acc, errors ++ [message], seen}
          more when is_list(more) -> {acc, errors ++ more, seen}
        end
      end)

    {Enum.reverse(roots), errors}
  end

  defp entries(entries, root_label) do
    {entries, errors, _seen} =
      entries
      |> Enum.with_index()
      |> Enum.reduce({[], [], MapSet.new()}, fn {entry, i}, {acc, errors, seen} ->
        case entry(entry, "#{root_label} entries[#{i}]") do
          {:ok, entry} ->
            path = entry["path"]

            duplicate =
              if MapSet.member?(seen, path),
                do: ["#{root_label} entries[#{i}]: duplicate path #{inspect(path)}"],
                else: []

            {[entry | acc], errors ++ duplicate, MapSet.put(seen, path)}

          {:error, more} ->
            {acc, errors ++ more, seen}
        end
      end)

    {Enum.reverse(entries), errors}
  end

  defp entry(entry, where) do
    with {:ok, entry} <- normalize(entry, where) do
      errors = path_errors(Map.get(entry, "path"), where)

      errors =
        case Map.get(entry, "op") do
          "delete" -> errors ++ delete_errors(entry, where)
          "write" -> errors ++ write_errors(entry, where)
          nil -> errors ++ ["#{where}: op is missing"]
          op -> errors ++ ["#{where}: op #{inspect(op)} is not \"write\" or \"delete\""]
        end

      if errors == [], do: {:ok, entry}, else: {:error, errors}
    else
      {:error, message} -> {:error, [message]}
    end
  end

  defp delete_errors(entry, where) do
    case entry |> Map.keys() |> Enum.reject(&(&1 in @delete_keys)) |> Enum.sort() do
      [] -> []
      extra -> ["#{where}: a delete carries only path and op, not #{Enum.join(extra, ", ")}"]
    end
  end

  defp write_errors(entry, where) do
    unknown = unknown_keys(entry, @write_keys, where)

    missing =
      for key <- @write_required, not Map.has_key?(entry, key), do: "#{where}: #{key} is missing"

    kind = Map.get(entry, "kind")
    mode = Map.get(entry, "mode")

    kind_errors =
      cond do
        kind == nil ->
          []

        not Map.has_key?(@kinds, kind) ->
          ["#{where}: kind #{inspect(kind)} is not \"file\" or \"symlink\""]

        mode == nil ->
          []

        mode in @kinds[kind] ->
          []

        mode in ["100644", "100755", "120000"] ->
          ["#{where}: mode #{mode} does not fit kind #{kind}"]

        true ->
          ["#{where}: mode #{inspect(mode)} is not 100644, 100755 or 120000"]
      end

    target_errors =
      case {kind, Map.get(entry, "target")} do
        {"symlink", nil} -> ["#{where}: a symlink needs a target"]
        {"symlink", target} -> string_errors(target, "#{where}: target")
        {_, nil} -> []
        {_, _} -> ["#{where}: only a symlink carries a target"]
      end

    size_errors =
      case Map.get(entry, "size") do
        nil -> []
        size when is_integer(size) and size >= 0 -> []
        size -> ["#{where}: size #{inspect(size)} is not a non-negative integer"]
      end

    sha_errors =
      case Map.get(entry, "sha256") do
        nil ->
          []

        sha when is_binary(sha) ->
          if sha =~ @sha256, do: [], else: ["#{where}: sha256 is not 64 lowercase hex digits"]

        _ ->
          ["#{where}: sha256 is not 64 lowercase hex digits"]
      end

    unknown ++ missing ++ kind_errors ++ target_errors ++ size_errors ++ sha_errors
  end

  # A path is relative to its root: segments separated by "/", none empty, "." or "..".
  defp path_errors(nil, where), do: ["#{where}: path is missing"]

  defp path_errors(path, where) do
    case string_errors(path, "#{where}: path") do
      [] ->
        cond do
          String.starts_with?(path, "/") ->
            ["#{where}: path #{inspect(path)} starts with /"]

          Enum.any?(String.split(path, "/"), &(&1 == "")) ->
            ["#{where}: path #{inspect(path)} has an empty segment"]

          Enum.any?(String.split(path, "/"), &(&1 in [".", ".."])) ->
            ["#{where}: path #{inspect(path)} has a . or .. segment"]

          true ->
            []
        end

      errors ->
        errors
    end
  end

  # A root is one top-level folder: one segment.
  defp root_name_errors(root, where) do
    case string_errors(root, where) do
      [] ->
        if String.contains?(root, "/") or root in [".", ".."],
          do: ["#{where} #{inspect(root)} is not one folder name"],
          else: []

      errors ->
        errors
    end
  end

  defp string_errors(nil, where), do: ["#{where} is missing"]
  defp string_errors("", where), do: ["#{where} is empty"]

  defp string_errors(value, where) when is_binary(value) do
    cond do
      not String.valid?(value) -> ["#{where} is not UTF-8"]
      String.contains?(value, <<0>>) -> ["#{where} contains a NUL"]
      true -> []
    end
  end

  defp string_errors(_value, where), do: ["#{where} is not a string"]

  defp unknown_keys(map, allowed, where) do
    case map |> Map.keys() |> Enum.reject(&(&1 in allowed)) |> Enum.sort() do
      [] -> []
      extra -> ["#{where}: unknown keys #{Enum.join(extra, ", ")}"]
    end
  end

  # Atom or string keys; a struct's tag and nil (absent) values are dropped.
  defp normalize(map, where) when is_map(map) do
    map
    |> Map.delete(:__struct__)
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      name =
        cond do
          is_atom(key) -> Atom.to_string(key)
          is_binary(key) -> key
          true -> nil
        end

      cond do
        name == nil ->
          {:halt, {:error, "#{where}: key #{inspect(key)} is not an atom or a string"}}

        value == nil ->
          {:cont, {:ok, acc}}

        Map.has_key?(acc, name) ->
          {:halt, {:error, "#{where}: key #{name} is given twice"}}

        true ->
          {:cont, {:ok, Map.put(acc, name, value)}}
      end
    end)
  end

  defp normalize(_value, where), do: {:error, "#{where} is not a map"}

  defp label(root) when is_binary(root), do: "root #{inspect(root)}"
  defp label(_root), do: "root"
end

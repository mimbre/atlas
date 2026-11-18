defmodule AtlasRuntime.S6Fixture do
  @moduledoc """
  The Elixir half of the S6 parity harness (plan s6-plan.md, package F, B2); its Go twin is
  `host/internal/s6fixture`. It loads the shared tables in `test/fixtures/s6`, builds a row's
  `fs` spec under a temporary root and substitutes the path placeholders. Both halves must
  build byte-identical trees and refuse a bad spec with the same text; the self-test in
  `test/fixtures/s6/_self` checks that. Elixir never writes an `expect` (B2).
  """

  import Bitwise

  @place_names ["tmp", "home", "user", "temporary"]
  @row_fields ~w(id fs env input expect elixir change detail_has_path note)
  @entry_fields ["path", "type", "mode", "content", "target", "head"]
  @type_fields %{
    "dir" => ["mode"],
    "file" => ["mode", "content"],
    "symlink" => ["target"],
    "hardlink" => ["target"],
    "socket" => ["mode"],
    "git" => ["head"]
  }
  @default_modes %{"dir" => "0755", "file" => "0644", "socket" => "0755"}
  @mode_pattern ~r/\A0[0-7]{3}\z/
  @head_pattern ~r{\A[A-Za-z0-9._/-]+\z}
  @row_id ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/
  # The longest socket path the BSD sockaddr_un holds (104 bytes with NUL).
  @socket_path_limit 103
  @git_config "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = false\n"

  @doc "test/fixtures/s6"
  def dir, do: Path.expand("../fixtures/s6", __DIR__)

  # Tables

  @doc "Reads a table strictly: version 1, only the documented row fields, unique ids."
  def load_table!(path) do
    table = read_json!(path)

    unless is_map(table) and Map.keys(table) -- ["version", "rows"] == [] and
             table["version"] == 1 and is_list(table["rows"]),
           do: raise("#{path}: want {\"version\": 1, \"rows\": [...]}")

    table["rows"]
    |> Enum.with_index()
    |> Enum.reduce(MapSet.new(), fn {row, i}, seen ->
      unless is_map(row), do: raise("#{path}: rows[#{i}] is not an object")

      case Map.keys(row) -- @row_fields do
        [] -> :ok
        [field | _] -> raise("#{path}: rows[#{i}]: unknown field #{inspect(field)}")
      end

      id = row["id"]

      unless is_binary(id) and Regex.match?(@row_id, id),
        do: raise("#{path}: rows[#{i}]: invalid id: #{inspect(id)}")

      if MapSet.member?(seen, id), do: raise("#{path}: rows[#{i}]: duplicate id: #{id}")
      MapSet.put(seen, id)
    end)

    table
  end

  def read_json!(path), do: path |> File.read!() |> JSON.decode!()

  # Placeholders

  @doc "{tmp} is the root, {home} the Runtime home, {user} the user's home, {temporary} the private temp."
  def default_places(root) do
    %{
      "tmp" => root,
      "home" => root <> "/home",
      "user" => root <> "/user",
      "temporary" => root <> "/temporary"
    }
  end

  def substitute(places, string) do
    Enum.reduce(@place_names, string, fn name, acc ->
      case places do
        %{^name => value} -> String.replace(acc, "{" <> name <> "}", value)
        _ -> acc
      end
    end)
  end

  @doc """
  Substitute's inverse for results: a placeholder's path that stands alone as a path (the
  bytes before and after it are not path-name bytes) becomes `{name}`; longer paths win.
  """
  def abstract(places, string) do
    order =
      @place_names
      |> Enum.filter(&Map.has_key?(places, &1))
      |> Enum.map(&{&1, places[&1]})
      |> Enum.sort_by(fn {_name, value} -> -byte_size(value) end)

    abstract(string, nil, order, [])
  end

  defp abstract(<<>>, _previous, _order, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp abstract(rest, previous, order, acc) do
    match =
      if previous == nil or not boundary_byte?(previous) do
        Enum.find(order, fn {_name, value} ->
          size = byte_size(value)

          value != "" and String.starts_with?(rest, value) and
            (byte_size(rest) == size or not name_byte?(:binary.at(rest, size)))
        end)
      end

    case match do
      {name, value} ->
        <<_::binary-size(byte_size(value)), tail::binary>> = rest
        abstract(tail, :binary.last(value), order, ["{" <> name <> "}" | acc])

      nil ->
        <<byte, tail::binary>> = rest
        abstract(tail, byte, order, [<<byte>> | acc])
    end
  end

  defp name_byte?(b),
    do: b in ?a..?z or b in ?A..?Z or b in ?0..?9 or b in [?., ?_, ?-]

  defp boundary_byte?(b), do: name_byte?(b) or b == ?/

  @doc "Substitute on every string value (not object keys) of decoded JSON."
  def substitute_value(places, value), do: map_strings(value, &substitute(places, &1))

  @doc "Abstract on every string value (not object keys) of decoded JSON."
  def abstract_value(places, value), do: map_strings(value, &abstract(places, &1))

  defp map_strings(value, f) when is_binary(value), do: f.(value)
  defp map_strings(value, f) when is_list(value), do: Enum.map(value, &map_strings(&1, f))

  defp map_strings(value, f) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, map_strings(item, f)} end)

  defp map_strings(value, _f), do: value

  # Roots

  @doc """
  A fresh canonical root for one test, removed on exit (directories are made writable first,
  so a row with a restrictive directory mode is removed too).
  """
  def new_root! do
    suffix = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    root = Path.join(System.tmp_dir!(), "s6-#{suffix}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    root = canonical(root)

    ExUnit.Callbacks.on_exit(fn ->
      unlock(root)
      File.rm_rf!(root)
    end)

    root
  end

  defp unlock(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        File.chmod(path, 0o700)
        for name <- File.ls!(path), do: unlock(Path.join(path, name))

      _ ->
        :ok
    end
  end

  defp canonical(path, depth \\ 0) do
    if depth > 40, do: raise("too many symlinks: #{path}")

    path
    |> Path.split()
    |> Enum.reduce("/", fn part, acc ->
      next = Path.join(acc, part)

      case File.lstat(next) do
        {:ok, %File.Stat{type: :symlink}} ->
          next |> File.read_link!() |> Path.expand(acc) |> canonical(depth + 1)

        _ ->
          next
      end
    end)
  end

  @doc "Builds row's fs under a new_root! and returns the root and its default places."
  def build_row!(row) do
    root = new_root!()
    places = default_places(root)

    case build(root, places, Map.get(row, "fs", [])) do
      :ok -> {root, places}
      {:error, text} -> raise "row #{row["id"]}: #{text}"
    end
  end

  # Building

  @doc """
  Creates the fs spec under root (existing, canonical). Never follows a symlink on the way.
  Returns `{:error, text}` with the text the Go builder uses; raises on unexpected I/O errors.
  """
  def build(root, places, spec) when is_list(spec) do
    {_taken, dir_modes} =
      spec
      |> Enum.with_index()
      |> Enum.reduce({MapSet.new(), %{}}, fn {entry, i}, state ->
        build_entry(root, places, i, entry, state)
      end)

    # Children before parents, so a restrictive parent mode is applied last.
    dir_modes
    |> Map.keys()
    |> Enum.sort(:desc)
    |> Enum.each(fn rel -> chmod!(Path.join(root, rel), dir_modes[rel]) end)

    :ok
  catch
    {:spec_error, text} -> {:error, text}
  end

  defp fail(i, text), do: throw({:spec_error, "fs[#{i}]: #{text}"})

  defp build_entry(_root, _places, i, entry, _state) when not is_map(entry),
    do: fail(i, "entry is not an object")

  defp build_entry(root, places, i, entry, {taken, dir_modes}) do
    case entry |> Map.keys() |> Enum.sort() |> Enum.find(&(&1 not in @entry_fields)) do
      nil -> :ok
      key -> fail(i, "unknown field: #{key}")
    end

    fields =
      Enum.reduce(@entry_fields, %{}, fn key, acc ->
        case entry do
          %{^key => value} when is_binary(value) -> Map.put(acc, key, value)
          %{^key => _} -> fail(i, "field #{key} is not a string")
          _ -> acc
        end
      end)

    path_spec = fields["path"] || fail(i, "path is required")
    kind = fields["type"] || fail(i, "type is required")
    allowed = @type_fields[kind] || fail(i, "unknown type: #{kind}")
    rel = relative(root, substitute(places, path_spec)) || fail(i, "invalid path: #{path_spec}")
    key = if kind == "git", do: rel <> "/.git", else: rel
    if MapSet.member?(taken, key), do: fail(i, "duplicate path: #{path_spec}")
    taken = MapSet.put(taken, key)

    for field <- Enum.drop(@entry_fields, 2),
        Map.has_key?(fields, field) and field not in allowed,
        do: fail(i, "field #{field} is not allowed for type #{kind}")

    mode = Map.get(fields, "mode", @default_modes[kind])

    if "mode" in allowed and not Regex.match?(@mode_pattern, mode),
      do: fail(i, "invalid mode: #{mode}")

    target = fields["target"]

    if kind in ["symlink", "hardlink"] and target == nil,
      do: fail(i, "type #{kind} requires a target")

    head = Map.get(fields, "head", "develop")

    if kind == "git" and not Regex.match?(@head_pattern, head),
      do: fail(i, "invalid head: #{head}")

    case ensure_parents(root, rel) do
      :ok -> :ok
      {:not_dir, parent} -> fail(i, "parent is not a directory: #{parent}")
    end

    path = Path.join(root, rel)
    existing = lstat(path)
    dir? = match?(%File.Stat{type: :directory}, existing)

    if existing != nil and not (kind in ["dir", "git"] and dir?),
      do: fail(i, "path exists: #{path_spec}")

    dir_modes =
      case kind do
        "dir" ->
          if existing == nil, do: mkdir!(path)
          Map.put(dir_modes, rel, mode)

        "file" ->
          File.write!(path, fields["content"] || "", [:exclusive])
          chmod!(path, mode)
          dir_modes

        "symlink" ->
          File.ln_s!(substitute(places, target), path)
          dir_modes

        "hardlink" ->
          target_rel =
            relative(root, substitute(places, target)) || fail(i, "invalid target: #{target}")

          case lstat_inside(root, target_rel) do
            %File.Stat{type: :regular} -> File.ln!(Path.join(root, target_rel), path)
            _ -> fail(i, "hardlink target is not a file: #{target}")
          end

          dir_modes

        "socket" ->
          if byte_size(path) > @socket_path_limit,
            do: fail(i, "socket path is too long: #{path_spec}")

          {:ok, socket} = :socket.open(:local, :stream, :default)
          :ok = :socket.bind(socket, %{family: :local, path: path})
          :ok = :socket.close(socket)
          chmod!(path, mode)
          dir_modes

        "git" ->
          if existing == nil, do: mkdir!(path)
          git = Path.join(path, ".git")
          if lstat(git) != nil, do: fail(i, "path exists: #{path_spec}/.git")

          for sub <- ["", "objects", "refs", "refs/heads", "refs/tags"],
              do: mkdir!(Path.join(git, sub))

          for {name, content} <- [{"HEAD", "ref: refs/heads/#{head}\n"}, {"config", @git_config}] do
            File.write!(Path.join(git, name), content, [:exclusive])
            chmod!(Path.join(git, name), "0644")
          end

          dir_modes
      end

    {taken, dir_modes}
  end

  # A clean path relative to root, or nil: empty, root itself, absolute outside root, or with
  # an empty, "." or ".." component.
  defp relative(root, path) do
    path =
      cond do
        not String.starts_with?(path, "/") ->
          path

        String.starts_with?(path, root <> "/") ->
          binary_part(path, byte_size(root) + 1, byte_size(path) - byte_size(root) - 1)

        true ->
          nil
      end

    if path not in [nil, ""] and Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."])),
      do: path
  end

  defp ensure_parents(root, rel) do
    parts = String.split(rel, "/")

    Enum.reduce_while(1..(length(parts) - 1)//1, :ok, fn n, :ok ->
      parent = parts |> Enum.take(n) |> Enum.join("/")
      path = Path.join(root, parent)

      case lstat(path) do
        nil -> mkdir!(path) && {:cont, :ok}
        %File.Stat{type: :directory} -> {:cont, :ok}
        _ -> {:halt, {:not_dir, parent}}
      end
    end)
  end

  defp lstat_inside(root, rel) do
    parts = String.split(rel, "/")

    parents_real? =
      Enum.all?(1..(length(parts) - 1)//1, fn n ->
        match?(%File.Stat{type: :directory}, lstat(Path.join([root | Enum.take(parts, n)])))
      end)

    if parents_real?, do: lstat(Path.join(root, rel))
  end

  defp lstat(path) do
    case File.lstat(path) do
      {:ok, stat} -> stat
      {:error, :enoent} -> nil
      {:error, reason} -> raise File.Error, reason: reason, action: "lstat", path: path
    end
  end

  defp mkdir!(path) do
    File.mkdir!(path)
    chmod!(path, "0755")
    true
  end

  defp chmod!(path, mode), do: File.chmod!(path, String.to_integer(mode, 8))

  # Listing and results

  @doc """
  Every entry under root (root excluded) in byte order of its relative path, not following
  symlinks, with the fields of the Go `Item`; symlink targets are abstracted with places.
  """
  def listing(root, places) do
    root |> walk("") |> Enum.map(&item(root, places, &1)) |> Enum.sort_by(& &1["path"])
  end

  defp walk(root, rel) do
    root
    |> Path.join(rel)
    |> File.ls!()
    |> Enum.flat_map(fn name ->
      child = if rel == "", do: name, else: rel <> "/" <> name

      case File.lstat!(Path.join(root, child)) do
        %File.Stat{type: :directory} -> [child | walk(root, child)]
        _ -> [child]
      end
    end)
  end

  defp item(root, places, rel) do
    path = Path.join(root, rel)
    stat = File.lstat!(path)
    mode = (stat.mode &&& 0o777) |> Integer.to_string(8) |> String.pad_leading(4, "0")

    base = %{
      "path" => rel,
      "mode" => nil,
      "target" => nil,
      "nlink" => nil,
      "size" => nil,
      "sha256" => nil
    }

    case stat.type do
      :directory ->
        Map.merge(base, %{"type" => "dir", "mode" => mode})

      :regular ->
        digest = :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

        base
        |> Map.merge(%{"type" => "file", "mode" => mode, "nlink" => stat.links})
        |> Map.merge(%{"size" => stat.size, "sha256" => digest})

      :symlink ->
        Map.merge(base, %{
          "type" => "symlink",
          "target" => abstract(places, File.read_link!(path))
        })

      _ when (stat.mode &&& 0o170000) == 0o140000 ->
        Map.merge(base, %{"type" => "socket", "mode" => mode})

      _ ->
        Map.merge(base, %{"type" => "other", "mode" => mode})
    end
  end

  @doc ~S|The self-test's verdict: %{"error" => text} for a refused spec, else %{"listing" => items}.|
  def result(root, places, spec) do
    case build(root, places, spec) do
      :ok -> %{"listing" => listing(root, places)}
      {:error, text} -> %{"error" => text}
    end
  end
end

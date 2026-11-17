defmodule AtlasRuntime.Sources.Credential do
  @moduledoc """
  The Runtime's credential for one remote work source (decision 2026-11-17 §3 "Who
  authenticates whom", §6.2 "TLS and the credential"; M2 plan W3). The source authenticates
  the Runtime by this per-Runtime bearer token; the Runtime authenticates the source by TLS
  (`AtlasRuntime.Sources.Transport`).

  It lives in the Runtime home at `sources/<name>/token`, which I8 denies to every agent
  profile (F4). The operator puts it there (M2 plan §7 step 4):

      install -d -m 0700 "$HOME_RT/sources/<name>"
      install -m 0600 /dev/stdin "$HOME_RT/sources/<name>/token"

  `load/3` takes it only when:
  - `name` is one path component of letters, digits, `.`, `_` and `-` (so the path stays
    under `sources/`);
  - `sources/` and `sources/<name>/` are directories, not symbolic links;
  - `token` is a regular file, not a symbolic link, and the file it opens is the one it
    checked (same device and inode, so a file swapped in between is refused);
  - its mode is exactly `0600`;
  - it is owned by the Runtime's own uid;
  - it holds a bearer token (an RFC 7235 token68 of at most 4096 bytes), followed by at
    most one line ending, and is not empty.

  A refusal is `{:error, {:credential, reason}}`, `reason` one atom of `t:reason/0`. It
  never quotes the file's contents.

  The token itself is handed over only inside a closure that answers the `Authorization`
  header's value (`"Bearer <token>"`). Inspecting a closure shows no captured value, so a
  process that keeps it (the transport's connection) shows no token in `inspect/2`,
  `:sys.get_state/1` or `:sys.get_status/1`. Call it only where the header is built; never
  store or log its result.
  """

  @max_token 4096
  @redacted "[redacted]"

  @typedoc "Why a credential is refused."
  @type reason ::
          :invalid_name
          | :missing
          | :directory
          | :symlink
          | :not_regular
          | :mode
          | :owner
          | :changed
          | :unreadable
          | :empty
          | :malformed

  @typedoc "Answers the `Authorization` header's value."
  @type secret :: (-> String.t())

  @doc "The credential file of source `name` in `home`: `<home>/sources/<name>/token`."
  def path(home, name), do: Path.join([home, "sources", name, "token"])

  @doc "Whether `name` can name a source's directory under `sources/`."
  def valid_name?(name) when is_binary(name),
    do: Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/, name)

  def valid_name?(_name), do: false

  @doc """
  Reads source `name`'s credential from `home` and answers `{:ok, secret}`, or
  `{:error, {:credential, reason}}`. `opts`: `uid:` the uid that must own the file (default
  the Runtime's own).
  """
  @spec load(Path.t(), String.t(), keyword()) ::
          {:ok, secret()} | {:error, {:credential, reason()}}
  def load(home, name, opts \\ []) do
    with :ok <- name(name),
         :ok <- directory(Path.join(home, "sources")),
         :ok <- directory(Path.join([home, "sources", name])),
         {:ok, stat} <- file(path(home, name)),
         :ok <- mode(stat),
         :ok <- owner(stat, Keyword.get_lazy(opts, :uid, &own_uid/0)),
         {:ok, data} <- read(path(home, name), stat),
         {:ok, token} <- token(data) do
      header = "Bearer " <> token
      {:ok, fn -> header end}
    else
      {:error, reason} -> {:error, {:credential, reason}}
    end
  end

  @doc """
  `term` with every occurrence of `token` (in a binary or a charlist, at any depth) replaced
  by `[redacted]`.
  """
  def redact(term, token) when is_binary(token) and token != "", do: scrub(term, token)

  ## The checks

  defp name(name), do: if(valid_name?(name), do: :ok, else: {:error, :invalid_name})

  defp directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink}
      {:ok, _other} -> {:error, :directory}
      {:error, :enoent} -> {:error, :missing}
      {:error, _} -> {:error, :unreadable}
    end
  end

  defp file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular} = stat} -> {:ok, stat}
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink}
      {:ok, _other} -> {:error, :not_regular}
      {:error, :enoent} -> {:error, :missing}
      {:error, _} -> {:error, :unreadable}
    end
  end

  defp mode(%File.Stat{mode: mode}),
    do: if(Bitwise.band(mode, 0o7777) == 0o600, do: :ok, else: {:error, :mode})

  defp owner(%File.Stat{uid: uid}, uid) when is_integer(uid), do: :ok
  defp owner(_stat, _uid), do: {:error, :owner}

  # The file opened is the file checked: a symlink or another file renamed in between has
  # another device or inode.
  defp read(path, %File.Stat{major_device: device, inode: inode}) do
    case :file.open(path, [:read, :raw, :binary]) do
      {:ok, fd} ->
        try do
          opened(fd, device, inode)
        after
          :file.close(fd)
        end

      {:error, _} ->
        {:error, :unreadable}
    end
  end

  defp opened(fd, device, inode) do
    with {:ok, info} <- :file.read_file_info(fd, time: :posix),
         %File.Stat{type: :regular, major_device: ^device, inode: ^inode} <-
           File.Stat.from_record(info) do
      case :file.read(fd, @max_token + 3) do
        {:ok, data} -> {:ok, data}
        :eof -> {:ok, ""}
        {:error, _} -> {:error, :unreadable}
      end
    else
      {:error, _} -> {:error, :unreadable}
      %File.Stat{} -> {:error, :changed}
    end
  end

  # One trailing line ending is allowed (an operator's `echo`).
  defp token(data) do
    token =
      cond do
        String.ends_with?(data, "\r\n") -> binary_part(data, 0, byte_size(data) - 2)
        String.ends_with?(data, "\n") -> binary_part(data, 0, byte_size(data) - 1)
        true -> data
      end

    cond do
      token == "" -> {:error, :empty}
      byte_size(token) > @max_token -> {:error, :malformed}
      Regex.match?(~r/\A[A-Za-z0-9._~+\/-]+=*\z/, token) -> {:ok, token}
      true -> {:error, :malformed}
    end
  end

  # Erlang has no getuid(); `id -u` answers it once per node.
  defp own_uid do
    case :persistent_term.get({__MODULE__, :uid}, nil) do
      nil ->
        uid =
          case System.cmd("/usr/bin/id", ["-u"], stderr_to_stdout: true) do
            {out, 0} -> String.to_integer(String.trim(out))
            _ -> :unknown
          end

        :persistent_term.put({__MODULE__, :uid}, uid)
        uid

      uid ->
        uid
    end
  rescue
    _ -> :unknown
  end

  ## Redaction

  defp scrub(bin, token) when is_binary(bin) do
    if :binary.match(bin, token) == :nomatch,
      do: bin,
      else: :binary.replace(bin, token, @redacted, [:global])
  end

  defp scrub(list, token) when is_list(list) do
    if chars?(list) do
      case :unicode.characters_to_binary(list) do
        bin when is_binary(bin) ->
          if :binary.match(bin, token) == :nomatch,
            do: list,
            else: String.to_charlist(:binary.replace(bin, token, @redacted, [:global]))

        _not_unicode ->
          list
      end
    else
      scrub_items(list, token)
    end
  end

  defp scrub(tuple, token) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> scrub_items(token) |> List.to_tuple()

  defp scrub(map, token) when is_map(map),
    do: :maps.fold(fn k, v, acc -> Map.put(acc, scrub(k, token), scrub(v, token)) end, %{}, map)

  defp scrub(other, _token), do: other

  defp chars?([c | rest]) when is_integer(c) and c in 0..0x10FFFF, do: chars?(rest)
  defp chars?([]), do: true
  defp chars?(_), do: false

  # Also an improper list's tail.
  defp scrub_items([item | rest], token), do: [scrub(item, token) | scrub_items(rest, token)]
  defp scrub_items([], _token), do: []
  defp scrub_items(tail, token), do: scrub(tail, token)
end

defmodule AtlasRuntime.Backend.Clients do
  @moduledoc """
  The loopback TCP listener's clients: `$ATLAS_RUNTIME_HOME/clients.json` (design §8.1,
  §9; S3 plan B2–B4). Human-owned, like `policy.json`: the Runtime reads it and never
  writes it.

      {"version": 1,
       "listen": {"port": 8443},
       "clients": [{"name": "core", "token_sha256": "<64 lowercase hex>",
                    "rights": ["read"], "disabled": false}]}

  - `name` matches `^[a-z0-9][a-z0-9_-]{0,62}$` and is unique; the client is
    `token:<name>`.
  - `token_sha256` is the SHA-256 of the token, 64 lowercase hex characters, unique. The
    token itself is never stored.
  - `rights` are names of rights within the TCP listener's ceiling (the contract's
    `rights :tcp`). A right outside it, `choose_slot` and `choose_path` included, makes
    the **file** invalid; it is never silently cut down (B2).
  - `disabled` (optional, boolean): the entry is kept but no longer authenticates.
  - No other field is allowed anywhere.

  The file must be a regular file (no symlink), mode 0600 and owned by the Runtime's uid.

  It is read on every request (`load/3`), with no cache (B3): an edit, a revocation or a
  broken file takes effect on the next request. A reason for refusing the file names the
  problem and where it is, never a value from the file.
  """

  import Bitwise

  @file_name "clients.json"
  @name ~r/\A[a-z0-9][a-z0-9_-]{0,62}\z/
  @hash ~r/\A[0-9a-f]{64}\z/
  @top ["version", "listen", "clients"]
  @entry ["name", "token_sha256", "rights", "disabled"]

  @typedoc "One loaded entry; `rights` are atoms of the ceiling."
  @type entry :: %{name: String.t(), token_sha256: String.t(), rights: [atom], disabled: boolean}

  @type config :: %{port: 1..65_535, clients: [entry]}

  @doc "The file's path in `home`."
  def path(home), do: Path.join(home, @file_name)

  @doc """
  Reads and checks `<home>/clients.json`. `ceiling` is the TCP listener's rights (atoms);
  `uid` the Runtime's uid, which must own the file.

  Gives `{:ok, config}`, `:none` when there is no file, or `{:error, reason}` (text that
  quotes nothing from the file).
  """
  @spec load(Path.t(), [atom], non_neg_integer) :: {:ok, config} | :none | {:error, String.t()}
  def load(home, ceiling, uid) do
    file = path(home)

    with {:ok, stat} <- stat(file),
         :ok <- private(stat, uid),
         {:ok, binary} <- read(file),
         {:ok, data} <- decode(binary) do
      parse(data, ceiling)
    end
  end

  @doc """
  The entry `token` belongs to: `{:ok, entry}`, or `:error` when it matches none or only a
  disabled one. The token's SHA-256 is compared with `Plug.Crypto.secure_compare/2` against
  every entry, with no early exit, so the time taken does not depend on which entry (if any)
  matches.
  """
  @spec authenticate([entry], String.t()) :: {:ok, entry} | :error
  def authenticate(entries, token) when is_binary(token) do
    hash = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

    found =
      Enum.reduce(entries, nil, fn entry, found ->
        if Plug.Crypto.secure_compare(hash, entry.token_sha256), do: entry, else: found
      end)

    case found do
      %{disabled: false} = entry -> {:ok, entry}
      _ -> :error
    end
  end

  @doc "The uid this process runs as, from `id -u` (the process's credentials, not the environment)."
  def uid do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {out, 0} ->
        case Integer.parse(String.trim(out)) do
          {uid, ""} -> {:ok, uid}
          _ -> {:error, :no_uid}
        end

      _ ->
        {:error, :no_uid}
    end
  rescue
    ErlangError -> {:error, :no_uid}
  end

  ## The file

  defp stat(file) do
    case File.lstat(file) do
      {:ok, %File.Stat{type: :regular} = stat} -> {:ok, stat}
      {:ok, %File.Stat{}} -> {:error, "#{@file_name} is not a regular file"}
      {:error, :enoent} -> :none
      {:error, reason} -> {:error, "#{@file_name} cannot be read (#{reason})"}
    end
  end

  defp private(%File.Stat{mode: mode, uid: owner}, uid) do
    cond do
      (mode &&& 0o777) != 0o600 ->
        {:error,
         "#{@file_name} has mode #{Integer.to_string(mode &&& 0o777, 8)}; it must be 0600"}

      owner != uid ->
        {:error, "#{@file_name} is not owned by the Runtime's uid"}

      true ->
        :ok
    end
  end

  defp read(file) do
    case File.read(file) do
      {:ok, binary} -> {:ok, binary}
      {:error, reason} -> {:error, "#{@file_name} cannot be read (#{reason})"}
    end
  end

  defp decode(binary) do
    case JSON.decode(binary) do
      {:ok, data} -> {:ok, data}
      {:error, _reason} -> {:error, "#{@file_name} is no JSON"}
    end
  end

  ## Its content

  defp parse(%{} = data, ceiling) do
    with :ok <- only(data, @top, "the top level"),
         :ok <- version(data),
         {:ok, port} <- port(data),
         {:ok, clients} <- clients(data, Map.new(ceiling, &{Atom.to_string(&1), &1})) do
      {:ok, %{port: port, clients: clients}}
    end
  end

  defp parse(_data, _ceiling), do: invalid("the top level is no object")

  defp version(%{"version" => 1}), do: :ok
  defp version(_), do: invalid("version must be 1")

  defp port(%{"listen" => %{} = listen}) do
    with :ok <- only(listen, ["port"], "listen") do
      case listen do
        %{"port" => port} when is_integer(port) and port in 1..65_535 -> {:ok, port}
        _ -> invalid("listen.port must be an integer from 1 to 65535")
      end
    end
  end

  defp port(_), do: invalid("listen must be an object with port")

  defp clients(%{"clients" => list}, rights) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], MapSet.new(), MapSet.new()}, fn {item, i},
                                                                   {:ok, acc, names, hashes} ->
      case entry(item, "clients[#{i}]", rights) do
        {:ok, entry} ->
          cond do
            entry.name in names ->
              {:halt, invalid("clients[#{i}].name is not unique")}

            entry.token_sha256 in hashes ->
              {:halt, invalid("clients[#{i}].token_sha256 is not unique")}

            true ->
              {:cont,
               {:ok, [entry | acc], MapSet.put(names, entry.name),
                MapSet.put(hashes, entry.token_sha256)}}
          end

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, entries, _names, _hashes} -> {:ok, Enum.reverse(entries)}
      {:error, _} = error -> error
    end
  end

  defp clients(_, _rights), do: invalid("clients must be a list")

  defp entry(%{} = item, at, rights) do
    with :ok <- only(item, @entry, at),
         {:ok, name} <-
           field(
             item,
             "name",
             at,
             &(is_binary(&1) and Regex.match?(@name, &1)),
             "must match ^[a-z0-9][a-z0-9_-]{0,62}$"
           ),
         {:ok, hash} <-
           field(
             item,
             "token_sha256",
             at,
             &(is_binary(&1) and Regex.match?(@hash, &1)),
             "must be 64 lowercase hex characters"
           ),
         {:ok, names} <-
           field(
             item,
             "rights",
             at,
             &(is_list(&1) and Enum.all?(&1, fn r -> is_binary(r) end) and Enum.uniq(&1) == &1),
             "must be a list of right names, each once"
           ),
         {:ok, granted} <- granted(names, rights, at),
         {:ok, disabled} <- disabled(item, at) do
      {:ok, %{name: name, token_sha256: hash, rights: granted, disabled: disabled}}
    end
  end

  defp entry(_item, at, _rights), do: invalid("#{at} is no object")

  defp field(item, key, at, valid?, rule) do
    case Map.fetch(item, key) do
      {:ok, value} -> if valid?.(value), do: {:ok, value}, else: invalid("#{at}.#{key} #{rule}")
      :error -> invalid("#{at}.#{key} is missing")
    end
  end

  # B2: every right must be within the ceiling; one outside makes the file invalid.
  defp granted(names, rights, at) do
    if Enum.all?(names, &Map.has_key?(rights, &1)),
      do: {:ok, Enum.map(names, &Map.fetch!(rights, &1))},
      else: invalid("#{at}.rights names a right outside the TCP listener's rights")
  end

  defp disabled(item, at) do
    case Map.get(item, "disabled", false) do
      flag when is_boolean(flag) -> {:ok, flag}
      _ -> invalid("#{at}.disabled must be true or false")
    end
  end

  defp only(map, allowed, at) do
    if Map.keys(map) -- allowed == [],
      do: :ok,
      else: invalid("#{at} has a field that is not allowed")
  end

  defp invalid(why), do: {:error, "#{@file_name} is invalid: #{why}"}
end

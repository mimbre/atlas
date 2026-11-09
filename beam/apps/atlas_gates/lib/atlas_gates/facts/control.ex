defmodule AtlasGates.Facts.Control do
  @moduledoc """
  Records verdicts through Control with the `atlas` client, for a caller that is not in a
  node with the core's Bus: `atlas put <kind> --<field> <value> … --link <relation>=<key>`
  and `atlas list` / `atlas get`, each with `--env` and `--json`. Control makes the key (the
  next number) and writes the fact over the Bus to Facts, under the same rules as any
  other write.

  Control takes no request id, so a repeat is found by its values: the newest verdict of
  the kind whose fields hold every value of the request's identity.
  """
  @behaviour AtlasGates.Facts

  @doc """
  The state for environment `env`: `client` is a function of the client's arguments
  answering `{:ok, json}` or `{:error, reason}`; by default the `atlas` executable
  (`atlas` on PATH, or `executable`).
  """
  def new(env, opts \\ []) when env in ["test", "prod"] do
    client = Keyword.get(opts, :client) || (&run(Keyword.get(opts, :executable, "atlas"), &1))
    {__MODULE__, %{env: env, client: client}}
  end

  @impl true
  def find(state, kind, identity) do
    with {:ok, rows} when is_list(rows) <- call(state, ["list", kind]) do
      Enum.reduce_while(rows, {:ok, nil}, fn row, acc ->
        case call(state, ["get", row["key"]]) do
          {:ok, %{"fields" => fields}} ->
            values = Enum.map(fields, fn [_label, value] -> to_string(value) end)

            if Enum.all?(identity, &(&1 in values)),
              do: {:halt, {:ok, row["key"]}},
              else: {:cont, acc}

          {:ok, _} ->
            {:cont, acc}

          {:error, _} = error ->
            {:halt, error}
        end
      end)
    else
      {:ok, other} -> {:error, "atlas list answered #{inspect(other)}"}
      error -> error
    end
  end

  @impl true
  def create(state, kind, _request_id, values, links) do
    # Text of several lines goes in a file (`--<field>-file`), the rest as it is.
    {files, args} =
      Enum.reduce(Enum.sort(values), {[], []}, fn {field, value}, {files, args} ->
        text = to_string(value)

        if String.contains?(text, "\n") do
          file = scratch(field)
          File.write!(file, text)
          {[file | files], args ++ ["--#{field}-file", file]}
        else
          {files, args ++ ["--#{field}", text]}
        end
      end)

    link_args = Enum.flat_map(Enum.sort(links), fn {rel, key} -> ["--link", "#{rel}=#{key}"] end)

    try do
      case call(state, ["put", kind | args ++ link_args]) do
        {:ok, %{"key" => key}} when is_binary(key) -> {:ok, key}
        {:ok, other} -> {:error, "atlas put answered #{inspect(other)}"}
        error -> error
      end
    after
      Enum.each(files, &File.rm/1)
    end
  end

  defp call(state, args), do: state.client.(args ++ ["--env", state.env, "--json"])

  defp scratch(field),
    do: Path.join(System.tmp_dir!(), "atlas-gates-#{field}-#{System.unique_integer([:positive])}")

  # The `atlas` client prints one JSON value with --json; exit 1 is a refusal, 2 an error.
  defp run(executable, args) do
    case System.cmd(executable, args, stderr_to_stdout: false) do
      {out, 0} ->
        case JSON.decode(out) do
          {:ok, value} -> {:ok, value}
          _ -> {:error, "atlas #{hd(args)} printed no JSON"}
        end

      {out, status} ->
        why =
          case JSON.decode(out) do
            {:ok, %{"error" => text}} -> text
            {:ok, %{"refused" => reasons}} -> Enum.join(List.wrap(reasons), "; ")
            _ -> "exit status #{status}"
          end

        {:error, "atlas #{hd(args)} failed: #{why}"}
    end
  rescue
    error in ErlangError -> {:error, "cannot run #{executable}: #{inspect(error.original)}"}
  end
end

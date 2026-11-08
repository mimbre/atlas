defmodule AtlasRuntime.Providers.Codex do
  @moduledoc """
  Codex model identity from this invocation's native rollout evidence. Exec JSON omits the
  model, so only a turn context of the confirmed session, in the launch workspace and at or
  after the host-captured launch time, counts. Anything unreadable leaves identity unknown.
  """

  @session ~r/\A[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\z/

  def model(session, workspace, home, %DateTime{} = started_at)
      when is_binary(session) and is_binary(workspace) and is_binary(home) do
    if Regex.match?(@session, session) do
      try do
        home
        |> Path.join("sessions")
        |> rollouts(session)
        |> Enum.reduce(nil, &evidence(&1, session, workspace, started_at, &2))
      catch
        :unknown -> nil
      end
    end
  end

  def model(_, _, _, _), do: nil

  # sessions/*/*/*/rollout-*-<session>.jsonl, in directory order; unreadable directories are skipped.
  defp rollouts(sessions, session) do
    suffix = "-" <> session <> ".jsonl"

    for year <- dirs(sessions),
        month <- dirs(year),
        day <- dirs(month),
        name <- entries(day),
        byte_size(name) >= byte_size("rollout-" <> suffix),
        String.starts_with?(name, "rollout-") and String.ends_with?(name, suffix),
        do: Path.join(day, name)
  end

  defp dirs(dir),
    do: for(name <- entries(dir), path = Path.join(dir, name), File.dir?(path), do: path)

  defp entries(dir) do
    case File.ls(dir) do
      {:ok, names} -> names
      {:error, _} -> []
    end
  end

  # The latest matching turn context wins, across files in traversal order.
  defp evidence(path, session, workspace, started_at, model) do
    case lines(path) do
      [first | records] ->
        metadata = object!(decode!(first))

        if metadata["type"] == "session_meta" and
             object!(Map.get(metadata, "payload", %{}))["id"] == session,
           do: Enum.reduce(records, model, &context(&1, workspace, started_at, &2)),
           else: model

      [] ->
        throw(:unknown)
    end
  end

  defp context(line, workspace, started_at, model) do
    record = object!(decode!(line))

    if record["type"] == "turn_context" do
      context = Map.get(record, "payload", %{})

      with {:ok, timestamp} <- timestamp!(Map.get(record, "timestamp", "")),
           true <- DateTime.compare(timestamp, started_at) != :lt,
           context = object!(context),
           true <- context["cwd"] == workspace,
           value when is_binary(value) and value not in ["", "<synthetic>"] <- context["model"] do
        value
      else
        _ -> model
      end
    else
      model
    end
  end

  # Universal newlines; a final newline does not add an empty record.
  defp lines(path) do
    case File.read(path) do
      {:ok, text} ->
        lines =
          text |> String.replace("\r\n", "\n") |> String.replace("\r", "\n") |> String.split("\n")

        if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines

      {:error, _} ->
        throw(:unknown)
    end
  end

  defp decode!(line) do
    case JSON.decode(line) do
      {:ok, value} -> value
      _ -> throw(:unknown)
    end
  end

  defp object!(value) when is_map(value), do: value
  defp object!(_), do: throw(:unknown)

  # Offset-less timestamps are not evidence; malformed ones make the evidence unreadable.
  defp timestamp!(text) when is_binary(text) do
    text = String.replace(text, "Z", "+00:00")

    with {:error, _} <- DateTime.from_iso8601(text),
         {:error, _} <- DateTime.from_iso8601(text, Calendar.ISO, :basic) do
      naive =
        match?({:ok, _}, NaiveDateTime.from_iso8601(text)) or
          match?({:ok, _}, Date.from_iso8601(text))

      if naive, do: :naive, else: throw(:unknown)
    else
      {:ok, timestamp, _offset} -> {:ok, timestamp}
    end
  end

  defp timestamp!(_), do: throw(:unknown)
end

defmodule AtlasLearn.Observations.CodeChanges do
  @moduledoc """
  Changes through Code: the changes submitted to Code, the reviews it opened and the
  integrations it attempted, read from the records Code keeps in its home (`changes/`,
  `reviews/`, `integrations/`, described in Code's own module documentation). Code has no
  read endpoint for them, so this observation reads those records as they are, read-only,
  and nothing else in the home: never the tokens, the cache or the snapshots.

  Code's records carry no time, so a record is in the window when its file last changed in
  it (Code rewrites a record on every phase). Records outside the window stay available as
  context, so a second review of the same work is seen next to the first.

  Options: `code_home`.
  """
  alias AtlasLearn.{Observations, Window}

  @name "Changes through Code"

  def observe(window, opts) do
    case opts[:code_home] do
      nil ->
        Observations.not_asked(@name, "no Code home given")

      home ->
        source = "Code records in #{home}"

        if File.dir?(home) do
          {records, unreadable} =
            (changes(home) ++ reviews(home) ++ integrations(home))
            |> Enum.split_with(&match?({:ok, _}, &1))

          records = Enum.map(records, fn {:ok, record} -> record end)
          {inside, outside} = Enum.split_with(records, &Window.within?(window, &1.at))

          %{
            name: @name,
            source: source,
            status: :read,
            records: inside,
            context: outside,
            notes:
              Enum.map(unreadable, fn {:error, path} -> "Unreadable record: #{path}" end) ++
                [
                  "Code records no time; the window uses each record file's last change.",
                  "Code does not record a refused fingerprint check: the refusal is only a reply.",
                  "Code does not know CI outcomes, so none are shown."
                ]
          }
        else
          Observations.unavailable(@name, source, "no such folder")
        end
    end
  end

  defp changes(home) do
    for {id, path} <- entries(home, "changes", &Path.join(&1, "request.json")) do
      with {:ok, request} <- record(path) do
        sealed? = File.exists?(Path.join(Path.dirname(path), "revision"))

        {:ok,
         %{
           id: "change " <> id,
           type: :change,
           change_id: id,
           repository: request["repository"],
           phase: if(sealed?, do: "sealed", else: "open"),
           at: changed_at(path)
         }}
      end
    end
  end

  defp reviews(home) do
    for {id, path} <- entries(home, "reviews", & &1) do
      with {:ok, review} <- record(path) do
        request = review["request"] || %{}

        {:ok,
         %{
           id: "review " <> id,
           type: :review,
           review_id: id,
           change_id: review["change_id"] || request["change_id"],
           repository: review["repository"],
           target: request["target"],
           title: request["title"],
           phase: review["phase"],
           at: changed_at(path)
         }}
      end
    end
  end

  defp integrations(home) do
    for {id, path} <- entries(home, "integrations", & &1) do
      with {:ok, integration} <- record(path) do
        request = integration["request"] || %{}

        {:ok,
         %{
           id: "integration " <> id,
           type: :integration,
           integration_id: id,
           review_id: request["review_id"],
           repository: integration["repository"],
           target: integration["target"],
           phase: integration["phase"],
           at: changed_at(path)
         }}
      end
    end
  end

  # `{id, record path}` per entry of `home/dir`: `<id>.json` files, or `<id>/` folders whose
  # record `file` names.
  defp entries(home, dir, file) do
    root = Path.join(home, dir)

    case File.ls(root) do
      {:ok, names} ->
        for name <- Enum.sort(names),
            path = file.(Path.join(root, name)),
            id = Path.basename(name, ".json"),
            File.regular?(path),
            do: {id, path}

      {:error, _} ->
        []
    end
  end

  defp record(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, %{} = record} <- JSON.decode(bytes) do
      {:ok, record}
    else
      _ -> {:error, path}
    end
  end

  defp changed_at(path) do
    %File.Stat{mtime: seconds} = File.stat!(path, time: :posix)
    DateTime.from_unix!(seconds)
  end
end

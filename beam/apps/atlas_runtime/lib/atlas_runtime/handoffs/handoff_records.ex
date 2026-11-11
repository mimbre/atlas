defmodule AtlasRuntime.HandoffRecords do
  @moduledoc "Immutable coordinator declarations with a bounded execution-event publication checkpoint."
  alias AtlasRuntime.ExecutionEvents

  defmodule StorageError do
    defexception [:message]
  end

  @max_bytes 65_536
  @max_declaration_bytes 32_768
  @fields ~w(kind repository_url branch base_sha head_sha result verification limits remaining_processes)
  @provenance "coordinator_submitted_declaration"
  @turn ~r/\Aturn-[0-9a-f]{16}\z/
  @worker ~r/\A[a-z][a-z0-9_-]{0,63}\z/
  @sha ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  @repository ~r/\Ahttps:\/\/github\.com\/([A-Za-z0-9-]+)\/([A-Za-z0-9_.-]+)\z/
  @pull_request ~r/\Ahttps:\/\/github\.com\/([A-Za-z0-9-]+)\/([A-Za-z0-9_.-]+)\/pull\/([1-9][0-9]*)\z/

  def submit(dir, events, run, declaration) do
    unless is_map(run) and text_match?(run["worker_id"], @worker) and
             text_match?(run["turn_id"], @turn),
           do: raise(ArgumentError, "Invalid handoff worker or turn")

    validate_declaration!(declaration)

    case load(dir, run["turn_id"]) do
      nil ->
        bind_repository!(run["repository"], declaration)

        storage(fn ->
          record = %{
            "version" => 1,
            "published" => false,
            "worker_id" => run["worker_id"],
            "turn_id" => run["turn_id"],
            "record_ref" => reference(run["turn_id"]),
            "submitted_at" => DateTime.to_iso8601(DateTime.utc_now()),
            "provenance" => @provenance,
            "handoff" => declaration
          }

          persist(dir, record)
          publish(dir, events, record)
        end)

      record ->
        unless record["worker_id"] == run["worker_id"] and record["handoff"] == declaration,
          do: raise(ArgumentError, "Conflicting handoff already recorded for this turn")

        storage(fn -> publish(dir, events, record) end)
    end
  end

  def load(dir, turn) do
    unless text_match?(turn, @turn), do: raise(ArgumentError, "Invalid handoff turn")

    storage(fn ->
      check_directories(dir, turn)
      path = Path.join(dir, reference(turn))

      case File.lstat(path) do
        {:error, :enoent} ->
          nil

        {:ok, %{type: :regular, links: 1, size: size}} when size <= @max_bytes ->
          record = path |> File.read!() |> JSON.decode!() |> validate_record!()

          unless record["turn_id"] == turn,
            do: raise("Handoff record ownership does not match its path")

          record

        {:ok, _} ->
          raise("Invalid or oversized handoff record file")

        {:error, reason} ->
          raise File.Error, reason: reason, action: "read handoff record", path: path
      end
    end)
  end

  def public(record), do: Map.drop(record, ["version", "published"])

  def recover(dir, events) do
    storage(fn ->
      turns = Path.join(dir, "turns")
      check_type(turns, :directory)

      names =
        case File.ls(turns) do
          {:ok, names} ->
            names

          {:error, :enoent} ->
            []

          {:error, reason} ->
            raise File.Error, reason: reason, action: "read handoff turns", path: turns
        end

      names
      |> Enum.filter(&text_match?(&1, @turn))
      |> Enum.sort()
      |> Enum.reduce(events, fn turn, events ->
        case load(dir, turn) do
          nil -> events
          record -> elem(publish(dir, events, record), 1)
        end
      end)
    end)
  end

  defp publish(dir, events, %{"published" => true} = record) do
    retained =
      Enum.any?(events["events"], fn event ->
        event["kind"] == "handoff_submitted" and event["turn_id"] == record["turn_id"]
      end)

    events = if retained, do: ExecutionEvents.append_handoff(dir, events, record), else: events
    {record, events}
  end

  defp publish(dir, events, record) do
    events = ExecutionEvents.append_handoff(dir, events, record)
    record = Map.put(record, "published", true)
    persist(dir, record)
    {record, events}
  end

  defp persist(dir, record) do
    validate_record!(record)
    encoded = JSON.encode!(record)
    if byte_size(encoded) > @max_bytes, do: raise("Oversized handoff record")
    check_directories(dir, record["turn_id"])
    path = Path.join(dir, record["record_ref"])
    check_type(path, :regular)
    check_type(path <> ".tmp", :regular)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path <> ".tmp", encoded)
    File.rename!(path <> ".tmp", path)
  end

  defp check_directories(dir, turn) do
    check_type(Path.join(dir, "turns"), :directory)
    check_type(Path.join([dir, "turns", turn]), :directory)
  end

  defp check_type(path, type) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %{type: ^type, links: links}} when type != :regular or links == 1 ->
        :ok

      {:ok, _} ->
        raise("Invalid handoff storage path")

      {:error, reason} ->
        raise File.Error, reason: reason, action: "inspect handoff path", path: path
    end
  end

  defp validate_record!(record) do
    valid =
      is_map(record) and map_size(record) == 8 and record["version"] == 1 and
        is_boolean(record["published"]) and text_match?(record["worker_id"], @worker) and
        text_match?(record["turn_id"], @turn) and
        record["record_ref"] == reference(record["turn_id"]) and
        record["provenance"] == @provenance and text?(record["submitted_at"], 64) and
        match?({:ok, _, _}, DateTime.from_iso8601(record["submitted_at"]))

    unless valid, do: raise("Invalid handoff record")
    validate_declaration!(record["handoff"])
    record
  end

  defp validate_declaration!(declaration) do
    valid =
      is_map(declaration) and declaration["kind"] in ["completion", "pull_request"] and
        Enum.sort(Map.keys(declaration)) ==
          Enum.sort(
            @fields ++ if(declaration["kind"] == "pull_request", do: ["pr_url"], else: [])
          ) and
        text?(declaration["branch"], 255) and text?(declaration["result"], 4096) and
        text_match?(declaration["base_sha"], @sha) and text_match?(declaration["head_sha"], @sha) and
        Enum.all?(~w(verification limits remaining_processes), &entries?(declaration[&1]))

    unless valid, do: raise(ArgumentError, "Invalid handoff declaration fields")
    repository = repository_identity(declaration["repository_url"])
    unless repository, do: raise(ArgumentError, "Invalid handoff repository URL")

    if declaration["kind"] == "pull_request" and
         pull_request_identity(declaration["pr_url"]) != repository,
       do: raise(ArgumentError, "Handoff PR URL must match its GitHub repository")

    if byte_size(JSON.encode!(declaration)) > @max_declaration_bytes,
      do: raise(ArgumentError, "Oversized handoff declaration")

    declaration
  end

  defp bind_repository!(nil, _declaration), do: :ok

  defp bind_repository!(repository, declaration) when is_map(repository) do
    Enum.each(
      [{"url", "repository_url"}, {"branch", "branch"}, {"base_sha", "base_sha"}],
      fn {saved, field} ->
        if Map.has_key?(repository, saved) do
          matches =
            if saved == "url" do
              identity = repository_identity(repository[saved])
              not is_nil(identity) and identity == repository_identity(declaration[field])
            else
              repository[saved] == declaration[field]
            end

          unless matches,
            do: raise(ArgumentError, "Handoff #{field} does not match saved repository")
        end
      end
    )
  end

  defp bind_repository!(_, _),
    do: raise(StorageError, message: "Invalid saved handoff repository")

  defp repository_identity(value) do
    case captures(value, @repository) do
      [owner, repository] -> identity(owner, repository)
      _ -> nil
    end
  end

  defp pull_request_identity(value) do
    case captures(value, @pull_request) do
      [owner, repository, _number] -> identity(owner, repository)
      _ -> nil
    end
  end

  defp identity(owner, repository) do
    repository = repository |> String.downcase() |> String.replace_suffix(".git", "")
    if repository not in ["", ".", ".."], do: {String.downcase(owner), repository}
  end

  defp captures(value, regex) do
    if is_binary(value) and String.valid?(value),
      do: Regex.run(regex, value, capture: :all_but_first)
  end

  defp entries?(entries) when is_list(entries) and length(entries) <= 16,
    do: Enum.all?(entries, &text?(&1, 1024))

  defp entries?(_), do: false

  defp text?(value, max),
    do:
      is_binary(value) and byte_size(value) in 1..max and String.valid?(value) and
        String.trim(value) != ""

  defp text_match?(value, regex),
    do: is_binary(value) and String.valid?(value) and Regex.match?(regex, value)

  defp reference(turn), do: Path.join(["turns", turn, "handoff.json"])

  defp storage(fun) do
    fun.()
  rescue
    error in StorageError -> reraise error, __STACKTRACE__
    error -> raise StorageError, message: "Handoff storage failed: #{Exception.message(error)}"
  end
end

defmodule AtlasRuntime.PeerQuestionRecords do
  @moduledoc "Bounded coordinator-routed references with immutable binding and checkpointed publication."
  alias AtlasRuntime.ExecutionEvents

  defmodule StorageError do
    defexception [:message]
  end

  @max_bytes 16_384
  @turn ~r/\Aturn-[0-9a-f]{16}\z/
  @worker ~r/\A[a-z][a-z0-9_-]{0,63}\z/
  @question ~r/\Aquestion-[0-9a-f]{1,64}\z/
  @kinds ~w(peer_question_routed peer_reply_bound)
  @identity ~w(worker_id turn_id question_id peer_worker_id peer_source_turn_id record_ref)
  @fields Enum.sort(
            ~w(version worker_id turn_id question_id question_ref peer_worker_id peer_source_turn_id
    response_turn_id record_ref provenance created_at bound_at revision published_revision transitions)
          )

  def reference(turn, question),
    do: Path.join(["turns", turn, "peer-questions", question <> ".json"])

  def load(dir, turn, question) do
    validate_ids!(turn, question)

    storage(fn ->
      check_directories(dir, turn)
      path = Path.join(dir, reference(turn, question))

      case File.lstat(path) do
        {:error, :enoent} ->
          nil

        {:ok, %{type: :regular, links: 1, size: size}} when size <= @max_bytes ->
          record = path |> File.read!() |> JSON.decode!() |> validate!()

          unless record["turn_id"] == turn and record["question_id"] == question,
            do: raise("Peer question record ownership does not match its path")

          record

        {:ok, _} ->
          raise("Invalid or oversized peer question record file")

        {:error, reason} ->
          raise File.Error, reason: reason, action: "read peer question record", path: path
      end
    end)
  end

  def create(dir, events, question, source) do
    unless is_map(question) and is_map(source) and
             text_match?(question["worker_id"], @worker) and
             text_match?(source["worker_id"], @worker) and
             question["worker_id"] != source["worker_id"] and
             text_match?(source["turn_id"], @turn),
           do: raise(ArgumentError, "Invalid peer question ownership")

    validate_ids!(question["turn_id"], question["question_id"])

    unless question["record_ref"] ==
             question_reference(question["turn_id"], question["question_id"]) and
             source["turn_id"] != question["turn_id"],
           do: raise(ArgumentError, "Invalid peer question source or reference")

    case load(dir, question["turn_id"], question["question_id"]) do
      record when is_map(record) ->
        unless record["worker_id"] == question["worker_id"] and
                 record["peer_worker_id"] == source["worker_id"] and
                 record["peer_source_turn_id"] == source["turn_id"],
               do: raise(ArgumentError, "Conflicting peer question route")

        storage(fn -> publish(dir, events, record) end)

      nil ->
        storage(fn ->
          record = %{
            "version" => 1,
            "worker_id" => question["worker_id"],
            "turn_id" => question["turn_id"],
            "question_id" => question["question_id"],
            "question_ref" => question["record_ref"],
            "peer_worker_id" => source["worker_id"],
            "peer_source_turn_id" => source["turn_id"],
            "response_turn_id" => nil,
            "record_ref" => reference(question["turn_id"], question["question_id"]),
            "provenance" => "coordinator_routed_declaration",
            "created_at" => timestamp(),
            "bound_at" => nil,
            "revision" => 1,
            "published_revision" => 0,
            "transitions" => []
          }

          record = Map.put(record, "transitions", [transition(record, 1)])
          persist(dir, record)
          publish(dir, events, record)
        end)
    end
  end

  def bind(dir, events, record, response) do
    unless is_map(record) and is_map(response) and text_match?(response["turn_id"], @turn) and
             text_match?(response["worker_id"], @worker),
           do: raise(ArgumentError, "Invalid peer response identity")

    saved =
      case load(dir, record["turn_id"], record["question_id"]) do
        nil -> raise ArgumentError, "Peer question route not found"
        saved -> saved
      end

    unless routed(saved) == routed(record) and response["worker_id"] == saved["peer_worker_id"] and
             response["turn_id"] not in [saved["turn_id"], saved["peer_source_turn_id"]],
           do: raise(ArgumentError, "Conflicting peer response ownership")

    response_turn = response["turn_id"]

    case saved["response_turn_id"] do
      nil ->
        storage(fn ->
          {saved, events} = publish(dir, events, saved)

          saved =
            Map.merge(saved, %{
              "response_turn_id" => response["turn_id"],
              "bound_at" => timestamp(),
              "revision" => 2
            })

          saved = Map.put(saved, "transitions", [transition(saved, 2)])
          persist(dir, saved)
          publish(dir, events, saved)
        end)

      ^response_turn ->
        storage(fn -> publish(dir, events, saved) end)

      _ ->
        raise ArgumentError, "Conflicting peer reply already bound"
    end
  end

  def public(record), do: Map.drop(record, ["version", "published_revision", "transitions"])

  def routed(record),
    do:
      Map.merge(public(record), %{"response_turn_id" => nil, "bound_at" => nil, "revision" => 1})

  def recover(dir, events) do
    storage(fn ->
      check_type(dir, :directory)
      turns = Path.join(dir, "turns")
      check_type(turns, :directory)

      entries(turns)
      |> Enum.filter(&text_match?(&1, @turn))
      |> Enum.sort()
      |> Enum.reduce(events, fn turn, events ->
        check_directories(dir, turn)

        entries(Path.join([dir, "turns", turn, "peer-questions"]))
        |> Enum.sort()
        |> Enum.reject(&String.ends_with?(&1, ".tmp"))
        |> Enum.reduce(events, fn name, events ->
          unless text_match?(name, ~r/\Aquestion-[0-9a-f]{1,64}\.json\z/),
            do: raise("Invalid peer question record filename")

          case load(dir, turn, String.replace_suffix(name, ".json", "")) do
            nil -> raise("Peer question record disappeared")
            record -> elem(publish(dir, events, record), 1)
          end
        end)
      end)
    end)
  end

  defp publish(dir, events, record) do
    # Retained evidence must agree even after its outbox entry was checkpointed.
    Enum.each(events["events"], fn event ->
      if event["kind"] in @kinds and event["turn_id"] == record["turn_id"] and
           event["question_id"] == record["question_id"] do
        unless event["revision"] <= record["revision"] and
                 Map.delete(event, "sequence") == transition(record, event["revision"]),
               do: raise("Conflicting retained peer question event")
      end
    end)

    Enum.reduce(record["transitions"], {record, events}, fn event, {record, events} ->
      events = ExecutionEvents.append_peer_question(dir, events, event)

      record =
        Map.merge(record, %{
          "published_revision" => event["revision"],
          "transitions" =>
            Enum.reject(record["transitions"], &(&1["revision"] <= event["revision"]))
        })

      persist(dir, record)
      {record, events}
    end)
  end

  defp transition(record, revision) do
    Map.merge(Map.take(record, @identity), %{
      "kind" => if(revision == 1, do: "peer_question_routed", else: "peer_reply_bound"),
      "response_turn_id" => if(revision == 1, do: nil, else: record["response_turn_id"]),
      "revision" => revision,
      "timestamp" => if(revision == 1, do: record["created_at"], else: record["bound_at"])
    })
  end

  defp persist(dir, record) do
    validate!(record)
    encoded = JSON.encode!(record)
    if byte_size(encoded) > @max_bytes, do: raise("Oversized peer question record")
    check_directories(dir, record["turn_id"])
    path = Path.join(dir, record["record_ref"])
    check_type(path, :regular)
    check_type(path <> ".tmp", :regular)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path <> ".tmp", encoded)
    File.rename!(path <> ".tmp", path)
  end

  defp validate!(record) do
    valid =
      is_map(record) and Enum.sort(Map.keys(record)) == @fields and record["version"] == 1 and
        text_match?(record["worker_id"], @worker) and
        text_match?(record["peer_worker_id"], @worker) and
        record["worker_id"] != record["peer_worker_id"] and text_match?(record["turn_id"], @turn) and
        text_match?(record["peer_source_turn_id"], @turn) and
        record["turn_id"] != record["peer_source_turn_id"] and
        text_match?(record["question_id"], @question) and
        record["record_ref"] == reference(record["turn_id"], record["question_id"]) and
        record["question_ref"] == question_reference(record["turn_id"], record["question_id"]) and
        record["provenance"] == "coordinator_routed_declaration" and
        timestamp?(record["created_at"]) and
        is_integer(record["revision"]) and record["revision"] in [1, 2] and
        is_integer(record["published_revision"]) and
        record["published_revision"] in 0..record["revision"] and is_list(record["transitions"]) and
        length(record["transitions"]) == record["revision"] - record["published_revision"]

    unless valid, do: raise("Invalid peer question record")

    case record["revision"] do
      1 ->
        unless is_nil(record["response_turn_id"]) and is_nil(record["bound_at"]),
          do: raise("Invalid unbound peer question record")

      2 ->
        unless text_match?(record["response_turn_id"], @turn) and timestamp?(record["bound_at"]) and
                 record["response_turn_id"] not in [
                   record["turn_id"],
                   record["peer_source_turn_id"]
                 ],
               do: raise("Invalid bound peer question record")
    end

    Enum.with_index(record["transitions"], record["published_revision"] + 1)
    |> Enum.each(fn {event, revision} ->
      unless event == transition(record, revision),
        do: raise("Invalid peer question transition outbox")
    end)

    record
  end

  defp validate_ids!(turn, question) do
    unless text_match?(turn, @turn) and text_match?(question, @question),
      do: raise(ArgumentError, "Invalid peer question turn or question")
  end

  defp check_directories(dir, turn) do
    check_type(dir, :directory)
    check_type(Path.join(dir, "turns"), :directory)
    check_type(Path.join([dir, "turns", turn]), :directory)
    check_type(Path.join([dir, "turns", turn, "peer-questions"]), :directory)
  end

  defp check_type(path, type) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %{type: ^type, links: links}} when type != :regular or links == 1 ->
        :ok

      {:ok, _} ->
        raise("Invalid peer question storage path")

      {:error, reason} ->
        raise File.Error, reason: reason, action: "inspect peer question path", path: path
    end
  end

  defp entries(path) do
    case File.ls(path) do
      {:ok, names} ->
        names

      {:error, :enoent} ->
        []

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read peer question records", path: path
    end
  end

  defp question_reference(turn, question),
    do: Path.join(["turns", turn, "questions", question <> ".json"])

  defp text_match?(value, regex),
    do: is_binary(value) and String.valid?(value) and Regex.match?(regex, value)

  defp timestamp, do: DateTime.to_iso8601(DateTime.utc_now())

  defp timestamp?(value),
    do:
      is_binary(value) and byte_size(value) <= 64 and
        match?({:ok, _, _}, DateTime.from_iso8601(value))

  defp storage(fun) do
    fun.()
  rescue
    error in StorageError ->
      reraise error, __STACKTRACE__

    error ->
      raise StorageError, message: "Peer question storage failed: #{Exception.message(error)}"
  end
end

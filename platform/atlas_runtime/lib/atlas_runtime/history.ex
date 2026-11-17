defmodule AtlasRuntime.History do
  @moduledoc """
  The history contract's implementation (`AtlasRuntimeBoundary.History`, served through the
  facade `AtlasRuntime.Boundary.History`; design §13 S2, §13.1 Q1, Q2): read-only summaries
  of the turns the Runtime has run.

  - **Turns** are the Service's turn history (`AtlasRuntime.Persistence.History.list/2`):
    the running Service's, so the turns it owns show their live state, and with no Service
    running the Runtime home's, where a turn left unfinished is `unknown`.
  - **Projection**: explicit fields only, as `runtime.read/1` projects a turn
    (`AtlasRuntime.Inspection.Reads`), with the worker as `slot` and the backend as
    `harness`. Nothing else of a turn record (its assignment, working directory,
    permissions, repository, artifacts, answer or Server identity) is returned.
  - **Provenance** comes from the turn's attempt in its work record
    (`work/{work_id}.json`) when there is one, and otherwise from the turn record.
  - **Visibility** (Q2): a turn of a work is seen by the work's client; a turn of no work is
    from before works existed and is seen only with `read_all`, which sees every turn.
  - **A work record that cannot be read** (damaged, or of another `format_version`) is
    skipped with a warning, so one bad file never fails every client's history (HR review
    R2). Its turns then belong to no work: `read_all` still sees them, with the turn
    record's provenance, and the work's client does not until the record reads again, so
    nothing becomes visible that was not. The work store writes a record whole (a
    temporary file renamed into place, `AtlasRuntime.Work.Store`), so a record is never
    read half-written; a skipped record is one the work core itself refuses at boot.
  - **Pages** follow (`started_at`, `turn_id`), a turn without a start first. The cursor is
    the last position served: a later page neither repeats nor skips a turn that was there
    when the earlier one was read, and the last page's cursor later yields newer turns.

  Reads change no file under the Runtime home and none of the Service's state.
  """
  use AtlasRuntime.Boundary.History.Implementation

  require Logger
  alias AtlasRuntime.Boundary.History, as: F
  alias AtlasRuntime.Inspection.Reads
  alias AtlasRuntime.Persistence.History, as: Saved
  import AtlasRuntime.Execution.Identity, only: [valid_id?: 1]

  @states ~w(running stopping killing finished failed stopped killed unknown)
  @state Map.new(@states, &{&1, String.to_atom(&1)})
  @terminal ~w(finished failed stopped killed)
  # Without a limit, a page is 100 turns (§13.1 Q1). The facade refuses a limit outside
  # 1..100 (`range:` in the contract), so one never reaches here.
  @limit 100
  @timeout 10_000

  @impl true
  def list_turns(client, %F.ListTurnsInput{} = input) do
    limit = limit!(input.limit)
    from = position!(input.cursor)

    turns =
      client
      |> visible()
      |> Enum.filter(&(is_nil(input.slot) or &1.slot == input.slot))
      |> Enum.filter(&(is_nil(input.since) or started_since?(&1, input.since)))
      |> Enum.sort_by(&key/1)
      |> Enum.filter(&(is_nil(from) or key(&1) > from))

    {page, rest} = Enum.split(turns, limit)
    last = if page == [], do: from, else: key(List.last(page))
    %F.Outcome.Turns{turns: page, cursor: cursor(last), more: rest != []}
  end

  @impl true
  def get_turn(client, %F.GetTurnInput{turn_id: id}) do
    case valid_id?(id) && Enum.find(visible(client), &(&1.turn_id == id)) do
      %F.Turn{} = turn -> %F.Outcome.Found{turn: turn}
      _ -> %F.Outcome.NotFound{}
    end
  end

  @doc """
  Where work's `turn_output` reads the output of a turn from before works existed (RQ5):
  `{:ok, buffer, execution}`, the existing buffer and identity it is retained under, for a
  client with `read_all`; `:not_found` without it, or when there is no such turn; `:work`
  when the turn belongs to a work, whose own visibility applies.
  """
  def pre_cutover_output({_id, rights}, turn_id) do
    home = home()

    with true <- valid_id?(turn_id),
         %{} = run <- Enum.find(runs(), &(&1["id"] == turn_id)) do
      cond do
        Map.has_key?(owners(home), turn_id) ->
          :work

        Enum.member?(rights, :read_all) ->
          {buffer, execution} = Reads.output_stream(run)
          {:ok, buffer, execution}

        true ->
          :not_found
      end
    else
      _ -> :not_found
    end
  end

  @doc """
  The Runtime home: `:runtime_home` of `:atlas_runtime`, which `host/service.exs` sets to
  the Service's home at boot (the host may leave `$ATLAS_RUNTIME_HOME` unset for the
  default home), otherwise `$ATLAS_RUNTIME_HOME`, which the backend listener also
  defaults to.
  """
  def home,
    do:
      Application.get_env(:atlas_runtime, :runtime_home) ||
        System.fetch_env!("ATLAS_RUNTIME_HOME")

  ## Turns and their works

  # Every turn summary the client may see.
  defp visible({id, rights}) do
    owners = owners(home())
    all? = Enum.member?(rights, :read_all)

    runs()
    |> Enum.map(&{&1, owners[&1["id"]]})
    |> Enum.filter(fn {_run, owner} -> all? or (owner != nil and owner.client == id) end)
    |> Enum.map(fn {run, owner} -> summary(run, owner) end)
  end

  # The running Service answers its own `turns` (the live state of what it owns); it changes
  # nothing for it. Without one, the saved turns under the home.
  defp runs do
    case GenServer.whereis(AtlasRuntime.Service) do
      nil ->
        Saved.list(home(), %{}).turns

      service ->
        case GenServer.call(service, %{"command" => "turns"}, @timeout) do
          {%{turns: turns}, _shutdown?} -> turns
          {%{command_error: why}, _shutdown?} -> raise "Cannot read turn history: #{why}"
        end
    end
  end

  # turn_id => the client of the work whose attempt ran it, and that attempt's provenance.
  defp owners(home) do
    Path.join([home, "work", "*.json"])
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) == "index.json"))
    |> Enum.sort()
    |> Enum.reduce(%{}, fn path, owners ->
      case work(path) do
        nil ->
          owners

        record ->
          for %{"turn_id" => turn} = attempt <- record["attempts"],
              is_binary(turn),
              into: owners,
              do:
                {turn, %{client: record["client"], provenance: provenance(attempt["provenance"])}}
      end
    end)
  end

  # Only what a summary needs of a work record (AtlasRuntimeModel.Work, format version 1),
  # or nil for one that cannot be read: it is skipped (see the moduledoc).
  defp work(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, %{"format_version" => 1, "client" => client, "attempts" => attempts} = record}
         when is_binary(client) and is_list(attempts) <- JSON.decode(bytes),
         true <- Enum.all?(attempts, &is_map/1) do
      record
    else
      _ ->
        Logger.warning(
          "runtime history: work record #{Path.basename(path)} cannot be read; " <>
            "its turns are listed as of no work"
        )

        nil
    end
  end

  defp provenance(%{} = provenance), do: provenance
  defp provenance(_), do: %{}

  ## Projection

  defp summary(run, owner) do
    provenance = if owner, do: owner.provenance, else: %{}
    # A state the turn history never writes is not claimed as one it does.
    state = if run["state"] in @states, do: run["state"], else: "unknown"

    %F.Turn{
      turn_id: run["id"],
      slot: text(run["worker_id"]),
      state: @state[state],
      native_outcome: if(state in @terminal, do: @state[state]),
      started_at: time(run["started_at"]),
      ended_at: time(run["ended_at"]),
      harness: known(provenance["harness"], run["backend"]),
      configured_model: known(provenance["configured_model"], run["requested_model"]),
      reported_model: known(provenance["reported_model"], run["model"]),
      conversation_id: known(provenance["conversation_id"], run["session_id"])
    }
  end

  defp known(from_work, from_turn), do: text(from_work) || text(from_turn)

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(_), do: nil

  defp time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  defp time(_), do: nil

  defp started_since?(%F.Turn{started_at: nil}, _since), do: false

  defp started_since?(%F.Turn{started_at: at}, since),
    do: DateTime.compare(at, since) != :lt

  ## Pages

  defp limit!(nil), do: @limit
  defp limit!(limit), do: limit

  # A turn's position: its start in microseconds (-1 without one), then its id.
  defp key(%F.Turn{started_at: nil, turn_id: id}), do: [-1, id]
  defp key(%F.Turn{started_at: at, turn_id: id}), do: [DateTime.to_unix(at, :microsecond), id]

  defp cursor(position), do: Base.url_encode64(JSON.encode!(position), padding: false)

  defp position!(nil), do: nil

  defp position!(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, position} <- JSON.decode(json),
         true <-
           position == nil or match?([at, id] when is_integer(at) and is_binary(id), position) do
      position
    else
      _ -> raise ArgumentError, "list_turns cursor is not one this Runtime gave"
    end
  end
end

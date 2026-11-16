defmodule AtlasRuntime.Integrations.AtlasServer.Lifecycle do
  @moduledoc """
  Optional lifecycle mirror of the standalone Runtime service, opted into with `server.json`
  in the Runtime home before the service starts. For each turn of a listed worker it creates
  the Server turn `TU-<machine>-<local turn ID>` on the configured machine, registers that
  exact attempt's execution, renews its activity and lease as `AtlasRuntime.Turn` does, and
  ends it with why: `finished`, `failed: …` or `stopped`. When the model names them, the turn
  also says what it is about (`title`: the assignment's first heading and line) and which
  model runs it (`model`: the requested one at once, the one the harness reports when it
  does; the execution record is immutable and written before that). It sets no item, no Flow outcome,
  and gives Server no start, stop or guidance over the native agent. Local turn IDs never
  change; the Server identity is persisted with the turn before any remote write. Such a
  turn's public output is retained by the Service in `AtlasRuntime.Output` under that exact
  identity, and read through `AtlasRuntime.OutputEndpoint` as the configured machine; this
  reporter carries none of it.

  It is a best-effort mirror. Each write is one bounded `Talk` exchange from this process,
  in order; the native lifecycle never waits for it. What Server confirmed, and the last
  failure, go back to the Service as the turn's `server.report`. There is no retry queue,
  replay or crash reconciliation: an unconfirmed write stays unconfirmed, and a turn left
  running by a daemon that died keeps a lease that runs out.

  `server.json` is `{"environment", "machine", "host", "port", "token_file", "workers"}`:
  `machine` is this service's own dedicated machine name, never one a connected Engine uses;
  `workers` lists the local worker IDs that are reported (each must be a Server agent), and
  other workers run as before without any Facts write. `token_file` names a regular file in
  the Runtime home, owned by the home's owner and readable by nobody else. The token goes
  only to the Bus link: never to native agents, status, history or this module's messages.
  """
  use GenServer

  alias AtlasRuntime.Settings
  alias AtlasRuntime.Talk
  import AtlasRuntime.Execution.Identity
  import Bitwise

  @keys ~w(environment host machine port token_file workers)
  @machine ~r/\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}\z/
  @names ~w(kind by state running ended machine lease activity why ended_at attempt)

  @doc "The configuration in `dir`'s `server.json`, or nil when there is none; invalid raises."
  def load!(dir) do
    path = Path.join(dir, "server.json")

    config =
      case File.read(path) do
        {:ok, bytes} ->
          case JSON.decode(bytes) do
            {:ok, %{} = config} -> config
            _ -> invalid!("#{path} must be a JSON object")
          end

        {:error, :enoent} ->
          nil

        {:error, reason} ->
          invalid!("cannot read #{path}: #{:file.format_error(reason)}")
      end

    if config do
      if Enum.sort(Map.keys(config)) != @keys,
        do: invalid!("#{path} must have exactly #{Enum.join(@keys, ", ")}")

      %{"environment" => env, "machine" => machine, "host" => host, "port" => port} = config
      workers = config["workers"]
      if env not in ["test", "prod"], do: invalid!("environment must be test or prod")

      if not (is_binary(machine) and Regex.match?(@machine, machine)),
        do: invalid!("machine must be an explicit name of letters, digits, _, . or -")

      if not (is_binary(host) and host != "" and String.trim(host) == host),
        do: invalid!("host must be a host name or address")

      if not (is_integer(port) and port in 1..65_535), do: invalid!("port must be 1..65535")

      if not (is_list(workers) and workers != [] and Enum.all?(workers, &valid_worker_id?/1) and
                Enum.uniq(workers) == workers),
         do: invalid!("workers must be a nonempty list of distinct worker IDs")

      %{
        environment: env,
        machine: machine,
        host: host,
        port: port,
        workers: workers,
        token: token!(dir, config["token_file"])
      }
    end
  end

  # Inside the home, no symbolic link on the way, a regular file only its owner can read.
  defp token!(dir, file) do
    home = Path.expand(dir)

    if not is_binary(file) or file == "",
      do: invalid!("token_file must name a file in the Runtime home")

    path = Path.expand(file, home)
    relative = Path.relative_to(path, home)

    if relative == path or relative == "." or String.starts_with?(relative, "../"),
      do: invalid!("token_file must lie inside the Runtime home")

    owner =
      case File.stat(home) do
        {:ok, %File.Stat{uid: uid}} ->
          uid

        {:error, reason} ->
          invalid!("cannot read the Runtime home: #{:file.format_error(reason)}")
      end

    steps = Enum.scan(Path.split(relative), home, &Path.join(&2, &1))

    for {step, last?} <- Enum.zip(steps, Enum.map(steps, &(&1 == path))) do
      case File.lstat(step) do
        {:ok, %File.Stat{type: :directory}} when not last? ->
          :ok

        {:ok, %File.Stat{type: :regular} = stat} when last? ->
          owner_only!(stat, owner)

        {:ok, _} ->
          invalid!("token_file must be a regular file, with no symbolic link on its path")

        {:error, reason} ->
          invalid!("cannot read token_file: #{:file.format_error(reason)}")
      end
    end

    token =
      case File.read(path) do
        {:ok, bytes} -> String.trim(bytes)
        {:error, reason} -> invalid!("cannot read token_file: #{:file.format_error(reason)}")
      end

    if token == "", do: invalid!("token_file is empty")
    token
  end

  defp owner_only!(%File.Stat{uid: uid, mode: mode, size: size}, owner) do
    if uid != owner, do: invalid!("token_file must belong to the Runtime home's owner")
    if (mode &&& 0o077) != 0, do: invalid!("token_file must be readable by its owner only")
    if size > 4_096, do: invalid!("token_file is larger than a token")
  end

  defp invalid!(why), do: raise("Atlas Server lifecycle configuration invalid: #{why}")

  @doc "The Bus link settings: the one place the token goes."
  def link(config) do
    %{
      "mode" => "client",
      "host" => config.host,
      "port" => config.port,
      "machine" => config.machine,
      "token" => config.token
    }
  end

  @doc """
  The Server identity of local turn `key` of `worker`, with a fresh attempt, or nil when the
  service does not report or the worker is not listed.
  """
  def identity(nil, _worker, _key), do: nil

  def identity(config, worker, key) do
    if worker in config.workers do
      %{
        "environment" => config.environment,
        "machine" => config.machine,
        "worker" => worker,
        "turn" => "TU-#{config.machine}-#{key}",
        "attempt" => AtlasBus.Envelope.new_id(),
        "report" => %{"turn" => "unconfirmed", "execution" => "unconfirmed", "error" => nil}
      }
    end
  end

  @doc "The reporter, unlinked: its failures never reach the native lifecycle."
  def start(config, opts \\ []), do: GenServer.start(__MODULE__, {config, self(), opts})

  def started(reporter, run), do: GenServer.cast(reporter, {:started, run})
  def activity(reporter, run, text), do: GenServer.cast(reporter, {:activity, run, text})
  def model(reporter, run, model), do: GenServer.cast(reporter, {:model, run, model})
  def ended(reporter, run), do: GenServer.cast(reporter, {:ended, run})

  @doc "Wait at most `timeout` for the reports already asked for."
  def flush(reporter, timeout) do
    GenServer.call(reporter, :flush, timeout)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init({config, owner, opts}) do
    settings = Settings.get()
    # The turn's kind and fields and the execution records are the model's; without a
    # model, or with a module that is no model, the reporter does not start.
    model =
      AtlasRuntime.Model.check!(Keyword.get_lazy(opts, :model, &AtlasRuntime.Model.configured!/0))

    attached =
      case AtlasBus.attach("runtime@" <> config.machine) do
        :ok ->
          :ok

        {:error, why} ->
          {:error, "Bus endpoint runtime@#{config.machine} not attached: #{inspect(why)}"}
      end

    {:ok,
     %{
       config: Map.delete(config, :token),
       owner: owner,
       attached: attached,
       talk: Keyword.get(opts, :talk, []),
       lease: Keyword.get(opts, :lease, settings[:lease]),
       silence: Keyword.get(opts, :silence, settings[:silence]),
       names: model.turn(),
       execution: get_in(model.guidance() || %{}, ["execution", "kind"]),
       turns: %{}
     }}
  end

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_cast({:started, %{id: key, server: server} = run}, state) do
    turn = %{
      server: server,
      report: server["report"],
      written: now(),
      activity: nil,
      timer: nil,
      model: run[:model] || run[:requested_model]
    }

    {turn, state} =
      case create(state, run, server) do
        {:ok, state} ->
          turn = put_in(turn.report["turn"], "running")

          case register(state, run, server) do
            :ok -> {put_in(turn.report["execution"], "registered"), state}
            {:error, why} -> {failed(turn, "execution not registered: #{why}"), state}
          end

        {:error, why, state} ->
          {failed(turn, "turn not created: #{why}"), state}
      end

    # Only a created turn is followed; any other turn is never written again.
    state = if turn.report["turn"] == "running", do: put_in(state.turns[key], turn), else: state
    send_report(state, key, turn)
    {:noreply, state}
  end

  def handle_cast({:started, _run}, state), do: {:noreply, state}

  # Coalesced: at most one activity write per lease interval, as a turn renews its lease.
  def handle_cast({:activity, %{id: key}, text}, state) do
    case state.turns[key] do
      nil ->
        {:noreply, state}

      turn ->
        turn = %{turn | activity: String.slice(to_string(text), 0, 500)}
        wait = turn.written + state.lease - now()

        cond do
          turn.timer ->
            {:noreply, put_in(state.turns[key], turn)}

          wait <= 0 ->
            {:noreply, write_activity(state, key, turn)}

          true ->
            {:noreply,
             put_in(state.turns[key], %{
               turn
               | timer: Process.send_after(self(), {:activity, key}, wait)
             })}
        end
    end
  end

  # The model the harness reports, written once it differs from what the turn says.
  def handle_cast({:model, %{id: key}, model}, state) do
    n = state.names

    case state.turns[key] do
      %{model: known} = turn when is_binary(model) and model != "" and model != known ->
        if is_binary(n["model"]) do
          next =
            case change(state, turn.server, %{n["model"] => model}, "model: #{model}") do
              :ok -> %{turn | model: model}
              {:error, why} -> failed(turn, "model not stored: #{why}")
            end

          if next.report != turn.report, do: send_report(state, key, next)
          {:noreply, put_in(state.turns[key], next)}
        else
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_cast({:ended, %{id: key} = run}, state) do
    case Map.pop(state.turns, key) do
      {nil, _turns} ->
        {:noreply, state}

      {turn, turns} ->
        if turn.timer, do: Process.cancel_timer(turn.timer)
        state = %{state | turns: turns}
        n = state.names
        why = why(run)

        values = %{
          n["state"] => n["ended"],
          n["why"] => why,
          n["lease"] => "",
          n["ended_at"] => at(now())
        }

        ended =
          case change(state, turn.server, values, why) do
            :ok -> put_in(turn.report["turn"], "ended")
            {:error, failure} -> failed(turn, "end not stored: #{failure}")
          end

        if ended.report != turn.report, do: send_report(state, key, ended)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:activity, key}, state) do
    case state.turns[key] do
      %{timer: timer} = turn when timer != nil ->
        {:noreply, write_activity(state, key, %{turn | timer: nil})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp create(state, run, server) do
    with {:ok, state} <- names(state) do
      n = state.names

      cause =
        "standalone Runtime on #{server["machine"]}: worker #{server["worker"]} started local turn #{run.id}"

      content = %{
        "op" => "create",
        "key" => server["turn"],
        "values" =>
          %{
            n["state"] => n["running"],
            n["machine"] => server["machine"],
            n["lease"] => at(now() + state.silence),
            n["activity"] => "started",
            n["attempt"] => server["attempt"]
          }
          |> about(n, run),
        "links" => %{n["by"] => [server["worker"]]},
        "version" => nil,
        "by" => "runtime",
        "cause" => cause
      }

      case fact(state, n["kind"], content) do
        :ok ->
          {:ok, state}

        # An unanswered create may still be stored: only this exact attempt confirms it.
        {:error, why} ->
          values =
            case read(state, n["kind"], %{"key" => server["turn"], "plain" => true}) do
              %{"fact" => %{"values" => %{} = values}} -> values
              _ -> %{}
            end

          if values[n["attempt"]] == server["attempt"] and
               values[n["machine"]] == server["machine"],
             do: {:ok, state},
             else: {:error, why, state}
      end
    else
      {:error, why} -> {:error, why, state}
    end
  end

  # As `AtlasRuntime.Guidance.register/1`, with nothing invented: no queued input, and an
  # unknown harness version; the model is the requested one, or unknown.
  defp register(state, run, server) do
    values = %{
      "worker" => server["worker"],
      "turn" => server["turn"],
      "attempt" => server["attempt"],
      "machine" => server["machine"],
      "harness" => run.backend,
      "harness_version" => "unknown",
      "configured_model" => run[:requested_model] || "unknown",
      "capability_version" => "1",
      "queued_input" => false,
      "durable_accept_query" => false,
      "consumption_evidence" => false
    }

    stored =
      case Talk.fact(
             state.execution,
             %{"op" => "register_execution", "values" => values},
             state.talk
           ) do
        {:stored, %{"fact" => execution}, _position} ->
          execution

        {:refused, refusal} ->
          {:error, refusal_text(refusal)}

        _unanswered ->
          case read(state, state.execution, Map.take(values, ~w(turn attempt))) do
            %{"fact" => %{} = execution} -> execution
            _ -> {:error, "Facts did not answer"}
          end
      end

    case stored do
      {:error, _} = error ->
        error

      execution ->
        if is_map(execution) and Map.take(execution, Map.keys(values)) == values and
             execution["environment"] == server["environment"],
           do: :ok,
           else: {:error, "the stored execution is not this exact attempt"}
    end
  catch
    class, why -> {:error, Exception.format_banner(class, why)}
  end

  defp write_activity(state, key, turn) do
    n = state.names
    text = turn.activity || "activity"
    values = %{n["lease"] => at(now() + state.silence), n["activity"] => text}

    next =
      case change(state, turn.server, values, "activity: #{text}") do
        :ok -> %{turn | written: now()}
        # Not stored: its lease runs out by itself if this goes on.
        {:error, why} -> failed(turn, "activity not stored: #{why}")
      end

    if next.report != turn.report, do: send_report(state, key, next)
    put_in(state.turns[key], next)
  end

  defp change(state, server, values, cause) do
    fact(state, state.names["kind"], %{
      "op" => "change",
      "key" => server["turn"],
      "values" => values,
      "version" => nil,
      "by" => "runtime",
      "cause" => cause
    })
  end

  defp fact(%{attached: {:error, why}}, _kind, _content), do: {:error, why}

  defp fact(state, kind, content) do
    case Talk.fact(kind, content, state.talk) do
      {:stored, _answer, _position} -> :ok
      {:refused, refusal} -> {:error, refusal_text(refusal)}
      {:error, :no_answer} -> {:error, "Facts did not answer"}
      other -> {:error, inspect(other)}
    end
  catch
    class, why -> {:error, Exception.format_banner(class, why)}
  end

  defp read(%{attached: {:error, _}}, _kind, _query), do: nil

  defp read(state, kind, query) do
    Talk.read(kind, query, state.talk)
  catch
    _, _ -> nil
  end

  # The model's names for the turn and its execution, as the engine uses them.
  defp names(%{attached: {:error, why}}), do: {:error, why}

  defp names(%{names: names, execution: execution} = state) do
    if is_map(names) and Enum.all?(@names, &is_binary(names[&1])) and is_binary(execution),
      do: {:ok, state},
      else: {:error, "the model has no runtime turn and execution mapping"}
  end

  # What the turn is about and the model asked for, under the model's names when it has them.
  defp about(values, n, run) do
    [{n["title"], title(run[:assignment])}, {n["model"], run[:model] || run[:requested_model]}]
    |> Enum.reduce(values, fn
      {name, value}, values when is_binary(name) and is_binary(value) and value != "" ->
        Map.put(values, name, value)

      _, values ->
        values
    end)
  end

  @title 120

  @doc """
  A turn's title from its assignment: its first non-empty line, without heading marks; when
  that is a heading and the next non-empty line is not, the two joined by `: `. Shortened to
  #{@title} characters, on one line; nil for an empty assignment.
  """
  def title(assignment) when is_binary(assignment) do
    lines =
      assignment
      |> String.split(["\r\n", "\n"])
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    text =
      case lines do
        ["#" <> _ = heading, next | _] ->
          if String.starts_with?(next, "#"),
            do: plain(heading),
            else: plain(heading) <> ": " <> next

        [first | _] ->
          plain(first)

        [] ->
          ""
      end

    text = text |> String.replace(~r/\s+/u, " ") |> String.trim()

    cond do
      text == "" -> nil
      String.length(text) <= @title -> text
      true -> String.slice(text, 0, @title - 1) <> "…"
    end
  end

  def title(_), do: nil

  defp plain(line), do: line |> String.trim_leading("#") |> String.trim()

  defp refusal_text(refusal) do
    refusal = if is_map(refusal), do: refusal, else: %{}
    "refused: " <> Enum.join(List.wrap(refusal["reasons"] || refusal["code"] || "unknown"), "; ")
  end

  defp why(%{state: "finished"}), do: "finished"
  defp why(%{state: "stopped"}), do: "stopped"
  defp why(%{state: "killed"}), do: "killed"
  defp why(run), do: String.slice("failed: #{run[:error] || "unknown"}", 0, 500)

  defp failed(turn, why), do: put_in(turn.report["error"], why)

  defp send_report(state, key, turn),
    do: send(state.owner, {:server_report, key, turn.server["attempt"], turn.report})

  defp now, do: System.system_time(:millisecond)

  defp at(ms),
    do:
      ms
      |> DateTime.from_unix!(:millisecond)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()
end

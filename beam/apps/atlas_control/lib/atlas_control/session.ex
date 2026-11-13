defmodule AtlasControl.Session do
  @moduledoc """
  One connected client. Speaks Control's protocol (`bff/README.md`) as JSON
  lines over TCP, and reaches Facts only over the Bus, as its own endpoint.

  - Opening a path reads what the page needs from Facts and sends the page.
  - A submit becomes a fact. The client is told it waits; the change shows only once
    Facts has stored it, and Flow has done what the write made it do (read-your-writes,
    docs/design/page-freshness.md §2.2): the page goes out once Flow says it has settled
    past the write (`_settled`), or once `settle_ms` (1 s) ran out, which is logged. A
    fact without an answer is sent again with the same id, after 5 seconds, then twice
    as long each time, up to a minute.
  - Every page is read in one `_page` read, and the session keeps what it depended on
    (`AtlasControl.Freshness`): for the path on screen and the paths viewed before it.
    Hints (`stored`, by anyone) are collected for a moment and handled at once: a page
    is read again only when what the hints say changed is something it depended on. The
    page on screen is sent again; up to 3 other recent pages are pushed, the most
    recently viewed first. A form is never redrawn under the user's hands; they get a
    notice instead. Before handling hints of others' writes the session waits, briefly
    (`hint_settle_ms`), for Flow to have settled past them.
  - Once a write of this client is stored, the facts it changed are marked
    (`AtlasControl.Freshness.Marks`) until Flow says it has settled past it: every page
    sent meanwhile flags their rows `pending`, and a recent page that shows one is sent
    again as it was, flagged (`reason: "pending"`, no read). A mark never says how the
    write turns out. Once Flow has settled past it, the mark goes, and a recent page that
    still shows it flagged is sent again without. While marks are held, each flush and
    each refresh asks Flow again how far it has settled.
  - The client asks for a refresh on an interval (it reconciles); a lost hint only delays.
    A reconcile asks Facts only how far it is (`_position`): the page on screen is read
    again when Facts is past every position the session has seen (a hint it got, a page
    it read), or once a value on it changes by time alone (`until`). The model is
    compiled in, so a reconcile never works it out again.
  - Each fact says who sent it (`by`): the user at a TUI (`tui_user` in the environment's
    settings; one for now), `migration` for a migration (which may set what the
    model marks `set_by: migration`), or `agent` for any other client, as its hello
    says.
  - Every page is worked out from the model Control is wired to (`AtlasControl.Model`,
    as the Gateway hands it over); only facts are read from Facts.
    A submit may carry a `cause`; it goes with the fact, as does a links form's note.
  """
  use GenServer, restart: :temporary

  require Logger

  alias AtlasBus.Envelope
  alias AtlasControl.{Faults, PageReads, Pages}
  alias AtlasControl.Freshness.{Affected, Batch, Marks, ReadSet, Recent, RowKey}

  @read_attempts 3
  @first_resend 5_000
  @last_resend 60_000
  # How often a create tries the next number when its key turns out to be taken.
  @key_tries 10
  # What Facts answers with how far it is: its position alone.
  @position "_position"
  # Who answers how far Flow has settled (`_settled`), and whose hints are Flow's.
  @flow "flow"
  # How many recent pages, besides the one on screen, one batch of hints pushes.
  @pushes 3

  def start_link({socket, model}), do: GenServer.start_link(__MODULE__, {socket, model})

  @impl true
  def init({socket, model}) do
    endpoint = "control/session-#{System.unique_integer([:positive])}"
    :ok = AtlasBus.attach(endpoint)

    {:ok,
     %{
       socket: socket,
       endpoint: endpoint,
       hello: false,
       surface: nil,
       # The model as Control serves it (`AtlasControl.Model.catalog/2`).
       model: model,
       listening: MapSet.new(),
       route: :home,
       form: %{},
       pending: %{},
       output: nil,
       output_connection: false,
       output_idle: nil,
       by: "agent",
       by_kind: nil,
       # What is assigned to the client, for the header of every page (`start.assigned`):
       # its words and what they were read from (`set`; nil: to be read again with the
       # next page, the words meanwhile those read last).
       count: %{text: nil, set: nil},
       cause: nil,
       # The pages sent lately, by path, with what each depended on.
       recent: Recent.new(),
       # The hints not handled yet, and the wait that handles them.
       batch: Batch.new(),
       flush_timer: nil,
       # A wait for Flow to settle (`%{id, ref, timer, position, budget, stored}`): after
       # a stored write of this client (`stored`: the page to show then), or before
       # handling hints of others' writes. The highest settled position Flow reported.
       settling: nil,
       settled: nil,
       # The highest position the session has seen: of a hint it got, or a page it read.
       seen: 0,
       # The facts this client's stored writes changed that Flow has not settled yet:
       # `key => position` (`AtlasControl.Freshness.Marks`).
       marks: Marks.new()
     }}
  end

  @impl true
  def handle_info(:go, state) do
    :ok = :inet.setopts(state.socket, active: :once)
    {:noreply, state}
  end

  def handle_info({:tcp, _socket, line}, state) do
    result =
      case JSON.decode(line) do
        {:ok, %{"op" => op} = message} ->
          handle_op(op, message, state)

        _ ->
          {:noreply,
           notice(state, "error", "Control could not read: #{String.slice(line, 0, 80)}")}
      end

    case result do
      {:noreply, next} ->
        case :inet.setopts(next.socket, active: :once) do
          :ok -> {:noreply, next}
          {:error, _} -> {:stop, :normal, next}
        end

      stopped ->
        stopped
    end
  end

  def handle_info(:presentation_failed, state), do: {:stop, :normal, state}

  def handle_info({:tcp_closed, _}, state), do: {:stop, :normal, state}
  def handle_info({:tcp_error, _, _}, state), do: {:stop, :normal, state}

  def handle_info({:output_idle, marker}, %{output_idle: {_, marker}} = state),
    do: {:stop, :normal, state}

  def handle_info({:output_idle, _}, state), do: {:noreply, state}

  def handle_info(
        {:atlas_bus, %Envelope{class: "stored"}, _},
        %{output_connection: true} = state
      ),
      do: {:noreply, state}

  def handle_info({:atlas_bus, %Envelope{class: class, id: id} = envelope, content}, state)
      when is_map_key(state.pending, id) and class in ["stored", "refused"] do
    {pending, rest} = Map.pop(state.pending, id)
    Process.cancel_timer(pending.timer)
    state = %{state | pending: rest}

    # A key this client made up was taken by someone else: try the next one.
    retry? =
      content["code"] in ["exists", "reserved"] and pending.retry != nil and
        pending.retry.tries < @key_tries

    case class do
      "stored" ->
        state = %{state | form: %{}}
        changes = content["changes"] || []

        text =
          case pending do
            %{content: %{"op" => "create", "key" => key}, retry: %{skipped: [_ | _] = skipped}} ->
              "Stored as #{key} (position #{envelope.position}); " <>
                "#{Enum.join(skipped, ", ")} #{if length(skipped) == 1, do: "was", else: "were"} taken."

            %{content: %{"op" => "create", "key" => key}} ->
              "Stored as #{key} (position #{envelope.position})."

            _ ->
              "Stored by Facts (position #{envelope.position})."
          end

        # Its own write is a hint too: the recent pages it changed are pushed once settled.
        hint = %{position: envelope.position, changes: changes, by: state.by}
        state = seen(%{state | batch: Batch.add(state.batch, hint, now_ms())}, envelope.position)
        # What it changed is being processed until Flow settles past it: the recent pages
        # that show it say so now, as they were sent.
        state = sync_marks(%{state | marks: Marks.mark(state.marks, envelope.position, changes)})
        keys = changes |> Enum.map(& &1["key"]) |> Enum.uniq() |> length()
        stored = %{after: pending.after, text: text, opened: false, keys: keys}
        {:noreply, settle(state, envelope.position, settle_ms(), stored)}

      "refused" when retry? ->
        {:noreply, retry_create(state, pending)}

      "refused" ->
        reasons = content["reasons"] || ["refused"]

        if Pages.form?(state.route) do
          form = Map.put(state.form, :errors, reasons)
          state = notice(state, "error", "Facts refused it; the form says why.")
          {:noreply, show(%{state | form: form}, state.route, "refused", nil)}
        else
          # No form to say why: the page says it (`refused`), for a client without a screen.
          state = notice(state, "error", "Facts refused: " <> Enum.join(reasons, "; "))
          {:noreply, show(state, state.route, "refused", nil, reasons)}
        end
    end
  end

  # A hint: facts were stored, by anyone. Collected, and handled with the hints that come
  # with it (`:flush`).
  def handle_info({:atlas_bus, %Envelope{class: "stored"} = envelope, content}, state) do
    hint = %{position: envelope.position, changes: content["changes"] || [], by: content["by"]}
    now = now_ms()
    batch = Batch.add(state.batch, hint, now)
    state = cancel_flush(seen(%{state | batch: batch}, envelope.position))
    wait = max(Batch.due(batch, batch_timing()) - now, 0)
    {:noreply, %{state | flush_timer: AtlasControl.Clock.after_ms(:flush, wait)}}
  end

  # How far Flow has settled. The wait it answers ends once Flow is past its position.
  def handle_info(
        {:atlas_bus, %Envelope{class: "answer", kind: "_settled", id: id}, content},
        state
      ) do
    settled = content["settled"]

    state =
      if is_integer(settled),
        do: %{
          state
          | settled: max(state.settled || settled, settled),
            marks: Marks.settled(state.marks, settled)
        },
        else: state

    # Any answer that covers a mark clears it, a late one too; the pages the stored page
    # and the hints did not send again lose their flags as they were sent.
    state =
      case state.settling do
        %{id: ^id, position: position} when is_integer(settled) and settled >= position ->
          settled(state)

        _ ->
          state
      end

    {:noreply, sync_marks(state)}
  end

  def handle_info({:atlas_bus, _envelope, _content}, state), do: {:noreply, state}

  # While Flow is waited for, hints wait too: they are handled once it answers.
  def handle_info(:flush, %{settling: %{}} = state), do: {:noreply, %{state | flush_timer: nil}}

  def handle_info(:flush, state) do
    state = %{state | flush_timer: nil}

    cond do
      Batch.empty?(state.batch) ->
        {:noreply, state}

      Batch.others?(state.batch.hints, @flow) and is_integer(Batch.position(state.batch.hints)) ->
        position = max(Batch.position(state.batch.hints), Marks.lowest(state.marks) || 0)
        {:noreply, settle(state, position, hint_settle_ms(), nil)}

      # While marks are held, Flow is asked again whether it settled past them.
      Marks.held?(state.marks) ->
        {:noreply, settle(state, Marks.lowest(state.marks), hint_settle_ms(), nil)}

      true ->
        {:noreply, flush(state)}
    end
  end

  # Flow did not say it settled in time: the page goes out as Facts has it now. Flow's
  # later writes come as hints and refresh it.
  def handle_info({:settle_timeout, ref}, %{settling: %{ref: ref} = settling} = state) do
    if settling.stored do
      Logger.warning(
        "control: settle timeout position=#{settling.position} budget_ms=#{settling.budget} " <>
          "settled=#{state.settled || "none"} marked_keys=#{settling.stored.keys}"
      )
    end

    {:noreply, settled(state)}
  end

  def handle_info({:settle_timeout, _ref}, state), do: {:noreply, state}

  def handle_info({:resend, id}, state) do
    case state.pending[id] do
      nil ->
        {:noreply, state}

      pending ->
        :ok = AtlasBus.send(pending.envelope, pending.content)
        wait = min(pending.wait * 2, @last_resend)
        timer = AtlasControl.Clock.after_ms({:resend, id}, wait)
        state = put_in(state.pending[id], %{pending | wait: wait, timer: timer})
        {:noreply, notice(state, "pending", "No answer from Facts yet; sent again.")}
    end
  end

  # Protocol

  # A client says which contract version it implements. One older than Control's cannot
  # render what Control sends now: it is told so and closed, rather than shown a page it
  # breaks on. A newer one shows what it knows, and the rest as fallbacks.
  defp handle_op(op, _message, %{output_connection: true} = state)
       when op not in ~w(worker_output_subscribe worker_output_next worker_output_unsubscribe),
       do: bye(state, "This connection is reserved for worker output.")

  defp handle_op("hello", message, state) do
    environment = AtlasBus.environment()
    version = AtlasControl.Blocks.version()

    cond do
      message["env"] != environment ->
        bye(
          state,
          "This is Control #{environment}; it does not serve #{inspect(message["env"])}."
        )

      too_old?(message["spec"], version) ->
        bye(
          state,
          "This client implements contract #{message["spec"] || "(none)"}; Control " <>
            "#{environment} speaks #{version}. It is too old: update it (atlas starts the newest build)."
        )

      message["surface"] not in [nil, "console"] ->
        bye(state, "Unsupported Control presentation surface")

      message["surface"] == "console" ->
        state =
          describe(%{
            state
            | hello: true,
              surface: "console",
              by: actor(message["client"], message["as"])
          })

        welcome = %{
          "op" => "welcome",
          "env" => environment,
          "spec" => version,
          "surface" => "console"
        }

        {:noreply, show(state, :home, "open", nil, nil, welcome)}

      true ->
        send_client(state, %{"op" => "welcome", "env" => environment, "spec" => version})

        state =
          describe(%{
            state
            | hello: true,
              surface: nil,
              by: actor(message["client"], message["as"])
          })

        {:noreply, show(state, :home, "open", nil)}
    end
  end

  defp handle_op("machine_discover", message, state) do
    reply = AtlasControl.RuntimeDiscovery.read(message, state.hello)
    send_client(state, reply)
    {:noreply, state}
  end

  defp handle_op(_op, _message, %{hello: false} = state),
    do: {:noreply, notice(state, "error", "Say hello first.")}

  defp handle_op("facts_read", message, state) do
    alias AtlasBFFContract.Wire.Control.Session.Protocol, as: Wire

    reply =
      case Wire.decode_request(message) do
        {:ok, :facts_read, request} ->
          kind =
            if request["kind"] == "_" and is_binary(request["key"]) do
              case Pages.resolve({:item, "_", request["key"]}, state.model) do
                {:item, kind, _} ->
                  kind

                _ ->
                  case kind_holding(request["key"], state) do
                    {:ok, kind} -> kind
                    _ -> nil
                  end
              end
            else
              request["kind"]
            end

          if is_binary(kind) and Pages.kind?(state.model, kind) do
            content =
              if request["key"],
                do: %{"key" => request["key"], "plain" => true},
                else: %{"plain" => true, "linked" => %{}}

            case ask(kind, content) do
              %{"error" => why} -> Wire.reply(:facts_read, :error, %{error: why})
              data -> Wire.reply(:facts_read, :result, %{data: data})
            end
          else
            Wire.reply(:facts_read, :error, %{error: "unknown kind or subject"})
          end

        _ ->
          Wire.reply(:facts_read, :error, %{error: "invalid facts read"})
      end

    send_client(state, reply)
    {:noreply, state}
  end

  defp handle_op(op, message, state)
       when op in ~w(worker_output_subscribe worker_output_next worker_output_unsubscribe) do
    alias AtlasBFFContract.Wire.Control.Workers.Protocol, as: Wire

    case Wire.decode_request(message) do
      {:ok, name, request} ->
        # Output reconciliation reads authority explicitly; Facts hints must not queue behind a slow viewer.
        Enum.each(state.listening, &Registry.unregister(AtlasBus.Listeners, &1))

        :ok =
          :inet.setopts(state.socket,
            send_timeout: 1_000,
            send_timeout_close: true,
            packet_size: 262_144
          )

        inspect = fn execution ->
          worker_call(state, "worker_inspect", %{"execution" => execution})
        end

        {reply, output} =
          case AtlasControl.Output.handle(op, request, state.output, inspect) do
            {:ok, result, output} ->
              props = result |> Map.put("id", request["id"]) |> compact_worker_reply()
              {Wire.reply(name, :result, props), output}

            {:error, reason, extra, output} ->
              props =
                Map.merge(extra, %{
                  "id" => request["id"],
                  "error" => %{
                    "code" => reason,
                    "message" => reason,
                    "retryable" => reason in ~w(output_unavailable facts_unavailable viewer_limit)
                  }
                })

              {Wire.reply(name, :error, compact_worker_reply(props)), output}
          end

        if state.output_idle, do: Process.cancel_timer(elem(state.output_idle, 0))
        marker = make_ref()

        timer =
          Process.send_after(self(), {:output_idle, marker}, AtlasControl.Output.idle_timeout())

        send_client(state, reply)

        {:noreply,
         %{
           state
           | output: output,
             output_connection: true,
             output_idle: {timer, marker},
             listening: MapSet.new()
         }}

      _ ->
        send_client(state, %{
          "op" => op <> "_error",
          "channel" => "control",
          "version" => "0.1.0",
          "id" => if(is_binary(message["id"]), do: message["id"], else: ""),
          "error" => %{
            "code" => "invalid_request",
            "message" => "Invalid output request",
            "retryable" => false
          }
        })

        {:noreply, state}
    end
  end

  defp handle_op(op, message, state)
       when op in ~w(worker_overview worker_inspect worker_submit worker_query worker_history worker_receipts) do
    alias AtlasBFFContract.Wire.Control.Workers.Protocol, as: Wire

    reply =
      case Wire.decode_request(message) do
        {:ok, name, request} ->
          case worker_call(state, op, request) do
            {:ok, result} ->
              result =
                if op == "worker_inspect" do
                  update_in(result, ["view"], fn view ->
                    Map.put(view, "output", AtlasControl.Output.capability(view["execution"]))
                  end)
                else
                  result
                end

              props = result |> Map.put("id", request["id"]) |> compact_worker_reply()

              try do
                Wire.reply(name, :result, props)
              rescue
                ArgumentError -> worker_error(name, request["id"], "invalid_facts_reply")
              end

            {:error, reason} ->
              worker_error(name, request["id"], reason)
          end

        _ ->
          %{
            "op" => op <> "_error",
            "channel" => "control",
            "version" => "0.1.0",
            "id" => if(is_binary(message["id"]), do: message["id"], else: ""),
            "error" => %{
              "code" => "invalid_request",
              "message" => "Unsupported or malformed worker request",
              "retryable" => false
            }
          }
      end

    send_client(state, reply)
    {:noreply, state}
  end

  defp handle_op("boot", message, state) do
    # A boot refresh is a read, even while editing: never redraw or reset a draft.
    # Work against a candidate only: an invalid shell or target leaves the listeners,
    # route and form intact.
    candidate = %{state | by_kind: known_kind(state, actor_kind(state))}

    case AtlasControl.Shell.boot(
           state.model,
           candidate.by_kind,
           message["to"],
           &route(&1, candidate)
         ) do
      {:ok, shell} ->
        candidate = listen(candidate)
        send_client(state, Map.put(shell, "op", "boot"))
        {:noreply, candidate}

      {:error, why} ->
        send_client(state, %{"op" => "boot", "error" => why})
        {:noreply, state}
    end
  end

  # An open while a stored write waits for Flow: the client went elsewhere, so the stored
  # page is not shown; its notice still comes.
  defp handle_op("open", %{"to" => to}, state) do
    state =
      case state.settling do
        %{stored: %{} = stored} = settling ->
          %{state | settling: %{settling | stored: %{stored | opened: true}}}

        _ ->
          state
      end

    {:noreply, show(%{state | form: %{}}, route(to, state), "open", nil)}
  end

  defp handle_op("refresh", _message, state) do
    # A page Facts did not answer for is worked out again.
    route =
      case state.route do
        {:unavailable, path, _failed} -> route(path, state)
        route -> route
      end

    state =
      if Pages.form?(route) do
        state
      else
        case reconcile(state, route) do
          :current -> state
          :timed -> show(state, route, "reconcile", nil)
          :missed -> show(missed(state), route, "reconcile", nil)
        end
      end

    {:noreply, ask_settled(state)}
  end

  defp handle_op("turn", _message, state) do
    result =
      case AtlasControl.Turns.current(state.model, state.by, &ask/2) do
        {:ok, context} -> Map.take(context, ["key", "on", "read_first"])
        {:error, why} -> %{"error" => why}
      end

    send_client(state, Map.put(result, "op", "turn"))
    {:noreply, state}
  end

  defp handle_op("turn_end", message, state) do
    case AtlasControl.Turns.outcome(state.model, state.by, message, &ask/2) do
      {:ok, kind, content} ->
        {:noreply, put_fact(state, kind, content, {:item, kind, content["key"]})}

      {:error, why} ->
        send_client(state, %{"op" => "turn", "error" => why})
        {:noreply, state}
    end
  end

  # A submit names one of the contract's submit endpoints and its params, as a form's
  # submit_to does (or its path); anything else is refused before anything is read or
  # written.
  defp handle_op("submit", message, state) do
    raw = Map.new(message["values"] || %{}, fn {k, v} -> {k, to_string(v)} end)
    cause = if is_binary(message["cause"]) and message["cause"] != "", do: message["cause"]

    case Pages.submit_call(message) do
      {:ok, endpoint, params} ->
        route = endpoint |> Pages.submit_route(params) |> Pages.resolve(state.model)
        state = submit(route, raw, %{state | cause: cause})
        {:noreply, %{state | cause: nil}}

      :error ->
        named = message["endpoint"] || message["to"]
        {:noreply, notice(state, "error", "Control takes no submit at #{inspect(named)}.")}
    end
  end

  defp handle_op(op, _message, state),
    do: {:noreply, notice(state, "error", "Unknown op #{inspect(op)}")}

  defp bye(state, text) do
    send_client(state, %{"op" => "bye", "text" => text})
    {:stop, :normal, state}
  end

  # Older than Control's contract, or no version at all. Versions are x.y.z.
  defp too_old?(spec, version) do
    case is_binary(spec) && Version.parse(spec) do
      {:ok, theirs} -> Version.compare(theirs, Version.parse!(version)) == :lt
      _ -> true
    end
  end

  # "No such page" only for a path the contract has no page for. A page of the contract
  # that cannot be worked out because Facts did not answer (on which kind holds a key) is
  # `{:unavailable, path, failed}`: it says so, and a refresh works it out again.
  defp route(to, state) do
    case Pages.route(to) do
      :unknown ->
        :unknown

      route ->
        case Pages.resolve(route, state.model) do
          :unknown -> by_key(route, to, state)
          resolved -> resolved
        end
    end
  end

  # `_` in place of a kind, for a key no id prefix claims: the kind without a prefix that
  # has it, asked of Facts (ids made from a name have no prefix).
  defp by_key({page, "_", key}, to, state) when page in [:item, :edit, :delete] do
    case kind_holding(key, state) do
      {:ok, kind} -> {page, kind, key}
      %{"error" => _} = failed -> {:unavailable, to, failed}
      nil -> :unknown
    end
  end

  defp by_key({:links, "_", key, relation}, to, state) do
    case kind_holding(key, state) do
      {:ok, kind} -> Pages.resolve({:links, kind, key, relation}, state.model)
      %{"error" => _} = failed -> {:unavailable, to, failed}
      nil -> :unknown
    end
  end

  defp by_key(_route, _to, _state), do: :unknown

  # `{:ok, kind}`; else the first failed read when one failed (it may have been that kind);
  # else nil.
  defp kind_holding(key, state) do
    Enum.reduce_while(Pages.unprefixed_kinds(state.model), nil, fn kind, failed ->
      case ask(kind, %{"key" => key}) do
        %{"fact" => %{}} -> {:halt, {:ok, kind}}
        %{"error" => _} = answer -> {:cont, failed || answer}
        _ -> {:cont, failed}
      end
    end)
  end

  # Who is on this session. A TUI is the environment's TUI user for now; anything else is
  # an agent. No sign-in yet: a client is what its hello says.
  # An agent may say which fact it is (`as`, an agent's key), so it is the owner of what
  # is assigned to it and sees what to do (IS-Atlas-54).
  defp actor("tui", _as), do: Application.get_env(:atlas_control, :tui_user) || "agent"
  defp actor("migration", _as), do: "migration"
  defp actor(_client, as) when is_binary(as) and as != "", do: as
  defp actor(_client, _as), do: "agent"

  # Writes

  defp submit({:worker_page, :worker_guidance, params} = route, raw, state) do
    request = %{"execution" => AtlasControl.WorkerPages.target(params), "guidance" => raw}

    case worker_call(state, "worker_submit", request) do
      {:ok, %{"interaction" => interaction}} ->
        state
        |> notice(
          "ok",
          "Guidance stored as #{interaction["key"]}; queued is not delivery or completion."
        )
        |> then(
          &show(
            %{&1 | form: %{}},
            {:worker_page, :worker, params},
            "stored",
            interaction["recorded_position"]
          )
        )

      {:error, reason} ->
        form = Map.merge(state.form, %{values: raw, errors: [reason]})
        show(%{state | form: form}, route, "refused", nil, [reason])
    end
  end

  defp submit({:new, kind} = route, raw, state), do: create(route, kind, raw, %{}, state)

  defp submit({:new, kind, {relation, parent}} = route, raw, state),
    do: create(route, kind, raw, %{relation => [parent]}, state)

  defp submit({:edit, kind, key} = route, raw, state) do
    # The field the id was made from is shown, never changed.
    k = Pages.kind_view(state.model, kind)
    {parents, fields} = Map.split(raw, Pages.parent_relations(state.model, kind))
    values = Pages.values_for(k, Map.drop(fields, List.wrap(k && k.id.from)))
    state = %{state | route: route, form: Map.put(state.form, :values, raw)}
    was = state.form[:parents] || %{}

    with {:ok, links} <- moves(parents, was) do
      # Only what was edited is sent, with what the form was read with for it: Facts then
      # refuses an old version only when one of these changed meanwhile, never because
      # other fields did, and a save never puts back an old value of a field left alone.
      read = state.form[:was] || %{}

      values =
        for {name, value} <- values,
            loose(value) != loose(read[name]),
            into: %{},
            do: {name, value}

      # The links the form was read with go along as well: a change that decides gets
      # its writer as the one who decides from Facts (the model's rule), in the same
      # change, and Facts compares that link with what the client read too.
      linked = state.form[:links] || %{}

      seen =
        Map.merge(
          Map.new(values, fn {name, _} -> {name, read[name]} end),
          Map.merge(
            Map.new(linked, fn {relation, keys} -> {relation, List.wrap(keys)} end),
            Map.new(links, fn {relation, _} -> {relation, List.wrap(was[relation])} end)
          )
        )

      content = %{
        "op" => "change",
        "key" => key,
        "values" => values,
        "version" => state.form[:version],
        "was" => seen
      }

      content =
        if links == %{},
          do: content,
          else: Map.merge(content, %{"links" => links, "cause" => moved(links, was)})

      put_fact(state, kind, content, {:item, kind, key})
    else
      {:error, reasons} -> not_sent(state, route, reasons)
    end
  end

  # A failure (test only): caused, said as a notice, and the page it was caused on again.
  defp submit({:fault, fault, on}, _raw, state) do
    {tone, text} =
      case Faults.run(fault, on) do
        {:ok, done} -> {"info", done}
        {:error, why} -> {"error", why}
      end

    state |> show(Faults.after_run(on), "open", nil) |> notice(tone, text)
  end

  # A kind that is never deleted: its page says why; nothing goes to Facts (which refuses
  # a delete of it too).
  defp submit({:delete, kind, key} = route, _raw, state) do
    case Pages.kind_view(state.model, kind) do
      %{delete_error: why} when is_binary(why) -> not_sent(%{state | route: route}, route, [why])
      _ -> delete(route, kind, key, state)
    end
  end

  # The links of one association: exactly the keys named, none removes them. Who may set
  # them (`only_target`, `set_by`) Facts checks, by the model's rules.
  defp submit({:links, kind, key, relation} = route, raw, state) do
    state = %{state | route: route, form: Map.put(state.form, :values, raw)}

    keys = Pages.link_keys(raw["to"])
    note = String.trim(raw["note"] || "")
    change = Pages.change_action(state.model, relation)

    state =
      case Pages.change_cause(change || %{}, keys, state.by, note) do
        nil -> state
        cause -> %{state | cause: cause}
      end

    # What the change also asks (`with`) goes in the same change as the link.
    with_fields = if change, do: change.with, else: []
    values = Pages.values_for(Pages.kind_view(state.model, kind), Map.take(raw, with_fields))
    content = %{link(key, relation, keys) | "values" => values}
    put_fact(state, kind, content, {:item, kind, key})
  end

  defp submit({:answer, kind, key, name} = route, raw, state) do
    answers = page_answers(route, state.model)
    item = Pages.answer_item(state.model, kind, answers)
    viewer = %{key: state.by, kind: state.by_kind}
    state = %{state | route: route, form: Map.put(state.form, :values, raw)}

    with {:write, answer} <- state.model.module.answer(kind, name, item, viewer),
         {:ok, content, cause} <-
           AtlasControl.Answers.change(answer, key, state.by, raw["note"], DateTime.utc_now()) do
      put_fact(%{state | cause: cause}, kind, content, {:item, kind, key})
    else
      {:refuse, why} -> not_sent(state, route, [why])
      {:error, problem} -> not_sent(state, route, [problem])
    end
  end

  # Link the fact to the client itself (Accept), when the page would let it.
  defp submit({:set, kind, key, relation} = route, _raw, state) do
    answers = page_answers(route, state.model)

    case Pages.set_problem(state.model, route, answers) do
      nil ->
        put_fact(
          %{state | route: route},
          kind,
          link(key, relation, [state.by]),
          {:item, kind, key}
        )

      problem ->
        state = notice(state, "error", problem)
        show(state, route, "refused", nil)
    end
  end

  # Remove the link (Reopen), with the note as its cause.
  defp submit({:remove, kind, key, relation} = route, raw, state) do
    state = %{state | route: route, form: Map.put(state.form, :values, raw)}
    note = String.trim(raw["note"] || "")

    cond do
      note == "" ->
        not_sent(state, route, ["a note is required: why"])

      true ->
        put_fact(%{state | cause: note}, kind, link(key, relation, []), {:item, kind, key})
    end
  end

  defp submit(_route, _raw, state), do: notice(state, "error", "Nothing to submit here.")

  defp link(key, relation, keys),
    do: %{
      "op" => "change",
      "key" => key,
      "values" => %{},
      "links" => %{relation => keys},
      "version" => nil
    }

  # The parents a change form names that differ from those the fact had: `{:ok, %{relation
  # => [key]}}`. A change moves a fact; it never leaves one without the parent it had.
  defp moves(parents, was) do
    empty = for {relation, ""} <- parents, Map.has_key?(was, relation), do: relation

    if empty == [] do
      {:ok,
       for({relation, parent} <- parents, parent != "", parent != was[relation], into: %{}) do
         {relation, [parent]}
       end}
    else
      {:error, Enum.map(empty, &"#{&1} cannot be empty; choose where it goes")}
    end
  end

  # The cause a move is stored with: "Moved from UC-Atlas-01 to UC-Atlas-30 (in_use_case),
  # by a change in Control".
  defp loose(value) when value in [nil, ""], do: nil
  defp loose(value), do: to_string(value)

  defp moved(links, was) do
    changes =
      Enum.map_join(links, "; ", fn {relation, [to]} ->
        "from #{was[relation] || "nothing"} to #{to} (#{relation})"
      end)

    "Moved #{changes}, by a change in Control"
  end

  # A new fact gets the next free key of its kind; nobody types one. When two clients make
  # the same key at once, Facts refuses the second ("exists"), and it tries the next number.
  defp create(route, kind, raw, links, state) do
    k = Pages.kind_view(state.model, kind)

    if k && k.id.from,
      do: create_made(route, kind, raw, links, state),
      else: create_numbered(route, kind, k, raw, links, state)
  end

  # An id made from a field: the same value is the same fact, so a taken key is never
  # retried with another number. When the key cannot be made, nothing goes to Facts.
  defp create_made(route, kind, raw, links, state) do
    state = %{state | route: route, form: %{values: raw}}

    case state.model.module.key(kind, raw) do
      {:ok, key} ->
        content = new_fact(state, kind, key, raw, links)
        put_fact(state, kind, content, {:item, kind, key})

      {:error, reason} ->
        not_sent(state, route, [reason])
    end
  end

  defp create_numbered(route, kind, k, raw, links, state) do
    keys =
      case ask(kind, %{}) do
        %{"facts" => facts} -> Enum.map(facts, & &1["key"])
        _ -> []
      end

    {key, number} = Pages.next_key(k, keys)
    content = new_fact(state, kind, key, raw, links)
    state = %{state | route: route, form: %{values: raw}}
    put_fact(state, kind, content, {:item, kind, key}, %{number: number, tries: 1, skipped: []})
  end

  defp delete(route, kind, key, state) do
    answer = ask(kind, %{"key" => key})

    held =
      Pages.children(state.model, kind, answer)
      |> Enum.reject(fn {_, keys} -> keys == [] end)

    case answer do
      %{"fact" => %{"version" => version}} when held == [] ->
        content = %{"op" => "delete", "key" => key, "values" => %{}, "version" => version}

        put_fact(
          %{state | route: route},
          kind,
          content,
          Pages.after_delete(state.model, kind, answer)
        )

      _ ->
        show(state, route, "open", nil)
    end
  end

  defp not_sent(state, route, reasons) do
    state = notice(state, "error", "Not sent: the form says why.")
    show(put_in(state.form[:errors], reasons), route, "refused", nil)
  end

  defp new_fact(state, kind, key, raw, links) do
    content = %{
      "op" => "create",
      "key" => key,
      "values" => Pages.create_values(state.model, kind, raw),
      "version" => nil
    }

    if links == %{}, do: content, else: Map.put(content, "links", links)
  end

  defp retry_create(state, pending) do
    kind = pending.envelope.kind
    {key, number} = Pages.next_key(Pages.kind_view(state.model, kind), [], pending.retry.number)
    content = %{pending.content | "key" => key}
    skipped = pending.retry.skipped ++ [pending.content["key"]]
    retry = %{number: number, tries: pending.retry.tries + 1, skipped: skipped}
    note = "#{pending.content["key"]} is taken; trying #{key}…"
    put_fact(state, kind, content, {:item, kind, key}, retry, note)
  end

  defp put_fact(state, kind, content, after_route, retry \\ nil, note \\ nil) do
    content = Map.put(content, "by", state.by)
    content = if state.cause, do: Map.put(content, "cause", state.cause), else: content
    envelope = Envelope.new("fact", kind)
    :ok = AtlasBus.send(envelope, content)
    timer = AtlasControl.Clock.after_ms({:resend, envelope.id}, @first_resend)

    pending = %{
      envelope: envelope,
      content: content,
      after: after_route,
      retry: retry,
      wait: @first_resend,
      timer: timer
    }

    state = put_in(state.pending[envelope.id], pending)
    notice(state, "pending", note || "Sent to Facts; waiting until it is stored…")
  end

  # Reads

  # Listen for hints of every kind of the model, and find out which kind of fact the
  # client is: once, at its hello. The model is compiled in and never changes under a
  # running session; which kind the client is, a hint about it says (`flush/1`).
  defp describe(state) do
    state = listen(state)
    %{state | by_kind: known_kind(state, actor_kind(state))}
  end

  defp listen(state) do
    kinds = Map.keys(state.model.kinds)
    Enum.each(kinds, &AtlasBus.listen/1)
    %{state | listening: MapSet.new(kinds)}
  end

  # What the client was known to be stays while Facts does not answer whether it still is
  # (Facts is busy): only a clear "no such fact" makes it nobody, so the start page does not
  # flip to the plan and back.
  defp known_kind(%{by_kind: nil}, found), do: found

  defp known_kind(state, nil) do
    case ask(state.by_kind, %{"key" => state.by}) do
      %{"fact" => nil} -> nil
      _ -> state.by_kind
    end
  end

  defp known_kind(_state, found), do: found

  # The kind of fact the client is (the user at a TUI), or nil (an agent, a migration):
  # the kind whose ids its key fits, when a fact with that key exists.
  defp actor_kind(state) do
    route = {:item, "_", state.by}

    resolved =
      case Pages.resolve(route, state.model) do
        :unknown -> by_key(route, nil, state)
        resolved -> resolved
      end

    case resolved do
      {:item, kind, key} ->
        case ask(kind, %{"key" => key}) do
          %{"fact" => %{}} -> kind
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp worker_call(state, operation, request) do
    actor = %{key: state.by, kind: actor_kind(state)}
    AtlasControl.Workers.handle(operation, request, state.model, actor, &ask/2, &worker_fact/2)
  end

  defp worker_fact(kind, content) do
    envelope = Envelope.new("fact", kind)
    :ok = AtlasBus.send(envelope, content)
    id = envelope.id

    receive do
      {:atlas_bus, %Envelope{id: ^id, class: "stored"}, answer} -> {:stored, answer}
      {:atlas_bus, %Envelope{id: ^id, class: "refused"}, answer} -> {:refused, answer}
    after
      read_timeout() -> {:error, :outcome_unknown}
    end
  end

  defp worker_error(operation, id, reason) do
    AtlasBFFContract.Wire.Control.Workers.Protocol.reply(operation, :error, %{
      "id" => id,
      "error" => %{
        "code" => reason,
        "message" => reason,
        "retryable" => reason == "facts_unavailable"
      }
    })
  end

  defp compact_worker_reply(value) when is_map(value),
    do: Map.new(for {key, item} <- value, not is_nil(item), do: {key, compact_worker_reply(item)})

  defp compact_worker_reply(value) when is_list(value),
    do: Enum.map(value, &compact_worker_reply/1)

  defp compact_worker_reply(value), do: value

  defp ask(kind, content), do: ask(kind, content, @read_attempts, read_timeout())

  defp ask(kind, content, attempts, timeout),
    do: await_read(Envelope.new("read", kind), content, attempts, timeout)

  defp await_read(_envelope, _content, 0, _timeout), do: %{"error" => "Facts did not answer"}

  # Each try waits `timeout` from its send (`AtlasControl.Clock`); answers to other reads do
  # not stretch it. An answer cancels the try's timer, and drops its message if it came.
  defp await_read(envelope, content, attempts, timeout) do
    :ok = AtlasBus.send(envelope, content)
    id = envelope.id
    timer = AtlasControl.Clock.after_ms({:read_expired, id, attempts}, timeout)

    receive do
      {:atlas_bus, %Envelope{id: ^id, class: "answer"}, answer} ->
        Process.cancel_timer(timer)

        receive do
          {:read_expired, ^id, ^attempts} -> answer
        after
          0 -> answer
        end

      {:read_expired, ^id, ^attempts} ->
        await_read(envelope, content, attempts - 1, timeout)
    end
  end

  # How long a read waits for Facts' answer before it asks again (a setting for tests).
  defp read_timeout, do: Application.get_env(:atlas_control, :read_timeout_ms, 2_000)

  defp page_answers(route, m) do
    PageReads.answers(route, m, fn kind, content, budget ->
      ask(kind, content, @read_attempts, read_timeout() * budget)
    end)
  end

  defp show(state, route, reason, position, refused \\ nil, welcome \\ nil) do
    route = start(route, state)

    state =
      case route do
        {:worker_page, :worker_guidance, _} ->
          %{
            state
            | form:
                Map.put_new_lazy(state.form, :worker_client_key, fn ->
                  :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
                end)
          }

        _ ->
          state
      end

    {page, answers, set} = page(state, route, state.form)
    state = count(state, route, answers, set)

    # Remember the version a change form was made from, so the change names it; the values
    # it was read with, so only a change to the same fields refuses it; and the parents the
    # fact had, so only a parent that differs moves it.
    form =
      case {route, answers} do
        {{:edit, kind, _}, [%{"fact" => %{"version" => version} = fact} | _]} ->
          parents = Pages.parent_values(state.model, kind, fact)

          Map.merge(state.form, %{
            version: version,
            parents: parents,
            was: fact["values"] || %{},
            links: fact["links"] || %{}
          })

        _ ->
          state.form
      end

    as_of = position || Enum.find_value(answers, & &1["position"])
    message = message(state, route, page, reason, as_of, refused)
    flagged = deliver_marked(state, message, set.row_keys, welcome)
    recent = Recent.viewed(state.recent, message["path"], entry(route, set, message, flagged))
    seen(%{state | route: route, form: form, recent: recent}, set.as_of)
  end

  # A recent page off screen, read again and pushed (reason "hint"), without the form or
  # the route on screen.
  defp push(state, path, position) do
    %{route: route} = Recent.get(state.recent, path)
    {page, _answers, set} = page(state, route, %{})
    message = message(state, route, page, "hint", position, nil)
    flagged = deliver_marked(state, message, set.row_keys, nil)
    recent = Recent.sent(state.recent, path, entry(route, set, message, flagged))
    seen(%{state | recent: recent}, set.as_of)
  end

  # A page as it goes out: its rows flagged by the session's marks. Returns the marked
  # keys the flags stand for; the page is kept without them.
  defp deliver_marked(state, message, row_keys, welcome) do
    {blocks, flagged} = Marks.overlay(message["blocks"], row_keys, state.marks)
    deliver(state, %{message | "blocks" => blocks}, welcome)
    flagged
  end

  # The recent pages whose flags, as the client has them, differ from the marks now: each
  # sent again as it was last sent, with the same position, flagged anew (`reason:
  # "pending"`), at most `@pushes`, the most recently viewed first. No read; a form is
  # left as it is.
  defp sync_marks(state) do
    state.recent
    |> Recent.paths()
    |> Enum.map(&{&1, Recent.get(state.recent, &1)})
    |> Enum.filter(fn {_path, entry} ->
      not Pages.form?(entry.route) and
        Marks.flagged(entry.view["blocks"], entry.row_keys, state.marks) !=
          Map.get(entry, :marked, [])
    end)
    |> Enum.take(@pushes)
    |> Enum.reduce(state, fn {path, entry}, state ->
      message =
        %{entry.view | "reason" => "pending", "at" => now()}
        |> then(&if(text = count_text(state), do: Map.put(&1, "count", text), else: &1))

      flagged = deliver_marked(state, message, entry.row_keys, nil)
      %{state | recent: Recent.sent(state.recent, path, %{entry | marked: flagged})}
    end)
  end

  # A page off screen that can be read again as it is: none that holds what is typed or
  # what the session only has while on it.
  defp pushable?(%{route: route}) do
    not Pages.form?(route) and
      not match?({tag, _, _} when tag in [:worker_page, :fault], route) and
      not match?({tag, _} when tag in [:faults], route) and
      not match?({:unavailable, _, _}, route) and route != :unknown
  end

  # How far the session has seen: a hint at `position`, or a page read at it.
  defp seen(state, position) when is_integer(position),
    do: %{state | seen: max(state.seen, position)}

  defp seen(state, _position), do: state

  # Whether the page on screen, `route`, is to be read again at a reconcile: `:current`
  # (it is as Facts has it: Facts is not past what the session has seen, and no value on
  # it changed by time since), `:timed` (a value changed by time alone) or `:missed`
  # (Facts is past it, the page was read at no position, or it says nothing of what it
  # depended on). Only the first asks Facts anything: its position.
  defp reconcile(state, route) do
    entry = route == state.route && Recent.get(state.recent, current_path(route))

    cond do
      not (is_map(entry) and entry.route == route and pushable?(entry)) -> :missed
      not is_integer(entry.as_of) -> :missed
      due?(entry.until) -> :timed
      past?(ask(@position, %{}), state.seen) -> :missed
      true -> :current
    end
  end

  defp past?(%{"position" => position}, seen) when is_integer(position), do: position > seen
  defp past?(_answer, _seen), do: true

  defp due?(nil), do: false

  defp due?(until) do
    case DateTime.from_iso8601(until) do
      {:ok, at, _} -> DateTime.compare(DateTime.utc_now(), at) != :lt
      _ -> true
    end
  end

  # Facts is past what the session saw: a hint may have been lost, so what it would have
  # said is found again, the kind of fact the client is and the header's count too.
  defp missed(state) do
    state = put_in(state.count.set, nil)
    %{state | by_kind: known_kind(state, actor_kind(state))}
  end

  # A hint that the fact the client is was made or deleted: which kind of fact the client
  # is, found again. `{state, changed?}`.
  defp client_kind(state, changes) do
    about? =
      Enum.any?(changes, fn {_position, entries} ->
        Enum.any?(entries, &(&1["key"] == state.by and &1["op"] in ["create", "delete"]))
      end)

    by_kind = if about?, do: known_kind(state, actor_kind(state)), else: state.by_kind

    if by_kind == state.by_kind do
      {state, false}
    else
      state = %{state | by_kind: by_kind}
      {put_in(state.count.set, nil), true}
    end
  end

  # The page `route` shows, the answers it was read from and what it depended on.
  defp page(state, route, form) do
    answers = page_answers(route, state.model)

    case route do
      {:worker_page, _, _} = worker_route ->
        {page, read} =
          recording(fn ask ->
            AtlasControl.WorkerPages.render(
              worker_route,
              state.model,
              %{key: state.by, kind: actor_kind(state)},
              ask,
              Map.put(form, :output_capability, &AtlasControl.Output.capability/1)
            )
          end)

        reads = for {kind, _} <- read, do: {kind, :rows}
        {page, answers, ReadSet.of(reads, Enum.map(read, &elem(&1, 1)), page.blocks)}

      {:faults, on} ->
        {Faults.page(route, Faults.offers(on)), answers, ReadSet.none()}

      {:fault, _fault, on} ->
        {Faults.page(route, Faults.offers(on)), answers, ReadSet.none()}

      route ->
        viewer = Map.merge(form, %{by: state.by, by_kind: state.by_kind})
        page = route |> Pages.render(state.model, answers, viewer) |> Faults.with_action(route)
        set = ReadSet.of(PageReads.roles(route, state.model), answers, page.blocks)
        {page, answers, set}
    end
  end

  # `fun` given a read that notes each read and its answer: `{fun's result, [{kind,
  # answer}]}`, for a page that reads as it renders.
  defp recording(fun) do
    key = {__MODULE__, :reads}
    Process.put(key, [])

    ask = fn kind, content ->
      answer = ask(kind, content)
      Process.put(key, [{kind, answer} | Process.get(key, [])])
      answer
    end

    try do
      result = fun.(ask)
      {result, Enum.reverse(Process.get(key, []))}
    after
      Process.delete(key)
    end
  end

  # `view`: the page as it was sent, without its flags; `marked`: the marked keys its
  # flags stood for.
  defp entry(route, set, message, marked),
    do: %{
      route: route,
      deps: set.deps,
      row_keys: set.row_keys,
      view: message,
      marked: marked,
      as_of: set.as_of,
      until: set.until,
      last_sent: now_ms()
    }

  defp message(state, route, page, reason, position, refused) do
    %{
      "op" => "page",
      "path" => current_path(route),
      "title" => page.title,
      "back" => page.back,
      "blocks" => RowKey.put(page.blocks),
      "markup" => page.markup,
      "reason" => reason,
      "position" => position,
      "at" => now()
    }
    |> then(&if(refused, do: Map.put(&1, "refused", refused), else: &1))
    |> then(&if(text = count_text(state), do: Map.put(&1, "count", text), else: &1))
    |> Map.put(:console_actions, Map.get(page, :console_actions, []))
  end

  defp deliver(state, message, welcome) do
    {console_actions, message} = Map.pop(message, :console_actions)

    projected =
      if state.surface == "console" do
        with {:ok, shell} <- AtlasControl.Shell.boot(state.model, state.by_kind),
             {:ok, page} <-
               AtlasControl.Console.project(message, length(shell["tabs"]), console_actions),
             do: {:ok, page}
      else
        {:ok, message}
      end

    case projected do
      {:ok, message} ->
        if welcome, do: send_client(state, welcome)
        send_client(state, message)

      {:error, why} ->
        send_client(state, %{"op" => "bye", "text" => "Console projection unavailable: #{why}"})
        send(self(), :presentation_failed)
    end
  end

  # Hints

  # The hints collected so far, handled at once: each page they made stale is read once.
  # The page on screen is sent again (a form gets a notice); up to `@pushes` other recent
  # pages are pushed, the most recently viewed first; the other stale ones are forgotten,
  # and read when they are opened again.
  defp flush(state) do
    state = cancel_flush(state)
    {hints, batch} = Batch.take(state.batch)
    state = %{state | batch: batch}

    if hints == [] do
      state
    else
      changes = Batch.changes(hints)
      position = Batch.position(hints)
      {state, count?} = stale_count(state, changes)
      {state, kind?} = client_kind(state, changes)
      screen = current_path(state.route)
      stale = Affected.affected(state.recent, changes)
      state = screen(state, screen, kind? or screen in stale, count? or kind?, changes, position)

      {pushed, dropped} =
        stale
        |> List.delete(screen)
        |> Enum.split_with(&pushable?(Recent.get(state.recent, &1)))
        |> then(fn {pushable, unpushable} ->
          {first, rest} = Enum.split(pushable, @pushes)
          {first, rest ++ unpushable}
        end)

      state = Enum.reduce(pushed, state, &push(&2, &1, position))
      %{state | recent: Recent.drop(state.recent, dropped)}
    end
  end

  # The page on screen after hints: sent again when what it, or its header's count,
  # depended on changed; a form only says so.
  defp screen(state, _path, false, false, _changes, _position), do: state

  defp screen(state, path, stale?, _count?, changes, position) do
    if Pages.form?(state.route) do
      entry = Recent.get(state.recent, path)

      case stale? && entry && Affected.first(entry.deps, entry.as_of, changes) do
        {at, change} ->
          notice(state, "info", "#{change["key"]} was changed elsewhere (position #{at}).")

        _ ->
          state
      end
    else
      show(state, state.route, "hint", position)
    end
  end

  # The header's count, made due when what it was read from changed: `{state, changed?}`.
  defp stale_count(%{count: %{set: %ReadSet{} = set}} = state, changes) do
    if Affected.stale?(set.deps, set.as_of, changes),
      do: {put_in(state.count.set, nil), true},
      else: {state, false}
  end

  defp stale_count(state, _changes), do: {state, false}

  defp cancel_flush(%{flush_timer: nil} = state), do: state

  defp cancel_flush(state) do
    Process.cancel_timer(state.flush_timer)
    %{state | flush_timer: nil}
  end

  # Wait for Flow to have settled past `position`, at most `budget` ms; then show the
  # stored page (`stored`), if any, and handle the hints collected meanwhile. A wait still
  # running gives way: a stored page it held is not shown, its notice is.
  defp settle(state, position, budget, stored) do
    state =
      case state.settling do
        nil ->
          state

        old ->
          Process.cancel_timer(old.timer)
          state = %{state | settling: nil}
          if old.stored, do: notice(state, "ok", old.stored.text), else: state
      end

    envelope = %{Envelope.new("request", "_settled") | address: @flow}
    _ = AtlasBus.send(envelope, %{"position" => position})
    ref = make_ref()
    timer = AtlasControl.Clock.after_ms({:settle_timeout, ref}, budget)

    settling = %{
      id: envelope.id,
      ref: ref,
      timer: timer,
      position: position,
      budget: budget,
      stored: stored
    }

    %{state | settling: settling}
  end

  # Flow settled, or the wait ran out: the stored page, then the hints.
  defp settled(%{settling: settling} = state) do
    Process.cancel_timer(settling.timer)
    state = %{state | settling: nil}

    state =
      case settling.stored do
        nil ->
          state

        stored ->
          state = notice(state, "ok", stored.text)
          # The count it heads is read with it when the write, or one meanwhile, changed it.
          {state, _} = stale_count(state, Batch.changes(state.batch.hints))

          if stored.opened,
            do: state,
            else: show(state, stored.after, "stored", settling.position)
      end

    flush(state)
  end

  # While marks are held and nothing is waited for, Flow is asked again, briefly, whether
  # it settled past them; its answer clears them.
  defp ask_settled(%{settling: nil} = state) do
    if Marks.held?(state.marks),
      do: settle(state, Marks.lowest(state.marks), hint_settle_ms(), nil),
      else: state
  end

  defp ask_settled(state), do: state

  defp settle_ms, do: Application.get_env(:atlas_control, :settle_ms, 1_000)
  defp hint_settle_ms, do: Application.get_env(:atlas_control, :hint_settle_ms, 250)

  defp batch_timing,
    do: [
      quiet: Application.get_env(:atlas_control, :batch_quiet_ms, 20),
      most: Application.get_env(:atlas_control, :batch_most_ms, 100)
    ]

  defp now_ms, do: System.monotonic_time(:millisecond)

  # `/` for a client that is a fact of a kind the start's relation points at:
  # what is assigned to it, when the model has such a start page.
  defp start(:home, state) do
    if Pages.assigned_start?(state.model, state.by_kind),
      do: {:assigned, state.by},
      else: :home
  end

  defp start(route, _state), do: route

  # The header's count: from the page when it is the start page of assignments, else read
  # with the page when what it was read from changed (its own read set) or it was never
  # read.
  defp count(state, {:assigned, _} = _route, answers, set),
    do: %{state | count: %{text: Pages.assigned_count(state.model, answers), set: set}}

  defp count(%{count: %{set: nil}} = state, _route, _answers, _set) do
    if Pages.assigned_start?(state.model, state.by_kind) do
      route = {:assigned, state.by}
      answers = page_answers(route, state.model)
      set = ReadSet.of(PageReads.roles(route, state.model), answers, [])
      count(state, route, answers, set)
    else
      %{state | count: %{text: nil, set: ReadSet.none()}}
    end
  end

  defp count(state, _route, _answers, _set), do: state

  defp count_text(%{count: %{text: text}}), do: text

  defp current_path({:assigned, _}), do: "/"
  defp current_path(:home), do: "/"
  defp current_path(:unknown), do: "/"
  defp current_path({:unavailable, path, _failed}), do: path
  defp current_path(route), do: Pages.path(route)

  defp notice(state, tone, text) do
    send_client(state, %{"op" => "notice", "tone" => tone, "text" => text, "at" => now()})
    state
  end

  defp send_client(state, message) do
    case :gen_tcp.send(state.socket, [JSON.encode!(message), "\n"]) do
      :ok -> :ok
      {:error, reason} -> Logger.debug("Control could not reach its client: #{inspect(reason)}")
    end
  end

  defp now, do: NaiveDateTime.local_now() |> NaiveDateTime.to_time() |> Time.to_iso8601()
end

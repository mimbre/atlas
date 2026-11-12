defmodule AtlasControl.Session do
  @moduledoc """
  One connected client. Speaks Control's protocol (`bff/README.md`) as JSON
  lines over TCP, and reaches Facts only over the Bus, as its own endpoint.

  - Opening a path reads what the page needs from Facts and sends the page.
  - A submit becomes a fact. The client is told it waits; the change shows only once
    Facts has stored it. A fact without an answer is sent again with the same id, after
    5 seconds, then twice as long each time, up to a minute.
  - A hint (a `stored` of a kind on screen) re-reads and sends the page again. A form is
    never redrawn under the user's hands; they get a notice instead.
  - The client asks for a refresh on an interval (it reconciles); a lost hint only delays.
  - Each fact says who sent it (`by`): the user at a TUI (`tui_user` in the environment's
    settings; one for now), `migration` for a migration (which may set what the
    description marks `set_by: migration`), or `agent` for any other client, as its hello
    says.
    A submit may carry a `cause`; it goes with the fact, as does a links form's note.
  """
  use GenServer, restart: :temporary

  require Logger

  alias AtlasBus.Envelope
  alias AtlasControl.{Faults, Pages}

  @description "_description"
  @read_attempts 3
  @first_resend 5_000
  @last_resend 60_000
  # How often a create tries the next number when its key turns out to be taken.
  @key_tries 10

  def start_link(socket), do: GenServer.start_link(__MODULE__, socket)

  @impl true
  def init(socket) do
    endpoint = "control/session-#{System.unique_integer([:positive])}"
    :ok = AtlasBus.attach(endpoint)

    {:ok,
     %{
       socket: socket,
       endpoint: endpoint,
       hello: false,
       surface: nil,
       description: %{},
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
       # its words, and whether a hint has made it stale since.
       count: nil,
       count_stale: true,
       cause: nil
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

        state = notice(state, "ok", text)
        {:noreply, show(state, pending.after, "stored", envelope.position)}

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

  # A hint: a fact of some kind was stored, by anyone.
  def handle_info({:atlas_bus, %Envelope{class: "stored"} = envelope, content}, state) do
    state = %{state | count_stale: true}

    if Pages.shows?(state.route, state.description, envelope.kind) do
      if Pages.form?(state.route) do
        {:noreply,
         notice(
           state,
           "info",
           "#{content["key"]} was changed elsewhere (position #{envelope.position})."
         )}
      else
        {:noreply, show(state, state.route, "hint", envelope.position)}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:atlas_bus, _envelope, _content}, state), do: {:noreply, state}

  def handle_info({:resend, id}, state) do
    case state.pending[id] do
      nil ->
        {:noreply, state}

      pending ->
        :ok = AtlasBus.send(pending.envelope, pending.content)
        wait = min(pending.wait * 2, @last_resend)
        timer = Process.send_after(self(), {:resend, id}, wait)
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
              case Pages.resolve({:item, "_", request["key"]}, state.description) do
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

          if is_binary(kind) and Map.has_key?(state.description["entities"], kind) do
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
    # Unlike page refresh, stale cached description is not a successful shell reply.
    case ask(@description, %{}) do
      %{"description" => description} ->
        result =
          with :ok <- AtlasControl.Shell.validate_description(description) do
            # Work against a candidate only. Invalid metadata/target resolution must
            # leave the prior description, listeners, route and form intact.
            candidate = %{state | description: description}
            by_kind = known_kind(candidate, actor_kind(candidate))
            candidate = %{candidate | by_kind: by_kind}

            case AtlasControl.Shell.boot(
                   description,
                   by_kind,
                   message["to"],
                   &route(&1, candidate)
                 ) do
              {:ok, shell} -> {:ok, shell, candidate}
              {:error, _} = error -> error
            end
          end

        case result do
          {:ok, shell, candidate} ->
            kinds = Map.keys(description["entities"])
            Enum.each(kinds, &AtlasBus.listen/1)
            send_client(state, Map.put(shell, "op", "boot"))
            {:noreply, %{candidate | listening: MapSet.new(kinds)}}

          {:error, why} ->
            send_client(state, %{"op" => "boot", "error" => why})
            {:noreply, state}
        end

      _ ->
        send_client(state, %{
          "op" => "boot",
          "error" => "Facts did not answer with the description"
        })

        {:noreply, state}
    end
  end

  defp handle_op("open", %{"to" => to}, state) do
    # Without the description (Facts did not answer at hello) no page can be worked out.
    state = if state.description == %{}, do: describe(state), else: state
    {:noreply, show(%{state | form: %{}}, route(to, state), "open", nil)}
  end

  defp handle_op("refresh", _message, state) do
    state = describe(state)

    # A page Facts did not answer for is worked out again.
    route =
      case state.route do
        {:unavailable, path, _failed} -> route(path, state)
        route -> route
      end

    if Pages.form?(route),
      do: {:noreply, state},
      else: {:noreply, show(state, route, "reconcile", nil)}
  end

  defp handle_op("turn", _message, state) do
    result =
      case AtlasControl.Turns.current(state.description, state.by, &ask/2) do
        {:ok, context} -> Map.take(context, ["key", "on", "read_first"])
        {:error, why} -> %{"error" => why}
      end

    send_client(state, Map.put(result, "op", "turn"))
    {:noreply, state}
  end

  defp handle_op("turn_end", message, state) do
    case AtlasControl.Turns.outcome(state.description, state.by, message, &ask/2) do
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
        route = endpoint |> Pages.submit_route(params) |> Pages.resolve(state.description)
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
  # that cannot be worked out because Facts did not answer (no description, or no answer
  # on which kind holds a key) is `{:unavailable, path, failed}`: it says so, and a
  # refresh works it out again.
  defp route(to, state) do
    case Pages.route(to) do
      :unknown ->
        :unknown

      _ when state.description == %{} ->
        {:unavailable, to, %{"error" => "Facts did not answer"}}

      route ->
        case Pages.resolve(route, state.description) do
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
      {:ok, kind} -> Pages.resolve({:links, kind, key, relation}, state.description)
      %{"error" => _} = failed -> {:unavailable, to, failed}
      nil -> :unknown
    end
  end

  defp by_key(_route, _to, _state), do: :unknown

  # `{:ok, kind}`; else the first failed read when one failed (it may have been that kind);
  # else nil.
  defp kind_holding(key, state) do
    Enum.reduce_while(Pages.unprefixed_kinds(state.description), nil, fn kind, failed ->
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
    # The property the id was made from is shown, never changed.
    spec = spec(state, kind)
    {parents, fields} = Map.split(raw, Pages.parent_relations(state.description, kind))
    values = Pages.values_for(spec, Map.drop(fields, List.wrap(Pages.id_property(spec))))
    state = %{state | route: route, form: Map.put(state.form, :values, raw)}
    was = state.form[:parents] || %{}

    with {:ok, links} <- moves(parents, was),
         [] <- over_limits(state, kind, key, links) do
      # Only what was edited is sent, with what the form was read with for it: Facts then
      # refuses an old version only when one of these changed meanwhile, never because
      # other fields did, and a save never puts back an old value of a field left alone.
      read = state.form[:was] || %{}

      values =
        for {name, value} <- values,
            loose(value) != loose(read[name]),
            into: %{},
            do: {name, value}

      seen =
        Map.merge(
          Map.new(values, fn {name, _} -> {name, read[name]} end),
          Map.new(links, fn {relation, _} -> {relation, List.wrap(was[relation])} end)
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
      reasons when is_list(reasons) -> not_sent(state, route, reasons)
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

  defp submit({:delete, kind, key} = route, _raw, state) do
    answer = ask(kind, %{"key" => key})

    held =
      Pages.children(state.description, kind, answer)
      |> Enum.reject(fn {_, keys} -> keys == [] end)

    case answer do
      %{"fact" => %{"version" => version}} when held == [] ->
        content = %{"op" => "delete", "key" => key, "values" => %{}, "version" => version}

        put_fact(
          %{state | route: route},
          kind,
          content,
          Pages.after_delete(state.description, kind, answer)
        )

      _ ->
        show(state, route, "open", nil)
    end
  end

  # The links of one association: exactly the keys named, none removes them.
  defp submit({:links, kind, key, relation} = route, raw, state) do
    state = %{state | route: route, form: Map.put(state.form, :values, raw)}

    keys = Pages.link_keys(raw["to"])

    if Pages.may_link_to?(state.description, relation, state.by, state.by_kind, keys) do
      note = String.trim(raw["note"] || "")
      change = Pages.change_action(state.description, relation)

      state =
        case Pages.change_cause(change || %{}, keys, state.by, note) do
          nil -> state
          cause -> %{state | cause: cause}
        end

      # What the change also asks (`with`) goes in the same change as the link.
      with_fields = List.wrap(change && change["with"])
      values = Pages.values_for(spec(state, kind), Map.take(raw, with_fields))
      content = %{link(key, relation, keys) | "values" => values}
      put_fact(state, kind, content, {:item, kind, key})
    else
      show(state, route, "refused", nil)
    end
  end

  # Link the fact to the client itself (Accept), when the page would let it.
  defp submit({:set, kind, key, relation} = route, _raw, state) do
    answers = Enum.map(Pages.reads(route, state.description), fn {k, c} -> ask(k, c) end)

    case Pages.set_problem(state.description, route, answers, state.by, state.by_kind) do
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
      not Pages.may_link?(state.description, relation, state.by, state.by_kind) ->
        show(state, route, "refused", nil)

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
    spec = spec(state, kind)

    if Pages.id_property(spec),
      do: create_made(route, kind, spec, raw, links, state),
      else: create_numbered(route, kind, spec, raw, links, state)
  end

  # An id made from a property: the same value is the same fact, so a taken key is never
  # retried with another number. When the key cannot be made, nothing goes to Facts.
  defp create_made(route, kind, spec, raw, links, state) do
    state = %{state | route: route, form: %{values: raw}}

    with {:ok, key} <- Pages.key_for(spec, raw),
         [] <- over_limits(state, kind, key, links) do
      content = new_fact(spec, key, raw, links)
      put_fact(state, kind, content, {:item, kind, key})
    else
      {:error, reason} -> not_sent(state, route, [reason])
      reasons when is_list(reasons) -> not_sent(state, route, reasons)
    end
  end

  defp create_numbered(route, kind, spec, raw, links, state) do
    case over_limits(state, kind, nil, links) do
      [] -> create_numbered_free(route, kind, spec, raw, links, state)
      reasons -> not_sent(%{state | route: route, form: %{values: raw}}, route, reasons)
    end
  end

  defp create_numbered_free(route, kind, spec, raw, links, state) do
    keys =
      case ask(kind, %{}) do
        %{"facts" => facts} -> Enum.map(facts, & &1["key"])
        _ -> []
      end

    {key, number} = Pages.next_key(spec, keys)
    content = new_fact(spec, key, raw, links)
    state = %{state | route: route, form: %{values: raw}}
    put_fact(state, kind, content, {:item, kind, key}, %{number: number, tries: 1, skipped: []})
  end

  # A link the description limits (`relations.<name>.limit`) is refused before Facts sees
  # it while its parent already has as many counted facts as allowed. Links that are
  # there already stay; only a new one (a create, or a move) is checked.
  defp over_limits(state, kind, key, links) do
    closed(state, kind, links) ++
      for {relation, parent} <- Pages.limited(state.description, links),
          problem = limit_problem(state, relation, kind, key, parent),
          problem != nil,
          do: problem
  end

  # A new fact under a parent that is closed to it (accepted: `closes_parent`), by a create
  # or a move, is refused with why.
  defp closed(state, kind, links) do
    for {relation, parents} <- links,
        relation in Pages.parent_relations(state.description, kind),
        [parent_kind] <- [get_in(state.description, ["relations", relation, "to"])],
        parent <- parents,
        %{"fact" => %{} = fact} <- [ask(parent_kind, %{"key" => parent})],
        problem = Pages.closed_problem(state.description, kind, parent_kind, fact),
        problem != nil,
        do: problem
  end

  defp limit_problem(state, relation, kind, key, parent) do
    case ask(kind, %{"linked" => %{relation => parent}}) do
      %{"facts" => children} ->
        Pages.over_limit(state.description, relation, kind, key, parent, children)

      %{"error" => error} ->
        "#{error}; could not check how many #{parent} has"
    end
  end

  defp not_sent(state, route, reasons) do
    state = notice(state, "error", "Not sent: the form says why.")
    show(put_in(state.form[:errors], reasons), route, "refused", nil)
  end

  defp new_fact(spec, key, raw, links) do
    content = %{
      "op" => "create",
      "key" => key,
      "values" => Pages.create_values(spec, raw),
      "version" => nil
    }

    if links == %{}, do: content, else: Map.put(content, "links", links)
  end

  defp retry_create(state, pending) do
    kind = pending.envelope.kind
    {key, number} = Pages.next_key(spec(state, kind), [], pending.retry.number)
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
    timer = Process.send_after(self(), {:resend, envelope.id}, @first_resend)

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

  defp describe(state) do
    case ask(@description, %{}) do
      %{"description" => description} ->
        install_description(state, description)

      _ ->
        notice(
          state,
          "error",
          "Facts did not answer with the description; showing what Control had."
        )
    end
  end

  defp install_description(state, description) do
    kinds = Map.keys(description["entities"] || %{})
    Enum.each(kinds, &AtlasBus.listen/1)
    state = %{state | description: description, listening: MapSet.new(kinds)}
    %{state | by_kind: known_kind(state, actor_kind(state))}
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
      case Pages.resolve(route, state.description) do
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
    case ask(@description, %{}) do
      %{"description" => description} ->
        candidate = %{state | description: description}
        actor = %{key: state.by, kind: actor_kind(candidate)}

        AtlasControl.Workers.handle(
          operation,
          request,
          description,
          actor,
          &ask/2,
          &worker_fact/2
        )

      _ ->
        {:error, "facts_unavailable"}
    end
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

  defp await_read(envelope, content, attempts, timeout) do
    :ok = AtlasBus.send(envelope, content)
    id = envelope.id

    receive do
      {:atlas_bus, %Envelope{id: ^id, class: "answer"}, answer} -> answer
    after
      timeout -> await_read(envelope, content, attempts - 1, timeout)
    end
  end

  # How long a read waits for Facts' answer before it asks again (a setting for tests).
  defp read_timeout, do: Application.get_env(:atlas_control, :read_timeout_ms, 2_000)

  defp page_answers(route, description) do
    AtlasControl.PageReads.answers(route, description, fn kind, content, budget ->
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

    answers = page_answers(route, state.description)

    state = count(state, route, answers)

    form = Map.merge(state.form, %{by: state.by, by_kind: state.by_kind})

    page =
      case route do
        {:worker_page, _, _} = worker_route ->
          case ask(@description, %{}) do
            %{"description" => description} ->
              actor = %{key: state.by, kind: actor_kind(%{state | description: description})}

              AtlasControl.WorkerPages.render(
                worker_route,
                description,
                actor,
                &ask/2,
                Map.put(state.form, :output_capability, &AtlasControl.Output.capability/1)
              )

            _ ->
              AtlasControl.WorkerPages.error("facts_unavailable", "/workers")
          end

        {:faults, on} ->
          Faults.page(route, Faults.offers(on))

        {:fault, _fault, on} ->
          Faults.page(route, Faults.offers(on))

        route ->
          route |> Pages.render(state.description, answers, form) |> Faults.with_action(route)
      end

    # Remember the version a change form was made from, so the change names it; the values
    # it was read with, so only a change to the same fields refuses it; and the parents the
    # fact had, so only a parent that differs moves it.
    form =
      case {route, answers} do
        {{:edit, kind, _}, [%{"fact" => %{"version" => version} = fact} | _]} ->
          parents = Pages.parent_values(state.description, kind, fact)
          Map.merge(state.form, %{version: version, parents: parents, was: fact["values"] || %{}})

        _ ->
          state.form
      end

    as_of = position || Enum.find_value(answers, & &1["position"])

    message =
      %{
        "op" => "page",
        "path" => current_path(route),
        "title" => page.title,
        "back" => page.back,
        "blocks" => page.blocks,
        "markup" => page.markup,
        "reason" => reason,
        "position" => as_of,
        "at" => now()
      }
      |> then(&if(refused, do: Map.put(&1, "refused", refused), else: &1))
      |> then(&if(state.count, do: Map.put(&1, "count", state.count), else: &1))

    projected =
      if state.surface == "console" do
        with {:ok, shell} <- AtlasControl.Shell.boot(state.description, state.by_kind),
             {:ok, page} <-
               AtlasControl.Console.project(
                 message,
                 length(shell["tabs"]),
                 Map.get(page, :console_actions, [])
               ),
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

    %{state | route: route, form: form}
  end

  # `/` for a client that is a fact of a kind the start's relation points at:
  # what is assigned to it, when the description has such a start page.
  defp start(:home, state) do
    if Pages.assigned_start?(state.description, state.by_kind),
      do: {:assigned, state.by},
      else: :home
  end

  defp start(route, _state), do: route

  # The header's count: from the page when it is the start page of assignments, else read
  # again only after a hint (a fact may have moved to or away from the client).
  defp count(state, {:assigned, _} = _route, answers),
    do: %{state | count: Pages.assigned_count(state.description, answers), count_stale: false}

  defp count(%{count_stale: true} = state, _route, _answers) do
    if Pages.assigned_start?(state.description, state.by_kind) do
      route = {:assigned, state.by}

      answers = page_answers(route, state.description)

      count(state, route, answers)
    else
      %{state | count: nil, count_stale: false}
    end
  end

  defp count(state, _route, _answers), do: state

  defp current_path({:assigned, _}), do: "/"
  defp current_path(:home), do: "/"
  defp current_path(:unknown), do: "/"
  defp current_path({:unavailable, path, _failed}), do: path
  defp current_path(route), do: Pages.path(route)

  defp spec(state, kind), do: get_in(state.description, ["entities", kind]) || %{}

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

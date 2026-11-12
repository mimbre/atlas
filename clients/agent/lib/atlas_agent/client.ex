defmodule AtlasAgent.Client do
  @moduledoc """
  One connection to Control of an environment, speaking its protocol
  (`bff/README.md`) as the TUI does: hello, open a path, submit a form. It waits
  for what it asked and passes over the rest (hints, notices, reconciles).

  Everything it knows comes from Control's pages: a form names the fields it asks and
  where to submit them; a stored fact's page has the fact's path; a refused form says why.
  """

  defstruct [:socket, :env]

  @connect_timeout 2_000
  # A page answers an open at once; a submit waits until Facts stored or refused it, and
  # Control sends a fact again on its own while Facts does not answer.
  @page_wait 10_000
  @stored_wait 60_000

  @doc """
  Connect to Control at `settings[\"control\"]` and say hello for `env`, as `as`: an
  `agent`, or a `migration` (which may set what the description marks as set by one).
  """
  def connect(env, settings, as \\ "agent") do
    host = settings["control"]["host"] |> String.to_charlist()
    port = settings["control"]["port"]
    options = [:binary, packet: :line, active: false, buffer: 4_194_304]

    case tcp_connect(host, port, options, env) do
      {:ok, socket} ->
        client = %__MODULE__{socket: socket, env: env}

        case exchange(client, :hello, hello(env, as), @page_wait) do
          {:ok, _} ->
            {:ok, client}

          error ->
            close(client)
            error
        end

      error ->
        error
    end
  end

  @doc "The current turn, or Facts' acknowledgement of its outcome (not Runtime/Flow completion)."
  def turn(client, message \\ AtlasAgent.Protocol.message(:turn, :turn)) do
    operation =
      case message["op"] do
        "turn" -> :turn
        "turn_end" -> :turn_end
        _ -> raise ArgumentError, "not a turn request"
      end

    case exchange(client, operation, message, @stored_wait) do
      {:ok, %{"reason" => "refused"}} -> {:error, "Facts refused the outcome"}
      result -> result
    end
  end

  def close(%__MODULE__{socket: socket}), do: :gen_tcp.close(socket)

  # The contract version this client implements; Control sends a too old one away.
  @version AtlasAgent.Protocol.version()

  @doc "The hello this client says: its environment, what it is, and its contract version."
  def hello(env, as) do
    hello = %{env: env, client: as, spec: @version}

    # The fact an agent is (an agent's key), from ATLAS_AS: it then owns what is assigned
    # to that agent and sees what to do (IS-Atlas-54). The migration is the migration.
    props =
      case System.get_env("ATLAS_AS") do
        who when is_binary(who) and who != "" and as != "migration" -> Map.put(hello, :as, who)
        _ -> hello
      end

    AtlasAgent.Protocol.message(:hello, :hello, props)
  end

  def facts(client, kind, key) do
    request = AtlasAgent.Protocol.request(:facts_read, kind: kind, key: key)

    with {:ok, reply} <- exchange(client, :facts_read, request, @page_wait),
         do: {:ok, reply["data"]}
  end

  @doc "The page at
 `path`."
  def open(client, path) do
    exchange(client, :open, AtlasAgent.Protocol.request(:open, to: path), @page_wait)
  end

  @doc """
  Submit `values` (text) to what a form's `submit_to` (or a confirm's `confirm_to`) names:
  an endpoint and its params. With why (`cause`) when given. Answers
  `{:stored, page}` with the page Control shows after it was stored, or `{:refused, reasons}`.
  """
  def submit(client, to, values, cause \\ nil) do
    message =
      AtlasAgent.Protocol.request(:submit,
        endpoint: to["endpoint"],
        params: to["params"] || %{},
        values: values,
        cause: cause
      )

    with {:ok, page} <- exchange(client, :submit, message, @stored_wait) do
      case page["reason"] do
        "stored" ->
          {:stored, page}

        "refused" ->
          errors = page |> blocks("form") |> Enum.flat_map(&(&1["errors"] || []))
          errors = if errors == [], do: page["refused"] || [], else: errors
          {:refused, if(errors == [], do: ["refused"], else: errors)}
      end
    end
  end

  @doc "The props of every block of `type` on `page`."
  def blocks(page, type),
    do: for(%{"type" => ^type, "props" => props} <- page["blocks"] || [], do: props)

  @doc "The last part of a path, which is the key of the fact it shows."
  def key_of(path), do: path |> String.split("/") |> List.last() |> URI.decode()

  defp tcp_connect(host, port, options, env) do
    case :gen_tcp.connect(host, port, options, @connect_timeout) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, _} ->
        {:error,
         "Control #{env} does not answer at #{host}:#{port}. " <>
           "Is it running? See `atlas-ops status --env #{env}`."}
    end
  end

  @doc false
  # Serial passive socket: one outstanding exchange. A fixed monotonic deadline
  # covers the entire handshake/request, including all unsolicited messages.
  # Exposed for short deterministic transport tests; production uses the constants above.
  def exchange(client, operation, message, timeout) do
    # Validate before sending, including channel/direction; never replay a write.
    case AtlasAgent.Protocol.decode_request(message) do
      {:ok, ^operation, ^message} -> :ok
      _ -> raise ArgumentError, "request does not match operation"
    end

    deadline = System.monotonic_time(:millisecond) + timeout

    with :ok <- send_line(client, message) do
      await_until(client, operation, message, deadline, MapSet.new())
    else
      error ->
        close(client)
        error
    end
  end

  defp await_until(client, operation, request, deadline, seen) do
    left = deadline - System.monotonic_time(:millisecond)

    result =
      if left <= 0 do
        {:error, :timeout}
      else
        :gen_tcp.recv(client.socket, 0, left)
      end

    case result do
      {:ok, line} ->
        case JSON.decode(line) do
          {:ok, message} ->
            dispatch(client, operation, request, deadline, seen, message)

          {:error, _} ->
            fail(
              client,
              "Control #{client.env} sent malformed JSON",
              operation,
              "malformed_reply"
            )
        end

      {:error, :timeout} ->
        fail(client, "Control #{client.env} did not answer in time", operation, "timeout")

      {:error, _} ->
        fail(
          client,
          "Control #{client.env} closed the connection",
          operation,
          "control_unavailable"
        )
    end
  end

  defp dispatch(client, operation, request, deadline, seen, message) do
    case AtlasAgent.Protocol.classify(operation, message) do
      :ignore ->
        await_until(client, operation, request, deadline, seen)

      {:invalid, why} ->
        fail(
          client,
          "Control #{client.env} sent an invalid reply: #{why}",
          operation,
          "invalid_reply"
        )

      {:reply, reply} ->
        bound =
          operation != :runtime_machine_discover or reply.effect in [:progress, :terminal] or
            (message["id"] == request["id"] and message["target"] == request["target"] and
               (reply.effect != :complete or
                  get_in(message, ["availability", "target"]) == request["target"]))

        if bound and Enum.all?(Map.get(reply, :requires, []), &MapSet.member?(seen, &1)) do
          case reply.effect do
            :complete ->
              {:ok, message}

            :progress ->
              await_until(client, operation, request, deadline, MapSet.put(seen, reply.name))

            :terminal ->
              fail(client, message["text"])

            :error ->
              {:error, message["error"]}
          end
        else
          fail(
            client,
            if(bound,
              do: "Control #{client.env} sent replies out of order",
              else: "Control #{client.env} sent a reply for another request or machine"
            ),
            operation,
            "reply_identity_mismatch"
          )
        end
    end
  end

  defp fail(client, why, operation \\ nil, code \\ "control_unavailable") do
    close(client)

    if operation == :runtime_machine_discover,
      do:
        {:error,
         %{
           "code" => code,
           "message" => why,
           "retryable" => code in ["timeout", "control_unavailable"]
         }},
      else: {:error, why}
  end

  defp send_line(client, message) do
    case :gen_tcp.send(client.socket, [JSON.encode!(message), "\n"]) do
      :ok -> :ok
      {:error, _} -> {:error, "Control #{client.env} closed the connection"}
    end
  end
end

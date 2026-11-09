defmodule AtlasRuntime.Backend.Events do
  @moduledoc """
  The Server-Sent Events loop of `GET /v1/events` (design §1.8, §8.4): hand-written
  plumbing the generated router calls with the chunked conn once the stream is open.

  The router has already subscribed through the facade, in this process, with the
  client's rights and `Last-Event-ID` as `from`, and has written the opening `reset`
  event when the subscription opened with one. From then on the work implementation
  sends this process each notification the client may see as

      {:notification, struct}

  where `struct` is one of the facade's event models (`WorkChanged`, `CapacityAvailable`,
  `Heartbeat`, `Reset`). The loop writes every one as a frame (`event:`, `id:` = its
  change sequence where it has one, `data:` the JSON) through the router's `__event__/1`,
  and ignores anything that is no event.

  It has no timer of its own. The 15 s `heartbeat` is a boundary notification the core
  emits (§3.6); written like any other, it also keeps proxies from dropping the
  connection, and a client that left is noticed at the next write, which ends the loop.
  When the listener stops, the loop ends with it, quietly.
  Visibility, the window and the heartbeat's content are the implementation's; this loop
  decides nothing.
  """

  require Logger

  @doc "Write notifications to `conn` as frames of `router` until the client leaves."
  def stream(conn, router), do: stream(conn, router, parent())

  defp stream(conn, router, parent) do
    receive do
      {:notification, value} ->
        case router.__event__(value) do
          {:ok, frame} ->
            case Plug.Conn.chunk(conn, frame) do
              {:ok, conn} -> stream(conn, router, parent)
              {:error, _closed} -> conn
            end

          :error ->
            Logger.warning("#{inspect(__MODULE__)}: #{inspect(value)} is no event; not sent")
            stream(conn, router, parent)
        end

      # The connection's process traps exits; while it waits here, its supervisor's
      # shutdown (the listener stopping) arrives as a message. End the stream at once,
      # rather than keep the listener waiting for its shutdown timeout, and hand the
      # message back, so the connection's process stops for the reason its supervisor
      # gave: quietly on a shutdown, logged as a crash on anything else. Exiting here
      # instead would have Bandit log every normal stop as an error.
      {:EXIT, ^parent, _reason} = exit ->
        send(self(), exit)
        conn

      # Another linked process: one that ended normally does not end the stream; one
      # that failed takes the stream with it, as the link would without the trap.
      {:EXIT, _from, :normal} ->
        stream(conn, router, parent)

      {:EXIT, _from, reason} ->
        exit(reason)
    end
  end

  # The connection's supervisor: the process its exit signals come from.
  defp parent do
    case Process.get(:"$ancestors") do
      [pid | _] when is_pid(pid) -> pid
      [name | _] when is_atom(name) -> Process.whereis(name)
      _ -> nil
    end
  end
end

defmodule AtlasFacts.Rela.Events do
  @moduledoc """
  rela's change feed: follows `GET <api>/_events` (rela's server-sent events, its
  data-entry API reference, "SSE events") and tells `notify` which kinds changed in rela,
  whoever wrote them. It is how Facts hears of writes that do not pass through it, such
  as those of rela's own sync connectors (ADR-0006, amended).

  rela sends `entity:changed` with `{"type": kind}` once per kind and write burst, and no
  key; this sends `{:rela_changed, [kind]}`. A first frame that cannot resume (`ready`
  without an earlier position, `refresh`) sends `{:rela_changed, :all}`: what changed
  while nobody listened is not known. Each frame's `id:` is kept, and a lost stream is
  opened again with it (`Last-Event-ID`), so rela repeats what changed meanwhile. rela
  pings every 25 s; a stream silent for longer than `@silence` is opened again.
  """
  use GenServer

  require Logger

  @silence 60_000
  @again 5_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    send(self(), :open)

    {:ok,
     %{
       url: Keyword.fetch!(opts, :url) <> "/_events",
       notify: Keyword.fetch!(opts, :notify),
       request: nil,
       buffer: "",
       last: nil,
       timer: nil
     }}
  end

  @impl true
  def handle_info(:open, state) do
    # rela serves its feed only to a caller of its own origin (on Fly its edge says so).
    uri = URI.parse(state.url)

    headers =
      [{"accept", "text/event-stream"}, {"origin", "#{uri.scheme}://#{uri.host}:#{uri.port}"}] ++
        if(state.last, do: [{"last-event-id", state.last}], else: []) ++ credential()

    request = {String.to_charlist(state.url), Enum.map(headers, &charlists/1)}

    case :httpc.request(:get, request, [connect_timeout: 5_000, timeout: :infinity],
           sync: false,
           stream: :self
         ) do
      {:ok, ref} -> {:noreply, watch(%{state | request: ref, buffer: ""})}
      {:error, reason} -> again(state, reason)
    end
  end

  def handle_info({:http, {ref, :stream_start, _headers}}, %{request: ref} = state),
    do: {:noreply, watch(state)}

  def handle_info({:http, {ref, :stream, chunk}}, %{request: ref} = state) do
    {frames, rest} = frames(state.buffer <> chunk)
    state = Enum.reduce(frames, %{state | buffer: rest}, &frame/2)
    {:noreply, watch(state)}
  end

  def handle_info({:http, {ref, :stream_end, _headers}}, %{request: ref} = state),
    do: again(state, :closed)

  # Not a stream: rela (or its edge) answered with a status, or the request failed.
  def handle_info({:http, {ref, {{_, status, _}, _headers, _body}}}, %{request: ref} = state),
    do: again(state, {:status, status})

  def handle_info({:http, {ref, {:error, reason}}}, %{request: ref} = state),
    do: again(state, reason)

  def handle_info(:silent, state) do
    if state.request, do: :httpc.cancel_request(state.request)
    again(state, :silent)
  end

  # An answer of a request this let go of.
  def handle_info({:http, _}, state), do: {:noreply, state}

  defp again(state, reason) do
    Logger.warning("Facts lost rela's change feed (#{inspect(reason)}); it opens it again")
    if state.timer, do: Process.cancel_timer(state.timer)
    Process.send_after(self(), :open, @again)
    {:noreply, %{state | request: nil, timer: nil}}
  end

  defp watch(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :silent, @silence)}
  end

  @doc false
  # Pure, for tests: the complete frames in `text` (fields by name) and what is left over.
  def frames(text) do
    parts = text |> String.replace("\r\n", "\n") |> String.split("\n\n")
    {complete, [rest]} = Enum.split(parts, -1)

    frames =
      for part <- complete, part != "" do
        for line <- String.split(part, "\n"),
            [name, value] <- [String.split(line, ":", parts: 2)],
            name != "",
            into: %{},
            do: {name, String.trim_leading(value)}
      end

    {frames, rest}
  end

  defp frame(fields, state) do
    resumed? = state.last != nil
    state = if fields["id"], do: %{state | last: fields["id"]}, else: state

    case fields["event"] do
      "entity:changed" ->
        case JSON.decode(fields["data"] || "") do
          {:ok, %{"type" => kind}} when is_binary(kind) -> send(state.notify, {:rela_changed, [kind]})
          _ -> :ok
        end

      "ready" when not resumed? ->
        send(state.notify, {:rela_changed, :all})

      "refresh" ->
        send(state.notify, {:rela_changed, :all})

      _ ->
        :ok
    end

    state
  end

  defp credential do
    case Application.get_env(:atlas_facts, :rela_token) do
      nil -> []
      token -> [{"authorization", "Bearer " <> token}]
    end
  end

  defp charlists({k, v}), do: {String.to_charlist(k), String.to_charlist(v)}
end

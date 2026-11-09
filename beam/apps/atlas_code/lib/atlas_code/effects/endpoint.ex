defmodule AtlasCode.Effects.Endpoint do
  @moduledoc """
  `AtlasCode.Effects` on the Bus: the endpoint `code/effects`, answering Flow's effect
  requests (`flow_effect`) from Flow's effect endpoint (`flow/effects`) only. One request
  at a time, so one id is never worked on twice at once.

  A request it fails on (its journal unreadable or damaged, a full disk) is answered
  `working` and logged by id only: Flow asks again by lookup, and the core it runs in
  goes on (`atlas_code` is permanent in the core's release).
  """
  use GenServer
  require Logger
  alias AtlasBus.Envelope

  @address "code/effects"
  @sender "flow/effects"

  def address, do: @address

  def start_link(settings), do: GenServer.start_link(__MODULE__, settings, name: __MODULE__)

  @impl true
  def init(settings) do
    receiver = AtlasCode.Effects.new(settings)
    :ok = AtlasBus.attach(@address)
    {:ok, receiver}
  end

  @impl true
  def handle_info({:atlas_bus, %Envelope{class: "request", kind: "flow_effect"} = e, body}, s) do
    reply =
      if e.sender == @sender,
        do: answer(s, body),
        else: %{"version" => 1, "status" => "invalid"}

    AtlasBus.send(Envelope.reply(e, "answer"), reply)
    {:noreply, s}
  end

  def handle_info(_, s), do: {:noreply, s}

  @doc "The receiver's answer to `body`, or `working` when it fails on it."
  def answer(s, body) do
    AtlasCode.Effects.handle(s, body)
  rescue
    error ->
      id = get_in(body, ["request", "id"])
      Logger.error("code/effects: request #{inspect(id)} failed: #{inspect(error.__struct__)}")

      %{
        "version" => 1,
        "id" => id,
        "digest" => body["digest"],
        "fingerprint" => get_in(body, ["request", "fingerprint"]),
        "status" => "working"
      }
  end
end

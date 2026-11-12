defmodule AtlasControl.FakeFlow do
  @moduledoc """
  A stand-in for Flow on the Bus, for Control's tests: the endpoint `flow`, answering
  `_settled` (`{"position": P}`) as Flow does, with `{"settled": S}` once S ≥ P. By
  default it has settled everything at once; `hold/0` keeps every request unanswered
  until `settle/1` reaches its position. It tells the test of each request
  (`{:settled_asked, position}`) when `tell/1` names it.
  """
  use GenServer

  alias AtlasBus.Envelope

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Answer nothing until `settle/1`."
  def hold, do: GenServer.call(__MODULE__, :hold)

  @doc "Flow has settled up to `position`: every request it reached is answered."
  def settle(position), do: GenServer.call(__MODULE__, {:settle, position})

  @doc "Tell `pid` `{:settled_asked, position}` of each request."
  def tell(pid), do: GenServer.call(__MODULE__, {:tell, pid})

  @impl true
  def init(:ok) do
    :ok = AtlasBus.attach("flow")
    {:ok, %{held: false, settled: 0, waiting: [], tell: nil}}
  end

  @impl true
  def handle_call(:hold, _from, s), do: {:reply, :ok, %{s | held: true}}
  def handle_call({:tell, pid}, _from, s), do: {:reply, :ok, %{s | tell: pid}}

  def handle_call({:settle, position}, _from, s) do
    {due, waiting} = Enum.split_with(s.waiting, fn {p, _} -> p <= position end)
    for {_, request} <- due, do: answer(request, position)
    {:reply, :ok, %{s | settled: max(s.settled, position), waiting: waiting}}
  end

  @impl true
  def handle_info(
        {:atlas_bus, %Envelope{class: "request", kind: "_settled"} = request, %{"position" => p}},
        s
      ) do
    if s.tell, do: send(s.tell, {:settled_asked, p})

    cond do
      not s.held -> answer(request, p) && {:noreply, s}
      p <= s.settled -> answer(request, s.settled) && {:noreply, s}
      true -> {:noreply, %{s | waiting: s.waiting ++ [{p, request}]}}
    end
  end

  def handle_info(_message, s), do: {:noreply, s}

  defp answer(request, settled),
    do: :ok == AtlasBus.send(Envelope.reply(request, "answer"), %{"settled" => settled})
end

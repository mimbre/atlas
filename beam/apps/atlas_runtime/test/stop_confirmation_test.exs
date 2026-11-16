defmodule AtlasRuntime.StopConfirmationTest do
  use ExUnit.Case, async: true

  defmodule Host do
    use GenServer
    def start_link(observer), do: GenServer.start_link(__MODULE__, observer)
    def init(observer), do: {:ok, {observer, nil}}

    def handle_call({:control, :stop, :await}, from, {observer, _}) do
      send(observer, {:stop_requested, self()})
      {:noreply, {observer, from}}
    end

    def handle_info(:confirmed_quiescent, {observer, from}) do
      GenServer.reply(from, :ok)
      {:noreply, {observer, nil}}
    end
  end

  test "a stop request stays pending until the native host confirms quiescence" do
    host = start_supervised!({Host, self()})
    task = Task.async(fn -> AtlasRuntime.Agent.Native.stop_confirmed(host) end)
    assert_receive {:stop_requested, ^host}
    assert Task.yield(task, 0) == nil
    send(host, :confirmed_quiescent)
    assert Task.await(task) == :ok
  end

  test "loss after the stop request is uncertain" do
    host = start_supervised!({Host, self()})
    task = Task.async(fn -> AtlasRuntime.Agent.Native.stop_confirmed(host) end)
    assert_receive {:stop_requested, ^host}
    stop_supervised!(Host)
    assert Task.await(task) == {:error, :uncertain}
  end

  test "an absent adapter is not a confirmed stopped execution" do
    host = start_supervised!({Host, self()})
    stop_supervised!(Host)
    assert AtlasRuntime.Agent.Native.stop_confirmed(host) == {:error, :uncertain}
  end
end

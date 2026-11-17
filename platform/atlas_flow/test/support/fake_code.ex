defmodule AtlasFlow.FakeCode do
  @moduledoc """
  A fake `AtlasFlow.Code.Client` for Flow's task tests: every `base` call is recorded,
  and by default answered `{:ok, snapshot_id}` with `id/1` of its input, as Code answers
  the same revision with the same snapshot ID. `script(answers)` overrides the next
  answers, in order (then the default again): an outcome to give, or `:default`.
  """
  @behaviour AtlasFlow.Code.Client
  use Agent

  def start_link(_ \\ nil),
    do: Agent.start_link(fn -> %{script: [], calls: []} end, name: __MODULE__)

  @doc "The snapshot ID the fake gives `input`."
  def id(input),
    do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, JSON.encode!(input)), case: :lower)

  @doc "Every input asked so far, oldest first."
  def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

  def script(answers), do: Agent.update(__MODULE__, &%{&1 | script: answers})

  @impl true
  def base(input) do
    answer =
      Agent.get_and_update(__MODULE__, fn
        %{script: [next | rest]} = s -> {next, %{s | script: rest, calls: [input | s.calls]}}
        s -> {:default, %{s | calls: [input | s.calls]}}
      end)

    if answer == :default, do: {:ok, id(input)}, else: answer
  end
end

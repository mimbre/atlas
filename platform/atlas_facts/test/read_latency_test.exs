defmodule AtlasFacts.ReadLatencyTest do
  @moduledoc """
  How long the reads Control and Flow make in daily use take, without writes and while
  writes wait for rela (IS-Atlas-85). Each request to rela takes `@delay` ms, as one over
  the network does; a write makes 2 of them (the change, the read back). Not run by
  default: `mix test --only bench test/read_latency_test.exs`.
  """
  use ExUnit.Case, async: false
  alias AtlasBus.Envelope
  alias AtlasFacts.SlowRela
  @moduletag :tmp_dir
  @moduletag :bench
  @moduletag timeout: 120_000

  @facts 1_200
  @delay 30
  @seconds 4
  @readers 4
  @writers 2

  # What Control and Flow read, as they read it (AtlasControl.PageReads, AtlasFlow.Talk).
  defp reads(i) do
    key = rem(i, div(@facts, 6)) + 1

    [
      {"control page", "_page",
       %{
         "reads" => [
           ["box", %{"key" => "box-#{key}"}],
           ["jar", %{"linked" => %{"in_box" => "box-#{key}"}}],
           ["bead", %{}]
         ]
       }},
      {"flow fact, plain", "bead", %{"key" => "bead-#{key}", "plain" => true}},
      {"flow fact, progress", "jar", %{"key" => "jar-#{key}", "incoming" => false}},
      {"flow kind, plain", "jar", %{"plain" => true}},
      {"flow linked, plain", "bead", %{"linked" => %{"in_jar" => "jar-#{key}"}, "plain" => true}}
    ]
  end

  setup %{tmp_dir: dir} do
    Application.put_env(:atlas_bus, :store, "latency-#{System.unique_integer([:positive])}")
    rela = SlowRela.start(@facts, delay: @delay)

    start_supervised!(
      {AtlasFacts.Server, rela: {SlowRela, rela}, model: AtlasFacts.Counting, data_dir: dir}
    )

    %{rela: rela}
  end

  test "reads without writes, and while writes wait for rela" do
    quiet = measure(0)
    busy = measure(@writers)

    IO.puts(
      "\nRead latency in ms, #{@readers} readers, #{@facts} facts, rela #{@delay} ms per request:\n" <>
        "| read | p50 alone | p99 alone | p50 with writes | p99 with writes |\n" <>
        "|---|---|---|---|---|\n" <>
        Enum.map_join(quiet.reads, "\n", fn {name, alone} ->
          busy_ms = busy.reads[name]

          "| #{name} | #{p(alone, 50)} | #{p(alone, 99)} | #{p(busy_ms, 50)} | #{p(busy_ms, 99)} |"
        end) <>
        "\nWrites stored while reading: #{busy.writes} " <>
        "(p50 #{p(busy.write_ms, 50)} ms, p99 #{p(busy.write_ms, 99)} ms)"
    )

    # Reads under concurrent writes are well within a second.
    for {_name, ms} <- busy.reads, do: assert(p(ms, 99) < 1_000)
  end

  defp measure(writers) do
    stop = System.monotonic_time(:millisecond) + @seconds * 1_000

    writing =
      for w <- 1..writers//1 do
        Task.async(fn ->
          :ok = AtlasBus.attach("flow-writer-#{w}-#{System.unique_integer([:positive])}")
          write(w, stop, [])
        end)
      end

    reading =
      for r <- 1..@readers do
        Task.async(fn ->
          :ok =
            AtlasBus.attach("control/session-latency-#{r}-#{System.unique_integer([:positive])}")

          read(r, stop, %{})
        end)
      end

    reads =
      reading
      |> Task.await_many(60_000)
      |> Enum.reduce(%{}, &Map.merge(&1, &2, fn _, a, b -> a ++ b end))

    write_ms = writing |> Task.await_many(60_000) |> List.flatten()
    %{reads: reads, writes: length(write_ms), write_ms: write_ms}
  end

  defp read(i, stop, acc) do
    if System.monotonic_time(:millisecond) >= stop do
      acc
    else
      {name, kind, content} = Enum.at(reads(i), rem(i, 5))
      {ms, answer} = timed("read", kind, content)
      refute answer["error"], inspect(answer)
      read(i + 1, stop, Map.update(acc, name, [ms], &[ms | &1]))
    end
  end

  defp write(w, stop, acc) do
    if System.monotonic_time(:millisecond) >= stop do
      acc
    else
      key = "bead-#{w * 10 + rem(length(acc), 10) + 1}"
      content = %{"op" => "change", "key" => key, "values" => %{"phase" => "w#{length(acc)}"}}
      {ms, answer} = timed("fact", "bead", content)
      refute answer["reasons"], inspect(answer)
      write(w, stop, [ms | acc])
    end
  end

  defp timed(class, kind, content) do
    e = Envelope.new(class, kind)
    started = System.monotonic_time(:microsecond)
    :ok = AtlasBus.send(e, content)
    id = e.id
    assert_receive {:atlas_bus, %Envelope{id: ^id}, answer}, 30_000
    {(System.monotonic_time(:microsecond) - started) / 1_000, answer}
  end

  defp p(values, percentile) do
    sorted = Enum.sort(values)
    at = min(length(sorted) - 1, ceil(length(sorted) * percentile / 100) - 1)
    sorted |> Enum.at(max(at, 0)) |> Float.round(1)
  end
end

ExUnit.start()

defmodule AtlasLearn.Fixtures do
  @moduledoc "Recorded source data for Learn's tests: a window, Runtime turns, a Code home, ledger facts."
  @dir Path.expand("fixtures", __DIR__)

  def until, do: ~U[2026-11-11 06:00:00Z]
  def window, do: AtlasLearn.Window.ending(until(), 24)

  @doc "A read function answering Runtime's `turns` read from the recorded reply."
  def runtime_read do
    reply = @dir |> Path.join("runtime_turns.json") |> File.read!() |> JSON.decode!()
    fn "turns" -> {:ok, reply} end
  end

  @doc """
  A private copy of the recorded Code home, its record files dated as Code would have left
  them: the first review and its change two days ago, everything else in the window.
  """
  def code_home do
    home = scratch("code-home")
    File.cp_r!(Path.join(@dir, "code_home"), home)
    inside = DateTime.to_unix(~U[2026-11-10 12:00:00Z])
    outside = DateTime.to_unix(~U[2026-11-09 05:00:00Z])

    for file <- Path.wildcard(Path.join(home, "**/*.json")), do: File.touch!(file, inside)

    for file <- [
          "reviews/aaaaaaaa-0000-4000-8000-000000000001.json",
          "changes/11111111-1111-4111-8111-111111111111/request.json"
        ],
        do: File.touch!(Path.join(home, file), outside)

    home
  end

  @doc "A stand-in for the `atlas` client: answers recorded JSON and reports every call to `pid`."
  def atlas_client(pid \\ self()) do
    fn args ->
      send(pid, {:atlas, args})

      case args do
        ["list", _kind | _] -> {:ok, read_json("decisions/list.json")}
        ["get", key | _] -> {:ok, read_json("decisions/get-#{key}.json")}
      end
    end
  end

  def read_json(name), do: @dir |> Path.join(name) |> File.read!() |> JSON.decode!()

  @doc "A fresh folder under the system's temporary folder, removed after the test."
  def scratch(name) do
    dir =
      Path.join(System.tmp_dir!(), "atlas-learn-#{name}-#{System.unique_integer([:positive])}")

    File.rm_rf!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end

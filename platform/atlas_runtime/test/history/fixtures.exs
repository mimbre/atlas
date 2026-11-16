defmodule AtlasRuntime.HistoryFixtures do
  @moduledoc """
  A Runtime home for the history tests: saved turn records as the Service writes them, and
  work records as the work store persists them (`AtlasRuntimeModel.Work`, format version 1).
  """
  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc "A fresh, short home (socket paths must fit), read by `AtlasRuntime.History`."
  def home! do
    dir =
      Path.join(
        System.tmp_dir!(),
        "arh-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"
      )

    File.mkdir_p!(dir)
    previous = Application.get_env(:atlas_runtime, :runtime_home)
    Application.put_env(:atlas_runtime, :runtime_home, dir)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:atlas_runtime, :runtime_home, previous),
        else: Application.delete_env(:atlas_runtime, :runtime_home)

      File.rm_rf!(dir)
    end)

    dir
  end

  def id(n),
    do: "turn-" <> String.pad_leading(String.downcase(Integer.to_string(n, 16)), 16, "0")

  @doc "A saved turn record; `:none` leaves its folder without `turn.json`."
  def turn!(home, id, fields \\ %{})

  def turn!(home, id, :none), do: File.mkdir_p!(Path.join([home, "turns", id]))

  def turn!(home, id, fields) do
    folder = Path.join([home, "turns", id])
    File.mkdir_p!(folder)

    record =
      Map.merge(
        %{
          "id" => id,
          "worker_id" => "alpha",
          "state" => "finished",
          "backend" => "claude",
          "requested_model" => "claude-opus-4-1",
          "model" => "claude-sonnet-4-6",
          "session_id" => "session-" <> id,
          "started_at" => "2026-11-16T10:00:00.000000Z",
          "ended_at" => "2026-11-16T10:05:00.000000Z",
          # Private: never projected.
          "cwd" => "/private/workspace",
          "assignment" => "Secret instructions",
          "sandbox" => "workspace-write",
          "artifacts" => folder,
          "result" => "done",
          "questions_enabled" => false
        },
        fields
      )

    File.write!(Path.join(folder, "turn.json"), JSON.encode!(record))
  end

  @doc "A work record of `client` whose attempts ran `turns`, each `{turn_id, provenance}`."
  def work!(home, work_id, client, turns) do
    attempts =
      turns
      |> Enum.with_index(1)
      |> Enum.map(fn {{turn, provenance}, n} ->
        %{
          "attempt" => n,
          "state" => "completed",
          "timestamps" => %{"received_at" => "2026-11-16T09:59:00Z"},
          "slot" => "alpha",
          "turn_id" => turn,
          "quiescent" => true,
          "provenance" =>
            Map.merge(
              %{
                "executor_kind" => "agent",
                "provider" => "anthropic",
                "harness" => "claude",
                "runtime_build" => "test",
                "machine" => "test",
                "slot" => "alpha",
                "turn_id" => turn,
                "started_at" => "2026-11-16T10:00:00Z",
                "selection" => %{
                  "profile" => "default",
                  "policy_version" => 1,
                  "option" => %{
                    "provider" => "anthropic",
                    "harness" => "claude",
                    "model" => "claude-opus-4-1"
                  },
                  "reason" => "preferred",
                  "skipped" => []
                }
              },
              provenance
            )
        }
      end)

    record = %{
      "format_version" => 1,
      "work_id" => work_id,
      "client" => client,
      "idempotency_key" => work_id,
      "revision" => 1,
      "sequence" => 1,
      "request" => %{
        "title" => "t",
        "instructions" => "i",
        "profile" => "default",
        "cost_class" => "standard",
        "workspace" => %{"kind" => "folder", "path" => "/w", "permissions" => "read_only"}
      },
      "attempts" => attempts
    }

    File.mkdir_p!(Path.join(home, "work"))
    File.write!(Path.join([home, "work", work_id <> ".json"]), JSON.encode!(record))
  end

  @doc "Every regular file under the home, byte for byte; sockets are skipped."
  def files(dir) do
    Path.wildcard(Path.join(dir, "**"), match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(&{&1, File.read!(&1)})
  end
end

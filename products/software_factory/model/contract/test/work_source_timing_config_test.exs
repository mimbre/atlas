defmodule Model.WorkSourceTimingConfigTest do
  @moduledoc """
  pull-e2e D6: the core's `config/runtime.exs` takes a test environment's short lease
  timing from `flow.work_source` (`lease_ttl`, `poll_max`, `sweep_ms`, `resync_ms` into
  `config :atlas_flow, :work_source`), only the keys given and only for env `test`. Prod
  refuses them, so prod keeps Flow's defaults (`AtlasFlow.Dispatch`); `grace` is refused in
  either env. Flow keeps no result store (IS-Atlas-100): `config :atlas_flow, :results` is
  never set, and `result_cap` is no timing key any more.

  The first test that reads `runtime.exs`: each case writes a settings file and reads the
  file with `Config.Reader` as a node started by `bin/atlas-ops up` would (`ATLAS_ENV`,
  `ATLAS_ENV_FILE`, `ATLAS_ROOT`, restored after). Structure, not wording: a refusal is a
  raise of a settings file that reads once the one offending key is left out.
  """
  use ExUnit.Case, async: false

  @runtime Path.expand("../../../config/runtime.exs", __DIR__)
  @vars ~w(ATLAS_ENV ATLAS_ENV_FILE ATLAS_ROOT)
  @timing %{
    "lease_ttl" => 180,
    "poll_max" => 5,
    "sweep_ms" => 1_000,
    "resync_ms" => 5_000
  }

  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})
    dir = Path.join(System.tmp_dir!(), "ws-timing-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      for {var, value} <- saved,
          do: if(value, do: System.put_env(var, value), else: System.delete_env(var))

      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  # Everything runtime.exs reads unconditionally, plus a work source with no timing.
  defp settings(dir, source) do
    %{
      "rela" => %{"url" => "http://127.0.0.1:1"},
      "facts" => %{"data" => Path.join(dir, "facts")},
      "control" => %{"host" => "127.0.0.1", "port" => 1},
      "tui_user" => "someone",
      "flow" => %{
        "work_source" =>
          Map.merge(
            %{
              "port" => 4100,
              "credentials_env" => "ATLAS_WORK_SOURCE_CREDENTIALS"
            },
            source
          )
      }
    }
  end

  defp read(dir, env, settings) do
    file = Path.join(dir, "#{env}-#{System.unique_integer([:positive])}.json")
    File.write!(file, JSON.encode!(Map.put(settings, "env", env)))
    System.put_env("ATLAS_ENV", env)
    System.put_env("ATLAS_ENV_FILE", file)
    System.put_env("ATLAS_ROOT", dir)
    Config.Reader.read!(@runtime, env: :dev)[:atlas_flow]
  end

  defp work_source(flow), do: Enum.sort(Keyword.fetch!(flow, :work_source))

  # What runtime.exs configures for a work source with no timing keys.
  defp base, do: [port: 4100, credentials_env: "ATLAS_WORK_SOURCE_CREDENTIALS"]

  # The settings read without `key`, and raise with it.
  defp refused(dir, env, source, key) do
    assert is_list(read(dir, env, settings(dir, Map.delete(source, key))))
    assert_raise RuntimeError, fn -> read(dir, env, settings(dir, source)) end
  end

  test "a test environment's timing keys go to Flow's work source; no result store", %{dir: dir} do
    flow = read(dir, "test", settings(dir, @timing))

    assert work_source(flow) ==
             Enum.sort(base() ++ [lease_ttl: 180, poll_max: 5, sweep_ms: 1_000, resync_ms: 5_000])

    refute Keyword.has_key?(flow, :results)

    # A results folder left in a settings file is no setting: nothing reads it.
    old = read(dir, "test", settings(dir, %{"results" => Path.join(dir, "results")}))
    refute Keyword.has_key?(old, :results)
  end

  test "only the timing keys given are set", %{dir: dir} do
    for {key, value} <- @timing do
      flow = read(dir, "test", settings(dir, %{key => value}))
      atom = String.to_existing_atom(key)
      assert work_source(flow) == Enum.sort(base() ++ [{atom, value}])
    end
  end

  test "without timing keys nothing is set, in test and in prod: Flow's defaults hold",
       %{dir: dir} do
    for env <- ~w(test prod) do
      flow = read(dir, env, settings(dir, %{}))
      assert work_source(flow) == Enum.sort(base())
      refute Keyword.has_key?(flow, :results)
    end

    # Without a work source block, neither is configured at all.
    prod = read(dir, "prod", Map.delete(settings(dir, %{}), "flow"))
    refute Keyword.has_key?(prod, :work_source)
    refute Keyword.has_key?(prod, :results)
  end

  test "prod refuses every timing key", %{dir: dir} do
    for {key, value} <- @timing, do: refused(dir, "prod", %{key => value}, key)
  end

  test "grace is not settable, in test or in prod", %{dir: dir} do
    for env <- ~w(test prod), do: refused(dir, env, %{"grace" => 30}, "grace")
    # Also next to the timing keys a test environment may set, and at the prod value.
    refused(dir, "test", Map.put(@timing, "grace", 120), "grace")
  end

  test "a timing value must be a positive integer, and poll_max 1–25", %{dir: dir} do
    for value <- [1, 25] do
      flow = read(dir, "test", settings(dir, %{"poll_max" => value}))
      assert Keyword.fetch!(flow[:work_source], :poll_max) == value
    end

    for {key, value} <- [
          {"poll_max", 0},
          {"poll_max", 26},
          {"poll_max", "5"},
          {"lease_ttl", 0},
          {"lease_ttl", 1.5},
          {"sweep_ms", -1},
          {"resync_ms", nil}
        ],
        do: refused(dir, "test", %{key => value}, key)
  end
end

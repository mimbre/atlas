defmodule AtlasE2E.Pull.Prepare do
  @moduledoc """
  Compile once, before the timed run (Main's duration ruling): everything the run would
  otherwise build cold goes into a warm cache, `products/software_factory/e2e/_build/pull-e2e`
  (git-ignored, inside the checkout, so it goes with it):

  - `bin/pull-stub` (go, standard library) and `bin/atlas-runtime` (the Runtime CLI of this
    checkout, `main.repoRoot` set to it);
  - the core and the clients (`mix compile`, `MIX_ENV=dev`, as `AtlasE2E.Instance.compile/0`);
  - `runtime-build/`: the Runtime service's build exactly as `atlas-runtime service start` makes
    it. Each run's Runtime home starts from a copy (`AtlasE2E.Pull.Runtime.prepare/3`), so the
    CLI's own build in the timed run is a no-op.

  Every build is bounded and tethered (`AtlasE2E.Pull.Bench.bounded/3`). The measured times
  go to `<cache>/prepare.json`; the run prints them as the compile part, apart from the test
  part. A second `--prepare` on the same checkout rebuilds only what changed.
  """
  alias AtlasE2E.{Instance}
  alias AtlasE2E.Pull.{Bench, Runtime, Stub}

  @budgets %{stub: 120_000, cli: 180_000, compile: 900_000, service: 900_000}

  def default_cache,
    do: Path.join(Instance.root(), "products/software_factory/e2e/_build/pull-e2e")

  def stub(cache), do: Path.join(cache, "bin/pull-stub")
  def cli(cache), do: Path.join(cache, "bin/atlas-runtime")
  def service_build(cache), do: Path.join(cache, "runtime-build")

  @doc "Build everything into `cache`; returns the measured steps `[{name, ms}]`."
  def run(cache \\ default_cache()) do
    root = Instance.root()
    File.mkdir_p!(Path.join(cache, "bin"))
    started = Bench.now()
    IO.puts("pull-e2e prepare: compiling into #{cache} (before the timed run)")

    steps = [
      timed("pull-stub", fn -> Stub.build!(stub(cache), within: @budgets.stub) end),
      timed("atlas-runtime CLI", fn ->
        Runtime.build_cli!(cli(cache), root, within: @budgets.cli, stub: stub(cache))
      end),
      timed("core and clients (mix compile, dev)", fn -> compile(root, stub(cache)) end),
      timed("Runtime service build (MIX_ENV=test)", fn ->
        Runtime.build_service!(service_build(cache), root,
          within: @budgets.service,
          stub: stub(cache)
        )
      end)
    ]

    total = Bench.now() - started

    File.write!(
      Path.join(cache, "prepare.json"),
      JSON.encode!(%{
        steps: Enum.map(steps, fn {n, ms} -> %{name: n, ms: ms} end),
        total_ms: total
      })
    )

    IO.puts("pull-e2e prepare: done in #{Float.round(total / 1000, 1)} s")
    steps
  end

  defp timed(name, fun) do
    started = Bench.now()
    fun.()
    ms = Bench.now() - started
    IO.puts("  ✓ #{name} (#{Float.round(ms / 1000, 1)} s)")
    {name, ms}
  end

  # As Instance.compile/0, each project bounded.
  defp compile(root, stub) do
    deadline = Bench.now() + @budgets.compile

    for dir <- ["products/software_factory", "platform/clients/tui", "platform/clients/agent"] do
      case Bench.bounded("mix", ["compile"],
             cd: Path.join(root, dir),
             env: [{"MIX_ENV", "dev"}],
             deadline: deadline,
             stub: stub
           ) do
        {_, 0} -> :ok
        {out, status} -> raise "#{dir} does not compile (#{inspect(status)}):\n#{out}"
      end
    end
  end

  @doc "The measured compile steps of the last prepare (`[]` when there is none)."
  def measured(cache) do
    case File.read(Path.join(cache, "prepare.json")) do
      {:ok, text} -> JSON.decode!(text)
      _ -> %{"steps" => [], "total_ms" => nil}
    end
  end

  @doc "Raise unless `cache` holds what the run takes from it."
  def ready!(cache) do
    for file <- [stub(cache), cli(cache), service_build(cache)],
        not File.exists?(file),
        do:
          raise(
            "pull-e2e: #{file} is missing; run `mix atlas.pull_e2e --prepare` first (pull/run.sh does)"
          )

    :ok
  end
end

defmodule Mix.Tasks.Atlas.E2e do
  @shortdoc "The end-to-end test: a private rela, the core and two TUIs"
  @moduledoc """
      mix atlas.e2e                 # every scenario in e2e/scenarios, in order
      mix atlas.e2e uc-atlas-22     # only the scenarios whose file name has this

  Also `bin/atlas-dev e2e`. Starts a private instance (fresh rela data, free ports; see
  `AtlasE2E.Instance`), the core, and two TUIs in tmux, then runs the scenarios. When a
  step fails it saves both screens and the logs in `e2e/artifacts/` (or
  `ATLAS_E2E_ARTIFACTS`) and exits with an error. Needs tmux.
  """
  use Mix.Task

  alias AtlasE2E.{Instance, Tui}

  @scenarios Path.expand("../../../scenarios", __DIR__)

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    # rela_get and the stand-ins use :httpc, which needs a CA store even for http.
    _ = AtlasFacts.Trust.load()
    started = System.monotonic_time(:millisecond)
    scenarios = load(args)

    artifacts =
      System.get_env("ATLAS_E2E_ARTIFACTS") || Path.join(Instance.root(), "e2e/artifacts")

    File.rm_rf!(artifacts)

    compile()
    IO.puts("atlas e2e: starting a private rela and the core…")
    instance = Instance.start()
    socket = "atlas-e2e-#{System.os_time(:millisecond)}"

    # The TUIs' user exists before they start, as in test and prod: a session knows from its
    # first page that its user is a person, so `/` is their start page throughout and never
    # turns from the plan into it halfway through a scenario (IS-Atlas-55). It is also the
    # decider the settings name (`actors.decider`); what it is to own waits for it till now.
    {_, 0, _} = AtlasE2E.Scenario.atlas(instance, ["put", "person", "--name", "Melle"])

    IO.puts(
      "atlas e2e: rela on #{instance.settings["rela"]["port"]}, Control on " <>
        "#{instance.settings["control"]["port"]}, build #{build()}"
    )

    result =
      try do
        t1 = Tui.start(instance, socket, "tui1", "TUI 1")
        t2 = Tui.start(instance, socket, "tui2", "TUI 2")

        for t <- [t1, t2], do: AtlasE2E.Scenario.ready(t, 120_000)
        for t <- [t1, t2], do: AtlasE2E.Scenario.see(t, "Atlas Console · test")
        settle_disk()

        Enum.reduce_while(scenarios, :ok, fn {file, scenario}, :ok ->
          IO.puts("\n#{scenario.title}  (#{Path.relative_to(file, Instance.root())})")

          try do
            for t <- [t1, t2], do: AtlasE2E.Scenario.home(t)
            scenario.fun.(%{t1: t1, t2: t2, instance: instance})
            {:cont, :ok}
          rescue
            error ->
              keep(artifacts, file, [t1, t2], instance, error, __STACKTRACE__)
              {:halt, {:error, scenario.title}}
          end
        end)
      after
        Tui.kill_server(socket)
        Instance.stop(instance)
      end

    took = Float.round((System.monotonic_time(:millisecond) - started) / 1000, 1)
    steps = Process.get(:e2e_steps) || 0

    case result do
      :ok ->
        File.rm_rf!(instance.dir)

        IO.puts(
          "\natlas e2e: #{length(scenarios)} scenarios, #{steps} steps, all passed in #{took} s"
        )

      {:error, title} ->
        Mix.raise(
          "atlas e2e: #{title} failed after #{steps} passed steps (#{took} s); " <>
            "screens and logs in #{Path.relative_to(artifacts, Instance.root())}"
        )
    end
  end

  defp load(args) do
    files = Path.wildcard(Path.join(@scenarios, "*.exs")) |> Enum.sort()

    files =
      if args == [],
        do: files,
        else:
          Enum.filter(files, fn f -> Enum.any?(args, &String.contains?(Path.basename(f), &1)) end)

    if files == [], do: Mix.raise("atlas e2e: no scenario matches #{Enum.join(args, " ")}")

    for file <- files do
      {scenario, _} = Code.eval_file(file)
      {file, scenario}
    end
  end

  # Compile first, so starting the core or a TUI never waits for a compile.
  defp compile do
    Instance.compile()
  rescue
    error in RuntimeError -> Mix.raise("atlas e2e: " <> Exception.message(error))
  end

  # Write out what the machine still holds for the disk (on a CI runner: hundreds of MB from
  # installing and compiling just before) before the first step is timed. The kernel writes
  # it out ~30 s later otherwise, and while it does, a file write waits for the disk: rela's
  # write of a fact, Facts' sync. CI measured one rela request at 836 ms in that window, and
  # a step missed its second (IS-Atlas-80).
  defp settle_disk do
    {_, 0} = System.cmd("sync", [])
    :ok
  end

  defp keep(artifacts, file, tuis, instance, error, stacktrace) do
    dir = Path.join(artifacts, Path.basename(file, ".exs"))
    File.mkdir_p!(dir)
    step = Process.get(:e2e_step) || "start"

    for t <- tuis do
      File.write!(Path.join(dir, "#{t.name}.txt"), "#{step}\n\n" <> Tui.screen(t))
    end

    for log <- Instance.logs(instance), do: File.cp!(log, Path.join(dir, Path.basename(log)))
    File.write!(Path.join(dir, "error.txt"), Exception.format(:error, error, stacktrace))
  end

  defp build do
    case System.cmd("git", ["-C", Instance.root(), "rev-parse", "--short", "HEAD"]) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  end
end

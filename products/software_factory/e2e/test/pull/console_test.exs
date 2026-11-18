defmodule AtlasE2E.Pull.ConsoleTest do
  @moduledoc """
  Gatefix round 2: where the TUI shows an issue to pick up. The bench found the tab bar and
  its tabs from the product's generated shell (the one Control boots), and reads which one is
  active from the screen. Structure only: tabs are found by their page, never by words.
  """
  use ExUnit.Case, async: true

  alias AtlasE2E.Pull.{Bench, Console}

  # The tab bar of LC3's failing run (develop 897c0125 + F10): the TUI opened on the shell's
  # default tab, Assigned to you, which listed nothing.
  @lc3_screen """
   Atlas Console · test · 0 assigned to you
  ┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
  │   Open for you    Supervised by you  ▸ Assigned to you    Scenes    Open work                    │
  └──────────────────────────────────────────────────────────────────────────────────────────────────┘
   Overview
  """

  defp by_to(to), do: Enum.find(Console.tabs(), &(&1["to"] == to))

  test "the product's shell has a tab for Open for you and for Supervised by you" do
    for to <- ["/_open", "/_supervised"] do
      assert %{"label" => label} = by_to(to)
      assert Console.tab_label(to) == label
    end

    assert_raise RuntimeError, fn -> Console.tab_label("/k/nothing") end
  end

  test "the tab a client opens on is Assigned to you, not where an unsupervised issue is" do
    shell = Console.tabs()
    [assigned] = Enum.filter(shell, &(&1["assigned"] == true))
    refute assigned["to"] in ["/_open", "/_supervised"]
  end

  test "the active tab is read from the bar that shows every tab" do
    tabs = Console.tabs()
    assigned = Enum.find(tabs, &(&1["assigned"] == true))["label"]
    open = Console.tab_label("/_open")

    assert Console.active_tab(@lc3_screen, tabs) == assigned

    moved =
      @lc3_screen
      |> String.replace("▸ " <> assigned, "  " <> assigned)
      |> String.replace("   " <> open, " ▸ " <> open)

    assert Console.active_tab(moved, tabs) == open

    # A folded block's ▸ outside the bar is not a tab; a screen with no bar has none.
    folded = String.replace(@lc3_screen, " Overview", " ▸ " <> open)
    assert Console.active_tab(folded, tabs) == assigned
    assert Console.active_tab(" Loading…\n", tabs) == nil
  end

  # pull-e2e-confirmkey: LC3's s5 sent Ctrl+S to the pick-up confirm, which binds submit to
  # Enter/y only (AtlasControl.Console `confirmation/1`), so the TUI ignored it and the step
  # waited out its cap. Each dialog kind submits with the key Control declares for it.
  test "a dialog submits with the key Control declares for its kind" do
    assert Console.submit_key(:confirm) == "Enter"
    assert Console.submit_key(:form) == "C-s"
    refute Console.submit_key(:confirm) == Console.submit_key(:form)
    assert_raise KeyError, fn -> Console.submit_key(:browse) end
  end

  describe "the kept artifacts" do
    setup do
      root = Path.join(System.tmp_dir!(), "pe-keep-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(root) end)
      %{run: Path.join(root, "run"), artifacts: Path.join(root, "artifacts")}
    end

    defp put(run, rel) do
      file = Path.join(run, rel)
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, rel)
    end

    test "core.log, rela's log and service.log are copied before the run folder goes", ctx do
      for rel <- ~w(inst/core.log inst/rela-server.log rt/rt/h/service.log events/wire.jsonl),
          do: put(ctx.run, rel)

      put(ctx.run, "inst/nested/flow.log")

      dir = Bench.keep(ctx.run, ctx.artifacts, "s5", "boom\n")
      File.rm_rf!(ctx.run)

      kept = File.ls!(dir)

      for name <-
            ~w(inst_core.log inst_rela-server.log rt_rt_h_service.log events_wire.jsonl inst_nested_flow.log error.txt),
          do: assert(name in kept, name)

      assert File.read!(Path.join(dir, "inst_core.log")) == "inst/core.log"
      assert Bench.missing_logs(kept) == []
    end

    test "a missing log is named, one entry per log", ctx do
      put(ctx.run, "inst/core.log")
      dir = Bench.keep(ctx.run, ctx.artifacts, "setup", "early\n")
      assert length(Bench.missing_logs(File.ls!(dir))) == 2
      assert Bench.missing_logs([]) |> length() == 3
    end
  end
end

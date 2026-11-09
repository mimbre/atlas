defmodule AtlasFlow.Composition.LinksTest do
  use ExUnit.Case, async: true
  alias AtlasFlow.Composition.Links

  # The neutral yard's link: a cup's outcome, from the cup poured for the tray's revision.
  @link hd(AtlasFlow.Yard.composition()["links"])
  @plain Map.merge(@link, %{"stale" => "keep", "current" => nil})

  defp tray(revision \\ "r1"), do: %{"key" => "T-1", "values" => %{"revision" => revision}}
  defp cup(key, revision \\ "r1"), do: %{"key" => key, "values" => %{"revision" => revision}}

  defp run(key, state, entry \\ 2),
    do: %{"flow" => "pour", "key" => "run-#{key}", "state" => state, "entry" => entry}

  defp source(key, state \\ "full", entry \\ 2, current \\ "r1"),
    do: %{
      "child" => key,
      "run" => "run-#{key}",
      "entry" => entry,
      "state" => state,
      "current" => current
    }

  test "only stale: drop with an explicit current identity is applied" do
    assert Links.valid?(@link) == :ok
    assert Links.valid?(@plain) == :ok
    assert Links.valid?(Map.put(@link, "current", nil)) == {:error, :stale_without_current}
    assert Links.valid?(Map.delete(@link, "current")) == {:error, :stale_without_current}

    assert Links.valid?(Map.put(@link, "current", %{"child" => "revision"})) ==
             {:error, :invalid_current}

    assert Links.valid?(Map.put(@link, "states", %{})) == {:error, :invalid_link}
  end

  test "the current child's completion is written once, with its source" do
    runs = %{"C-1" => run("C-1", "full")}
    assert {:write, "full", s} = Links.select(@link, tray(), [cup("C-1")], runs, nil)
    assert s == source("C-1")

    # A duplicate completion (the same run and entry) is applied already.
    assert {:applied, ^s} = Links.select(@link, tray(), [cup("C-1")], runs, s)

    # The same child completing again, in a later entry, is a new source.
    again = %{"C-1" => run("C-1", "spilt", 3)}
    assert {:write, "spilt", s3} = Links.select(@link, tray(), [cup("C-1")], again, s)
    assert s3 == source("C-1", "spilt", 3)
  end

  test "a replaced child that completes late writes nothing; the current one does" do
    children = [cup("C-1", "r1"), cup("C-2", "r2")]
    late = %{"C-1" => run("C-1", "full"), "C-2" => run("C-2", "pouring", 1)}
    assert Links.select(@link, tray("r2"), children, late, nil) == :waiting

    done = Map.put(late, "C-2", run("C-2", "spilt"))

    assert {:write, "spilt", %{"child" => "C-2", "current" => "r2"}} =
             Links.select(@link, tray("r2"), children, done, nil)
  end

  test "selection is by identity, never by time; more than one current child is refused" do
    children = [cup("C-2"), cup("C-1")]
    runs = %{"C-1" => run("C-1", "full"), "C-2" => run("C-2", "spilt")}

    assert Links.select(@link, tray(), children, runs, nil) ==
             {:refused, :ambiguous, ["C-1", "C-2"]}

    # Without a current identity every child is current: two are ambiguous, one is not.
    assert {:refused, :ambiguous, _} = Links.select(@plain, tray(), children, runs, nil)
    assert {:write, "full", _} = Links.select(@plain, tray(), [cup("C-1")], runs, nil)
  end

  test "no child, a parent without its identity, or a run elsewhere: nothing to write" do
    assert Links.select(@link, tray(), [], %{}, nil) == :none
    assert Links.select(@link, tray(nil), [cup("C-1")], %{}, nil) == :waiting
    assert Links.select(@link, tray(""), [cup("C-1")], %{}, nil) == :waiting
    assert Links.select(@link, tray(), [cup("C-1")], %{}, nil) == :waiting
    assert Links.select(@link, tray(), [cup("C-1", "r0")], %{}, nil) == :none

    other = %{"C-1" => Map.put(run("C-1", "full"), "flow", "other")}
    assert Links.select(@link, tray(), [cup("C-1")], other, nil) == :waiting
  end
end

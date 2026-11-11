defmodule AtlasAgent.CLITest do
  # ATLAS_ENV_FILE is global: one test at a time.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  alias AtlasAgent.FakeControl

  @kinds [
    %{
      kind: "widget",
      title: "Widget",
      prefix: "WI-",
      asks: ~w(title description),
      list_title: "Widgets"
    },
    %{
      kind: "part",
      title: "Part",
      prefix: "PA-",
      under: "widget",
      asks: ~w(title description stage),
      links: ~w(follows),
      list_title: "Parts"
    }
  ]

  setup do
    control = FakeControl.start(@kinds)
    FakeControl.use_env_file(control)
    %{control: control}
  end

  # Runs `atlas <args>`: {status, stdout, stderr}.
  defp atlas(args) do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        stdout =
          capture_io(fn ->
            send(parent, {:status, AtlasAgent.CLI.main(args ++ ["--env", "test"])})
          end)

        send(parent, {:stdout, stdout})
      end)

    assert_received {:status, status}
    assert_received {:stdout, stdout}
    {status, stdout, stderr}
  end

  test "help: the kinds from Control under its heading" do
    {0, out, ""} = atlas(["help"])
    assert out =~ ~r/^Kinds \(from rela's description, through Control\):\n\nWidget \(widget\)\n/
    assert out =~ "Part (part)\n"
    assert out =~ "  Belongs under: widget"
    assert out =~ "  Create asks: title, description\n"
  end

  test "help of a kind Atlas does not have: exit 2, naming the kinds it has" do
    {2, "", err} = atlas(["help", "nothing"])
    assert err =~ ~s|Atlas has no kind "nothing"; it has widget, part|
  end

  test "get: the title, its fields, and what hangs under it, as text", %{control: c} do
    widget =
      FakeControl.put(c, "widget", %{
        "title" => "A widget to read",
        "description" => "Two lines\nof text"
      })

    FakeControl.put(c, "part", %{"title" => "A part to read", "stage" => "Refine"}, widget)

    {0, out, ""} = atlas(["get", widget])

    assert out ==
             """
             Widget WI-01: A widget to read
               Title: A widget to read
               Description:
                 Two lines
                 of text
             Parts:
               PA-01  A part to read  Refine
             """
  end

  test "get --json keeps the newlines of a value", %{control: c} do
    widget =
      FakeControl.put(c, "widget", %{"title" => "A widget", "description" => "Two lines\nof text"})

    {0, out, ""} = atlas(["get", widget, "--json"])
    item = JSON.decode!(out)
    assert item["values"]["description"] == "Two lines\nof text"
    assert ["Description", "Two lines\nof text"] in item["fields"]
  end

  test "get of a key that is not there: exit 2, the error names the key" do
    {2, "", err} = atlas(["get", "WI-99"])
    assert err =~ "atlas: "
    assert err =~ "WI-99"

    {2, out, _} = atlas(["get", "WI-99", "--json"])
    assert JSON.decode!(out)["error"] =~ "WI-99"
  end

  test "list: rows as key, label and detail columns; --in only what hangs under it", %{control: c} do
    one = FakeControl.put(c, "widget", %{"title" => "One"})
    two = FakeControl.put(c, "widget", %{"title" => "Two"})
    FakeControl.put(c, "part", %{"title" => "A part to read", "stage" => "Refine"}, one)
    FakeControl.put(c, "part", %{"title" => "Elsewhere"}, two)

    assert {0, "PA-01  A part to read  Refine\n", ""} =
             atlas(["list", "part", "--in", one])

    {0, out, ""} = atlas(["list", "widget", "--json"])

    assert Enum.map(JSON.decode!(out), &{&1["key"], &1["label"]}) == [
             {"WI-01", "One"},
             {"WI-02", "Two"}
           ]

    # Keys padded to one column; a row without a detail has no trailing spaces.
    {0, out, ""} = atlas(["list", "part"])
    assert out == "PA-01  A part to read  Refine\nPA-02  Elsewhere\n"
  end

  test "list --in a key that is not there: exit 2" do
    {2, "", err} = atlas(["list", "part", "--in", "WI-99"])
    assert err =~ "WI-99"
  end

  test "put --link: makes the fact, then links it through the association, in one command",
       %{control: c} do
    widget = FakeControl.put(c, "widget", %{"title" => "W"})
    first = FakeControl.put(c, "part", %{"title" => "First"}, widget)

    {0, out, ""} =
      atlas(["put", "part", "--in", widget, "--title", "Second", "--link", "follows=#{first}"])

    assert out =~ "Part PA-02: Second"
    assert FakeControl.fact(c, "PA-02").links == %{"follows" => [first]}

    # The fields go in the create, the link only through its own form, after it.
    assert [%{"endpoint" => "create", "values" => values}, %{"endpoint" => "link"}] =
             FakeControl.writes(c)

    assert values == %{"title" => "Second"}
  end

  test "put --link that is refused: exit 1, the fact stays made and the refusal names it" do
    refuse = fn
      %{"endpoint" => "link"} -> ["no such part"]
      _ -> nil
    end

    control = FakeControl.start(@kinds, refuse: refuse)
    FakeControl.use_env_file(control)
    widget = FakeControl.put(control, "widget", %{"title" => "W"})

    {1, out, err} =
      atlas(["put", "part", "--in", widget, "--title", "T", "--link", "follows=PA-9", "--json"])

    assert JSON.decode!(out)["refused"] == ["PA-01 is made, but not linked", "no such part"]
    assert err =~ "PA-01 is made, but not linked"
    assert FakeControl.fact(control, "PA-01").values == %{"title" => "T"}
  end

  test "put --link without an association=key: exit 2, nothing written", %{control: c} do
    {2, _, err} = atlas(["put", "widget", "--title", "T", "--link", "follows"])
    assert err =~ "--link <association>=<key>"
    assert FakeControl.writes(c) == []
  end
end

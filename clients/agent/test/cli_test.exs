defmodule AtlasAgent.CLITest do
  # ATLAS_ENV_FILE is global: one test at a time.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  alias AtlasAgent.FakeControl

  @kinds [
    %{
      kind: "scene",
      title: "Scene",
      prefix: "SC-",
      asks: ~w(title description),
      list_title: "Scenes"
    },
    %{
      kind: "use_case",
      title: "Use case",
      prefix: "UC-",
      under: "scene",
      asks: ~w(title description stage),
      list_title: "Use cases"
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
    assert out =~ ~r/^Kinds \(from rela's description, through Control\):\n\nScene \(scene\)\n/
    assert out =~ "Use case (use_case)\n"
    assert out =~ "  Belongs under: scene"
    assert out =~ "  Create asks: title, description\n"
  end

  test "help of a kind Atlas does not have: exit 2, naming the kinds it has" do
    {2, "", err} = atlas(["help", "nothing"])
    assert err =~ ~s|Atlas has no kind "nothing"; it has scene, use_case|
  end

  test "get: the title, its fields, and what hangs under it, as text", %{control: c} do
    scene =
      FakeControl.put(c, "scene", %{
        "title" => "A scene to read",
        "description" => "Two lines\nof text"
      })

    FakeControl.put(c, "use_case", %{"title" => "A use case to read", "stage" => "Refine"}, scene)

    {0, out, ""} = atlas(["get", scene])

    assert out ==
             """
             Scene SC-01: A scene to read
               Title: A scene to read
               Description:
                 Two lines
                 of text
             Use cases:
               UC-01  A use case to read  Refine
             """
  end

  test "get --json keeps the newlines of a value", %{control: c} do
    scene =
      FakeControl.put(c, "scene", %{"title" => "A scene", "description" => "Two lines\nof text"})

    {0, out, ""} = atlas(["get", scene, "--json"])
    item = JSON.decode!(out)
    assert item["values"]["description"] == "Two lines\nof text"
    assert ["Description", "Two lines\nof text"] in item["fields"]
  end

  test "get of a key that is not there: exit 2, the error names the key" do
    {2, "", err} = atlas(["get", "SC-99"])
    assert err =~ "atlas: "
    assert err =~ "SC-99"

    {2, out, _} = atlas(["get", "SC-99", "--json"])
    assert JSON.decode!(out)["error"] =~ "SC-99"
  end

  test "list: rows as key, label and detail columns; --in only what hangs under it", %{control: c} do
    one = FakeControl.put(c, "scene", %{"title" => "One"})
    two = FakeControl.put(c, "scene", %{"title" => "Two"})
    FakeControl.put(c, "use_case", %{"title" => "A use case to read", "stage" => "Refine"}, one)
    FakeControl.put(c, "use_case", %{"title" => "Elsewhere"}, two)

    assert {0, "UC-01  A use case to read  Refine\n", ""} =
             atlas(["list", "use_case", "--in", one])

    {0, out, ""} = atlas(["list", "scene", "--json"])

    assert Enum.map(JSON.decode!(out), &{&1["key"], &1["label"]}) == [
             {"SC-01", "One"},
             {"SC-02", "Two"}
           ]

    # Keys padded to one column; a row without a detail has no trailing spaces.
    {0, out, ""} = atlas(["list", "use_case"])
    assert out == "UC-01  A use case to read  Refine\nUC-02  Elsewhere\n"
  end

  test "list --in a key that is not there: exit 2" do
    {2, "", err} = atlas(["list", "use_case", "--in", "SC-99"])
    assert err =~ "SC-99"
  end
end

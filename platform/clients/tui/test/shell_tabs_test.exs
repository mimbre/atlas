defmodule AtlasTui.ShellTabsTest do
  # The boot boundary between Control's shell (`AtlasControl.Shell.boot/4`) and the TUI's
  # check of it: every index page Control serves as a tab is one the TUI takes, and the
  # shell the product ships boots. A tab Control serves that the TUI refuses leaves the
  # Console on "Waiting for Console boot…" for good (pull-e2e on develop b4fd03e5).
  use ExUnit.Case, async: true
  alias AtlasTui.{Console, Model, Protocol}

  # The product's generated description (read only): the shell its Control serves.
  @product Path.expand(
             "../../../../products/software_factory/model/targets/rela/atlas.json",
             __DIR__
           )
  @external_resource @product

  # The routes `AtlasControl.Shell` lets a tab open, one path each.
  @tab_paths ["/", "/k/widget", "/workers", "/_open", "/_supervised"]

  defp handshake do
    model = %{Model.new("test") | console: Console.new()}

    {model, []} =
      Console.receive(model, %{
        "op" => "welcome",
        "env" => "test",
        "spec" => Protocol.version(),
        "surface" => "console"
      })

    {model, [{:send, %{"op" => "boot"}}]} =
      Console.receive(model, %{"op" => "page", "path" => "/", "blocks" => []})

    model
  end

  # A boot as `AtlasControl.Shell.boot/4` makes it: tabs carry id, label and to only.
  defp boot(tabs, initial_to) do
    tabs = Enum.map(tabs, &Map.take(&1, ~w(id label to)))

    %{
      "op" => "boot",
      "title" => "Atlas Console",
      "env" => "test",
      "spec" => Protocol.version(),
      "revision" => String.duplicate("a", 64),
      "tabs" => tabs,
      "initial_to" => initial_to,
      "active_tab" => Enum.find_value(tabs, &(&1["to"] == initial_to && &1["id"]))
    }
  end

  defp accepted(model, boot) do
    {booted, effects} = Console.receive(model, boot)
    assert effects == [{:send, Protocol.request(:open, %{"to" => boot["initial_to"]})}]
    assert booted.console.shell["tabs"] == boot["tabs"]
    refute booted.console.stale
    assert booted.console.phase == :content
  end

  defp refused(model, boot) do
    {refused, effects} = Console.receive(model, boot)
    assert effects == []
    assert refused.console.shell == nil
    assert refused.console.stale
  end

  test "every index page Control serves as a tab boots, alone and opened first" do
    tabs =
      for {to, i} <- Enum.with_index(@tab_paths),
          do: %{"id" => "t#{i}", "label" => "T#{i}", "to" => to}

    for tab <- tabs do
      accepted(handshake(), boot([tab], tab["to"]))
      accepted(handshake(), boot(tabs, tab["to"]))
    end
  end

  test "a page Control never serves as a tab is still refused" do
    for to <- ["/k/widget/W1", "/k/widget/new", "/_kinds", "/workers/m/w/t/a", "/faults"] do
      tabs = [
        %{"id" => "x", "label" => "X", "to" => to},
        %{"id" => "w", "label" => "W", "to" => "/workers"}
      ]

      refused(handshake(), boot(tabs, "/workers"))
    end
  end

  test "the shell the product ships boots, with and without its assigned tab" do
    shell = @product |> File.read!() |> JSON.decode!() |> Map.fetch!("shell")
    tabs = Map.fetch!(shell, "tabs")
    assert tabs != []
    default = Enum.find(tabs, &(&1["id"] == shell["default"])) || hd(tabs)

    # Control leaves `assigned` tabs out for a client the start page assigns nothing to.
    for shown <- [tabs, Enum.reject(tabs, &(&1["assigned"] == true))], shown != [] do
      initial = if default in shown, do: default["to"], else: hd(shown)["to"]
      accepted(handshake(), boot(shown, initial))
    end
  end
end

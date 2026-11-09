defmodule AtlasControl.ConsoleTest do
  use ExUnit.Case, async: false
  alias AtlasControl.FakeStore
  alias AtlasBFFContract.Console

  defmodule Protocol do
    use AtlasBFF.Targets.Protocol, contract: AtlasBFFContract.Contract, channel: :control
  end

  setup do
    Application.put_env(:atlas_bus, :store, "console-#{System.unique_integer([:positive])}")
    AtlasBus.drop_hints(0)
    start_supervised!(FakeStore)

    FakeStore.describe(
      Map.put(FakeStore.description(), "shell", %{
        "title" => "Private Console",
        "tabs" => [
          %{"id" => "widgets", "label" => "Widgets", "to" => "/k/widget"},
          %{"id" => "parts", "label" => "Parts", "to" => "/k/part"}
        ]
      })
    )

    start_supervised!({AtlasControl.Gateway, port: 0, name: :console_gateway})

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasControl.Sessions),
          do: DynamicSupervisor.terminate_child(AtlasControl.Sessions, pid)
    end)

    %{port: AtlasControl.Gateway.port(:console_gateway)}
  end

  defp connect(port, extra \\ %{}) do
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", port, [
        :binary,
        packet: :line,
        active: false,
        buffer: 4_194_304
      ])

    on_exit(fn -> :gen_tcp.close(socket) end)

    put(
      socket,
      Map.merge(
        %{
          "op" => "hello",
          "env" => "test",
          "client" => "tui",
          "spec" => AtlasControl.Blocks.version()
        },
        extra
      )
    )

    socket
  end

  defp put(s, message), do: :gen_tcp.send(s, [JSON.encode!(message), "\n"])

  defp read(s) do
    {:ok, line} = :gen_tcp.recv(s, 0, 2_000)
    JSON.decode!(line)
  end

  defp actions(page), do: Enum.filter(page["blocks"], &(&1["type"] == "console_action"))

  defp page(s), do: Stream.repeatedly(fn -> read(s) end) |> Enum.find(&(&1["op"] == "page"))

  defp console(port) do
    s = connect(port, %{"surface" => "console"})
    assert %{"op" => "welcome", "surface" => "console"} = read(s)
    assert %{"op" => "page"} = read(s)
    s
  end

  test "acknowledged Console has real typed projection; legacy body stays unchanged", %{
    port: port
  } do
    old = connect(port)
    assert %{"op" => "welcome"} = welcome = read(old)
    refute Map.has_key?(welcome, "surface")
    native = read(old)
    assert actions(native) == []
    refute Map.has_key?(native, "actions_revision")
    s = connect(port, %{"surface" => "console"})
    assert %{"op" => "welcome", "surface" => "console"} = read(s)
    page = read(s)
    assert Enum.reject(page["blocks"], &(&1["type"] == "console_action")) == native["blocks"]
    assert actions(page) != []

    for a <- actions(page) do
      p = a["props"]
      assert p["scope"]["revision"] == page["actions_revision"]
      assert p["scope"]["page"] == page["path"]
      assert AtlasBFFContract.Console.operation?(p["operation"])
      assert Enum.all?(p["keys"], &AtlasBFFContract.Console.key?/1)
    end

    assert Enum.any?(
             actions(page),
             &(&1["props"]["operation"] == %{"name" => "tab_next"} and
                 &1["props"]["keys"] == ["Tab"])
           )

    assert :ok = AtlasBFF.Markup.check(Enum.map(page["blocks"], & &1["id"]), page["markup"])
    put(s, %{"op" => "refresh"})
    refreshed = read(s)
    refute refreshed["actions_revision"] == page["actions_revision"]
    assert Enum.map(actions(refreshed), & &1["id"]) == Enum.map(actions(page), & &1["id"])
  end

  test "surface does not change actor or native boot", %{port: port} do
    old = connect(port)
    read(old)
    read(old)
    new = connect(port, %{"surface" => "console"})
    read(new)
    read(new)
    for s <- [old, new], do: put(s, %{"op" => "boot"})
    assert read(old) == read(new)
    assert FakeStore.sent() == []
  end

  test "unsupported surface, environment and version refuse before acknowledgement", %{port: port} do
    for extra <- [
          %{"surface" => "ios"},
          %{"surface" => "console", "env" => "prod"},
          %{"surface" => "console", "spec" => "0.1.0"}
        ] do
      s = connect(port, extra)
      assert %{"op" => "bye"} = read(s)
      assert {:error, :closed} = :gen_tcp.recv(s, 0, 500)
    end
  end

  test "form projection reuses its ordinary typed submit and keeps literal question marks", %{
    port: port
  } do
    s = connect(port, %{"surface" => "console"})
    read(s)
    read(s)
    put(s, %{"op" => "open", "to" => "/k/widget/new"})
    page = read(s)
    form = Enum.find(page["blocks"], &(&1["type"] == "form"))

    assert Enum.any?(actions(page), fn a ->
             p = a["props"]

             p["operation"] == %{"name" => "submit"} and p["scope"]["on"] == form["id"] and
               p["keys"] == ["Ctrl+S"]
           end)

    refute Enum.any?(actions(page), fn a ->
             a["props"]["scope"]["context"] == "form" and "?" in a["props"]["keys"]
           end)

    assert FakeStore.sent() == []
  end

  test "browse page binds Tab to the next tab under a browse legend", %{port: port} do
    s = console(port)
    put(s, %{"op" => "open", "to" => "/k/widget"})
    p = page(s)
    assert {:ok, projection} = Console.compile(p)
    current = %{path: p["path"], context: "browse", generation: 1}
    assert {:ok, bindings} = Console.bindings(projection, current)
    assert bindings["Tab"]["props"]["operation"] == %{"name" => "tab_next"}
    assert {:ok, event} = Console.capture(projection, "Tab", current)
    assert {:ok, action} = Console.resolve(projection, event, current)
    assert action["id"] == bindings["Tab"]["id"]
    assert Enum.any?(projection.groups, &(&1["props"]["context"] == "browse"))
  end

  test "create form binds Ctrl+S to submit through its typed create endpoint", %{port: port} do
    s = console(port)
    put(s, %{"op" => "open", "to" => "/k/widget/new"})
    p = page(s)
    assert {:ok, projection} = Console.compile(p)
    current = %{path: p["path"], context: "form", generation: 1}
    assert {:ok, bindings} = Console.bindings(projection, current)
    action = bindings["Ctrl+S"]
    assert action["props"]["operation"] == %{"name" => "submit"}
    form = Enum.find(p["blocks"], &(&1["id"] == action["props"]["scope"]["on"]))
    assert %{"endpoint" => "create", "params" => params} = form["props"]["submit_to"]
    assert FakeStore.sent() == []

    put(s, %{
      "op" => "submit",
      "to" => Protocol.endpoint_path(:submit, :create, params),
      "values" => %{"title" => "Console proof", "notes" => "Synthetic"}
    })

    stored = page(s)
    assert stored["reason"] == "stored"
    assert {:ok, _} = Console.compile(stored)
    assert %{"op" => "create", "values" => %{"title" => "Console proof"}} = FakeStore.last_fact()
  end

  test "selecting Console never grants an agent member-only mutation authority", %{port: port} do
    FakeStore.put("W-1", %{"title" => "One"})
    FakeStore.put("ada", %{"name" => "Ada"}, "member")
    Application.put_env(:atlas_control, :tui_user, "ada")
    on_exit(fn -> Application.delete_env(:atlas_control, :tui_user) end)
    s = connect(port, %{"surface" => "console", "client" => "agent"})
    assert %{"op" => "welcome", "surface" => "console"} = read(s)
    read(s)
    put(s, %{"op" => "submit", "to" => "/k/widget/W-1/set/approved_by", "values" => %{}})
    assert %{"op" => "notice", "text" => text} = read(s)
    assert text =~ "only a member approves"
    assert FakeStore.sent() == []
  end

  test "failed projection declines Console before welcome without affecting legacy", %{port: port} do
    FakeStore.describe(
      Map.put(FakeStore.description(), "shell", %{"title" => "Invalid", "tabs" => []})
    )

    s = connect(port, %{"surface" => "console"})
    assert %{"op" => "bye"} = read(s)
    assert {:error, :closed} = :gen_tcp.recv(s, 0, 500)
    old = connect(port)
    assert %{"op" => "welcome"} = read(old)
    assert %{"op" => "page"} = read(old)
    assert FakeStore.sent() == []
  end
end

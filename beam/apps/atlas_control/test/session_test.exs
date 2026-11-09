defmodule AtlasControl.SessionTest do
  use ExUnit.Case, async: false

  alias AtlasControl.{FakeStore, Pages}

  setup do
    Application.put_env(:atlas_bus, :store, "store-#{System.unique_integer([:positive])}")
    AtlasBus.drop_hints(0)
    start_supervised!(FakeStore)
    start_supervised!({AtlasControl.Gateway, port: 0, name: :gateway})

    # A session waiting on a read sees its client close only after its tries (6 s); stopped
    # here, it cannot read on into the next test, or another app's tests in this VM.
    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasControl.Sessions),
          do: DynamicSupervisor.terminate_child(AtlasControl.Sessions, pid)
    end)

    %{port: AtlasControl.Gateway.port(:gateway)}
  end

  defp client(port, env \\ "test") do
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", port, [
        :binary,
        packet: :line,
        active: false,
        buffer: 4_194_304
      ])

    put(socket, %{
      "op" => "hello",
      "env" => env,
      "client" => "test",
      "spec" => AtlasControl.Blocks.version()
    })

    socket
  end

  defp put(socket, message), do: :ok = :gen_tcp.send(socket, [JSON.encode!(message), "\n"])

  # The next message with this op, skipping others; nil when none comes.
  defp next(socket, op, timeout \\ 1_000) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, line} ->
        message = JSON.decode!(line)
        if message["op"] == op, do: message, else: next(socket, op, timeout)

      {:error, :timeout} ->
        nil
    end
  end

  defp rows(page),
    do: page["blocks"] |> hd() |> get_in(["props", "rows"]) |> Enum.map(& &1["label"])

  defmodule Protocol do
    use AtlasBFF.Targets.Protocol, contract: AtlasBFFContract.Contract, channel: :control
  end

  test "exact fact reads preserve named values and links for evidence", %{port: port} do
    FakeStore.put("W-01", %{"title" => "A", "done" => false}, "widget", %{"made_by" => ["M-1"]})
    socket = client(port)
    on_exit(fn -> :gen_tcp.close(socket) end)
    next(socket, "page")
    put(socket, Protocol.request(:facts_read, kind: "_", key: "W-01"))
    reply = next(socket, "facts_read")
    assert {:reply, %{effect: :complete}} = Protocol.classify(:facts_read, reply)

    assert %{
             "fact" => %{
               "key" => "W-01",
               "values" => %{"title" => "A", "done" => false},
               "links" => %{"made_by" => ["M-1"]}
             }
           } = reply["data"]

    put(socket, Protocol.request(:facts_read, kind: "widget"))
    assert %{"data" => %{"facts" => [%{"key" => "W-01"}]}} = next(socket, "facts_read")
    put(socket, Protocol.request(:facts_read, kind: "not-a-kind"))
    assert %{"error" => _} = next(socket, "facts_read")
  end

  test "actual session envelopes match the declared reply classifiers", %{port: port} do
    a = client(port)
    b = client(port)

    on_exit(fn ->
      :gen_tcp.close(a)
      :gen_tcp.close(b)
    end)

    assert {:reply, %{name: :welcome, effect: :progress}} =
             Protocol.classify(:hello, next(a, "welcome"))

    assert {:reply, %{name: :page, requires: [:welcome]}} =
             Protocol.classify(:hello, next(a, "page"))

    next(b, "page")
    put(a, %{"op" => "open", "to" => "/k/widget/new"})
    assert {:reply, %{effect: :complete}} = Protocol.classify(:open, next(a, "page"))

    put(a, %{
      "op" => "submit",
      "endpoint" => "create",
      "params" => %{"kind" => "widget"},
      "values" => %{"title" => "One"},
      "cause" => "wire parity"
    })

    assert {:reply, %{effect: :progress}} = Protocol.classify(:submit, next(a, "notice"))

    assert {:reply, %{name: :stored, effect: :complete}} =
             Protocol.classify(:submit, next(a, "page"))

    assert {:reply, %{effect: :progress}} = Protocol.classify(:open, next(b, "page"))
    put(b, %{"op" => "refresh"})
    assert {:reply, %{effect: :progress}} = Protocol.classify(:open, next(b, "page"))
    put(a, %{"op" => "turn_end", "key" => "stale", "outcome" => "done"})

    assert {:reply, %{name: :error, effect: :error}} =
             Protocol.classify(:turn_end, next(a, "turn"))

    put(a, %{"op" => "open", "to" => "/k/widget/new"})
    next(a, "page")
    FakeStore.refuse("W-02", "no")

    put(a, %{
      "op" => "submit",
      "endpoint" => "create",
      "params" => %{"kind" => "widget"},
      "values" => %{"title" => "Two"}
    })

    assert {:reply, %{name: :refused, effect: :complete}} =
             Protocol.classify(:submit, next(a, "page"))
  end

  test "a key made from a property: never sent when it cannot be made, never renumbered",
       %{port: port} do
    FakeStore.link("P-1", "W-1")
    a = client(port)
    next(a, "page")
    put(a, %{"op" => "open", "to" => "/k/tag/new/on_part/P-1"})
    assert %{"title" => "Create tag in P-1"} = next(a, "page")

    put(a, %{"op" => "submit", "to" => "/k/tag/new/on_part/P-1", "values" => %{"name" => "nope"}})
    assert %{"tone" => "error", "text" => "Not sent: the form says why."} = next(a, "notice")

    assert %{
             "reason" => "refused",
             "blocks" => [%{"props" => %{"errors" => ["name must look like #word/1"]}}]
           } = next(a, "page")

    put(a, %{
      "op" => "submit",
      "to" => "/k/tag/new/on_part/P-1",
      "values" => %{"name" => "#x.y/7"}
    })

    assert %{"tone" => "pending"} = next(a, "notice")

    assert %{"path" => "/k/tag/T-x_y-7", "back" => "/k/part/P-1", "reason" => "stored"} =
             next(a, "page")

    # The same name again is the same key: refused as taken, not tried with another number.
    put(a, %{"op" => "open", "to" => "/k/tag/new/on_part/P-1"})
    next(a, "page")

    put(a, %{
      "op" => "submit",
      "to" => "/k/tag/new/on_part/P-1",
      "values" => %{"name" => "#x.y/7"}
    })

    assert %{"tone" => "pending"} = next(a, "notice")
    assert %{"tone" => "error"} = next(a, "notice")

    assert %{
             "reason" => "refused",
             "blocks" => [%{"props" => %{"errors" => ["T-x_y-7 is taken"]}}]
           } =
             next(a, "page")
  end

  test "a client sees the top list at once", %{port: port} do
    FakeStore.put("W-1", %{"title" => "One"})
    c = client(port)
    assert %{"env" => "test", "spec" => "0.14.0"} = next(c, "welcome")
    assert %{"path" => "/", "title" => "Widgets", "reason" => "open"} = page = next(c, "page")
    assert rows(page) == ["One"]
  end

  test "a change shows once it is stored, and reaches a second client as a hint", %{port: port} do
    a = client(port)
    b = client(port)
    next(a, "page")
    next(b, "page")

    put(a, %{"op" => "open", "to" => "/k/widget/new"})
    assert %{"title" => "Create widget"} = next(a, "page")

    put(a, %{
      "op" => "submit",
      "to" => "/k/widget/new",
      "values" => %{"title" => "One"}
    })

    assert %{"tone" => "pending"} = next(a, "notice")
    assert %{"tone" => "ok", "text" => "Stored as W-01 (position 1)."} = next(a, "notice")
    assert %{"path" => "/k/widget/W-01", "reason" => "stored", "position" => 1} = next(a, "page")

    assert %{"reason" => "hint", "position" => 1} = page = next(b, "page")
    assert rows(page) == ["One"]
  end

  test "a lost hint only delays: the client's reconcile finds the change", %{port: port} do
    a = client(port)
    b = client(port)
    next(a, "page")
    next(b, "page")
    :ok = AtlasBus.drop_hints(1)

    put(a, %{
      "op" => "submit",
      "to" => "/k/widget/new",
      "values" => %{"title" => "One"}
    })

    assert %{"reason" => "stored"} = next(a, "page")
    assert next(b, "page", 300) == nil

    put(b, %{"op" => "refresh"})
    assert %{"reason" => "reconcile"} = page = next(b, "page")
    assert rows(page) == ["One"]
  end

  test "failures (IS-Atlas-23): ! opens what can fail; a confirm causes it", %{port: port} do
    a = client(port)
    b = client(port)
    home = next(a, "page")
    next(b, "page")

    # `! Failures…` on a browsing page, after its own actions.
    actions = home["blocks"] |> hd() |> get_in(["props", "actions"])
    assert %{"key" => "!", "label" => "Failures…", "to" => "/faults"} = List.last(actions)

    # The node's: Control's own (no Runtime or Flow runs here to offer more).
    put(a, %{"op" => "open", "to" => "/faults"})

    assert rows(next(a, "page")) == [
             "Drop the next hint",
             "Take Control offline for 10 s",
             "Restart the node"
           ]

    put(a, %{"op" => "open", "to" => "/fault/drop-hint"})
    assert %{"blocks" => [%{"type" => "confirm", "props" => confirm}]} = next(a, "page")

    assert confirm["confirm_to"] == %{
             "endpoint" => "fault",
             "params" => %{"fault" => "drop-hint"}
           }

    # Confirmed: the next hint is dropped, so b sees the next change only at its reconcile.
    put(a, %{"op" => "submit", "endpoint" => "fault", "params" => %{"fault" => "drop-hint"}})
    assert %{"tone" => "info", "text" => "The Bus drops the next hint" <> _} = next(a, "notice")
    put(a, %{"op" => "submit", "to" => "/k/widget/new", "values" => %{"title" => "Late"}})
    assert %{"reason" => "stored"} = next(a, "page")
    assert next(b, "page", 300) == nil

    # Not offered: refused, nothing caused.
    put(a, %{"op" => "submit", "endpoint" => "fault", "params" => %{"fault" => "melt"}})
    assert %{"tone" => "error"} = next(a, "notice")

    # A prod Control offers none, and no `!`.
    Application.put_env(:atlas_bus, :environment, "prod")
    on_exit(fn -> Application.put_env(:atlas_bus, :environment, "test") end)
    assert AtlasControl.Faults.offers(nil) == []
  end

  test "failures: Control offline closes every client and takes none, for a while",
       %{port: port} do
    a = client(port)
    next(a, "page")
    :ok = AtlasControl.Gateway.offline(400, :gateway)
    assert {:error, :closed} = :gen_tcp.recv(a, 0, 1_000)

    # A client that connects meanwhile is closed at once; after the while, served again.
    c = client(port)
    assert {:error, :closed} = :gen_tcp.recv(c, 0, 1_000)
    Process.sleep(400)
    d = client(port)
    assert %{"op" => "page"} = next(d, "page")
  end

  test "a refused change shows the form again, with what was typed and why", %{port: port} do
    a = client(port)
    next(a, "page")
    put(a, %{"op" => "open", "to" => "/k/widget/new"})
    next(a, "page")

    put(a, %{
      "op" => "submit",
      "to" => "/k/widget/new",
      "values" => %{"title" => ""}
    })

    assert %{"tone" => "pending"} = next(a, "notice")
    assert %{"tone" => "error"} = next(a, "notice")

    assert %{"reason" => "refused", "blocks" => [%{"type" => "form", "props" => form}]} =
             next(a, "page")

    assert form["errors"] == ["title is required"]
    assert form["errors"] != []
  end

  test "a refused create keeps what was typed in every field", %{port: port} do
    a = client(port)
    next(a, "page")
    put(a, %{"op" => "open", "to" => "/k/widget/new"})
    next(a, "page")

    put(a, %{
      "op" => "submit",
      "to" => "/k/widget/new",
      "values" => %{"title" => "", "notes" => "Two lines\nof notes"}
    })

    assert %{"reason" => "refused", "blocks" => [%{"type" => "form", "props" => form}]} =
             next(a, "page")

    assert form["errors"] == ["title is required"]

    assert %{"value" => "Two lines\nof notes"} =
             Enum.find(form["inputs"], &(&1["name"] == "notes"))

    assert FakeStore.sent() |> Enum.map(& &1["op"]) == ["create"]
  end

  test "new facts under one parent get the next numbers, with the create defaults",
       %{port: port} do
    FakeStore.put("W-1", %{"title" => "One"})
    a = client(port)
    next(a, "page")

    for {title, key} <- [{"Wheel", "P-01"}, {"Axle", "P-02"}] do
      put(a, %{
        "op" => "submit",
        "to" => "/k/part/new/of_widget/W-1",
        "values" => %{"title" => title}
      })

      assert %{"path" => "/k/part/" <> ^key, "reason" => "stored"} = next(a, "page")
    end

    # The next number after the highest of its kind (W-1 is number 1).
    put(a, %{"op" => "submit", "to" => "/k/widget/new", "values" => %{"title" => "Two"}})
    assert %{"path" => "/k/widget/W-02", "reason" => "stored"} = next(a, "page")

    # Nobody types a key; what create does not ask comes from its defaults.
    assert %{
             "key" => "W-02",
             "values" => %{"title" => "Two", "shade" => "light", "done" => false}
           } =
             FakeStore.last_fact()
  end

  test "change and delete name the version they were made from", %{port: port} do
    FakeStore.put("W-1", %{"title" => "One"})
    a = client(port)
    next(a, "page")

    put(a, %{"op" => "open", "to" => "/k/widget/W-1/edit"})
    assert %{"blocks" => [%{"type" => "form"}]} = next(a, "page")
    put(a, %{"op" => "submit", "to" => "/k/widget/W-1/edit", "values" => %{"title" => "Uno"}})
    assert %{"path" => "/k/widget/W-1", "reason" => "stored"} = page = next(a, "page")
    assert page["blocks"] |> hd() |> get_in(["props", "title"]) == "Widget W-1: Uno"

    put(a, %{"op" => "open", "to" => "/k/widget/W-1/delete"})
    assert %{"blocks" => [%{"type" => "confirm"}]} = next(a, "page")
    put(a, %{"op" => "submit", "to" => "/k/widget/W-1/delete", "values" => %{}})
    assert %{"path" => "/k/widget", "reason" => "stored"} = page = next(a, "page")
    assert rows(page) == []
  end

  test "a fact is added under its parent; a client on the parent sees it by hint", %{port: port} do
    FakeStore.put("W-1", %{"title" => "One"})
    a = client(port)
    b = client(port)
    next(a, "page")
    next(b, "page")
    put(b, %{"op" => "open", "to" => "/k/widget/W-1"})

    assert %{"blocks" => [%{"type" => "item"}, %{"type" => "list", "props" => %{"rows" => []}}]} =
             next(b, "page")

    put(a, %{"op" => "open", "to" => "/k/part/new/of_widget/W-1"})
    assert %{"title" => "Create part in W-1"} = next(a, "page")

    put(a, %{
      "op" => "submit",
      "to" => "/k/part/new/of_widget/W-1",
      "values" => %{"title" => "Wheel"}
    })

    assert %{"path" => "/k/part/P-01", "back" => "/k/widget/W-1", "reason" => "stored"} =
             next(a, "page")

    assert %{
             "reason" => "hint",
             "blocks" => [_, %{"props" => %{"rows" => [%{"label" => "Wheel"}]}}]
           } = next(b, "page")

    put(a, %{"op" => "submit", "to" => "/k/part/P-01/delete", "values" => %{}})
    assert %{"path" => "/k/widget/W-1", "reason" => "stored"} = next(a, "page")
    assert %{"reason" => "hint", "blocks" => [_, %{"props" => %{"rows" => []}}]} = next(b, "page")
  end

  test "a change moves a fact to another parent; clients on both parents see it by hint",
       %{port: port} do
    FakeStore.put("W-1", %{"title" => "One"})
    FakeStore.put("W-2", %{"title" => "Two"})
    FakeStore.link("P-1", "W-1")
    a = client(port)
    old = client(port)
    new = client(port)
    for c <- [a, old, new], do: next(c, "page")
    put(old, %{"op" => "open", "to" => "/k/widget/W-1"})
    assert %{"blocks" => [_, %{"props" => %{"rows" => [_]}}]} = next(old, "page")
    put(new, %{"op" => "open", "to" => "/k/widget/W-2"})
    assert %{"blocks" => [_, %{"props" => %{"rows" => []}}]} = next(new, "page")

    put(a, %{"op" => "open", "to" => "/k/part/P-1/edit"})
    assert %{"blocks" => [%{"props" => form}]} = next(a, "page")
    assert %{"value" => "W-1"} = Enum.find(form["inputs"], &(&1["name"] == "of_widget"))

    # Emptied, it is refused before Facts sees it: a move never leaves a fact without one.
    put(a, %{
      "op" => "submit",
      "to" => "/k/part/P-1/edit",
      "values" => %{"title" => "P-1", "of_widget" => ""}
    })

    assert %{"reason" => "refused", "blocks" => [%{"props" => %{"errors" => [error]}}]} =
             next(a, "page")

    assert error == "of_widget cannot be empty; choose where it goes"

    put(a, %{
      "op" => "submit",
      "to" => "/k/part/P-1/edit",
      "values" => %{"title" => "P-1", "of_widget" => "W-2"}
    })

    assert %{"path" => "/k/part/P-1", "back" => "/k/widget/W-2", "reason" => "stored"} =
             next(a, "page")

    assert %{"cause" => "Moved from W-1 to W-2 (of_widget), by a change in Control"} =
             FakeStore.last_fact()

    assert %{"reason" => "hint", "blocks" => [_, %{"props" => %{"rows" => []}}]} =
             next(old, "page")

    assert %{"reason" => "hint", "blocks" => [_, %{"props" => %{"rows" => [%{"to" => to}]}}]} =
             next(new, "page")

    assert to == "/k/part/P-1"

    # A change that keeps the parent sends no move.
    put(a, %{"op" => "open", "to" => "/k/part/P-1/edit"})
    next(a, "page")

    put(a, %{
      "op" => "submit",
      "to" => "/k/part/P-1/edit",
      "values" => %{"title" => "Wheel", "of_widget" => "W-2"}
    })

    assert %{"reason" => "stored"} = next(a, "page")
    refute Map.has_key?(FakeStore.last_fact(), "links")
  end

  test "a limited relation: a create or a move to a full parent is refused, never sent",
       %{port: port} do
    FakeStore.link("P-1", "W-1")
    FakeStore.link("P-2", "W-1")
    FakeStore.put("T-a-1", %{"name" => "#a/1", "note" => "live"}, "tag", %{"on_part" => ["P-1"]})
    FakeStore.put("T-b-1", %{"name" => "#b/1", "note" => "live"}, "tag", %{"on_part" => ["P-2"]})
    a = client(port)
    next(a, "page")

    put(a, %{"op" => "submit", "to" => "/k/tag/new/on_part/P-1", "values" => %{"name" => "#c/1"}})
    assert %{"tone" => "error", "text" => "Not sent: the form says why."} = next(a, "notice")

    assert %{"reason" => "refused", "blocks" => [%{"props" => %{"errors" => [error]}}]} =
             next(a, "page")

    assert error == "P-1 already has T-a-1 (live); one tag per part"
    assert FakeStore.last_fact() == nil

    put(a, %{"op" => "open", "to" => "/k/tag/T-b-1/edit"})
    next(a, "page")

    put(a, %{
      "op" => "submit",
      "to" => "/k/tag/T-b-1/edit",
      "values" => %{"name" => "#b/1", "on_part" => "P-1"}
    })

    assert %{"reason" => "refused", "blocks" => [%{"props" => %{"errors" => [^error]}}]} =
             next(a, "page")

    # Once the one there no longer counts, the same create goes through.
    FakeStore.put("T-a-1", %{"name" => "#a/1", "note" => "dropped"}, "tag", %{
      "on_part" => ["P-1"]
    })

    put(a, %{"op" => "submit", "to" => "/k/tag/new/on_part/P-1", "values" => %{"name" => "#c/1"}})
    assert %{"path" => "/k/tag/T-c-1", "reason" => "stored"} = next(a, "page")
  end

  test "a submit to anything but a submit endpoint of the contract is refused, unsent",
       %{port: port} do
    FakeStore.put("W-1", %{"title" => "One"})
    a = client(port)
    next(a, "page")

    for to <- ["/k/widget", "/k/widget/W-1", "/nowhere"] do
      put(a, %{"op" => "submit", "to" => to, "values" => %{"title" => "Two"}})

      assert %{"tone" => "error", "text" => text} = next(a, "notice")
      assert text == "Control takes no submit at #{inspect(to)}."
    end

    assert FakeStore.last_fact() == nil
  end

  test "hello carries the contract version: an older client, or one without, is told it is too old",
       %{port: port} do
    version = AtlasControl.Blocks.version()

    for spec <- ["0.1.0", nil, "not a version"] do
      {:ok, socket} =
        :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :line, active: false])

      hello = %{"op" => "hello", "env" => "test", "client" => "tui"}
      put(socket, if(spec, do: Map.put(hello, "spec", spec), else: hello))

      assert %{"op" => "bye", "text" => text} = next(socket, "bye")

      assert text =~
               "This client implements contract #{spec || "(none)"}; Control test speaks #{version}."

      assert text =~ "It is too old"
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
    end

    # The same version, or a newer one, is welcomed.
    newer = version |> Version.parse!() |> Map.update!(:minor, &(&1 + 1)) |> to_string()
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :line, active: false])
    put(socket, %{"op" => "hello", "env" => "test", "client" => "tui", "spec" => newer})
    assert %{"spec" => ^version} = next(socket, "welcome")
  end

  test "a submit names its endpoint and params, as the form's submit_to holds them",
       %{port: port} do
    FakeStore.put("W-1", %{"title" => "One"})
    a = client(port)
    next(a, "page")
    put(a, %{"op" => "open", "to" => "/k/widget/W-1/edit"})
    assert %{"blocks" => [%{"props" => form}]} = next(a, "page")

    assert form["submit_to"] ==
             %{"endpoint" => "update", "params" => %{"kind" => "widget", "key" => "W-1"}}

    message = Map.merge(%{"op" => "submit", "values" => %{"title" => "Uno"}}, form["submit_to"])
    put(a, message)
    assert %{"path" => "/k/widget/W-1", "reason" => "stored"} = next(a, "page")

    # An endpoint the contract has not, or one without its params, is refused, unsent.
    for bad <- [
          %{"endpoint" => "explode", "params" => %{"kind" => "widget"}},
          %{"endpoint" => "update", "params" => %{"kind" => "widget"}},
          %{"endpoint" => "update", "params" => "W-1"}
        ] do
      put(a, Map.merge(%{"op" => "submit", "values" => %{}}, bad))

      assert %{"tone" => "error", "text" => "Control takes no submit at " <> _} =
               next(a, "notice")
    end
  end

  test "a client that knows only the parent's key submits to _parent", %{port: port} do
    FakeStore.put("W-1", %{"title" => "One"})
    a = client(port)
    next(a, "page")

    put(a, %{"op" => "open", "to" => "/k/part/new/_parent/W-1"})

    assert %{"title" => "Create part in W-1", "blocks" => [%{"props" => form}]} = next(a, "page")

    assert Pages.submit_call(form["submit_to"]) ==
             {:ok, :create_under, %{kind: "part", relation: "of_widget", parent: "W-1"}}

    put(a, %{
      "op" => "submit",
      "to" => "/k/part/new/_parent/W-1",
      "values" => %{"title" => "Wheel"}
    })

    assert %{"path" => "/k/part/P-01", "back" => "/k/widget/W-1", "reason" => "stored"} =
             next(a, "page")
  end

  test "a refused delete answers with the page and Facts' reasons", %{port: port} do
    FakeStore.put("W-1", %{"title" => "One"})
    FakeStore.refuse("W-1", "W-1 is locked")
    a = client(port)
    next(a, "page")

    put(a, %{"op" => "open", "to" => "/k/widget/W-1/delete"})
    assert %{"blocks" => [%{"type" => "confirm"}]} = next(a, "page")
    put(a, %{"op" => "submit", "to" => "/k/widget/W-1/delete", "values" => %{}})

    assert %{"path" => "/k/widget/W-1/delete", "reason" => "refused", "refused" => reasons} =
             next(a, "page")

    assert reasons == ["W-1 is locked"]
  end

  test "a fact with parts under it is not deleted", %{port: port} do
    FakeStore.put("W-1", %{"title" => "One"})
    FakeStore.link("P-1", "W-1")
    a = client(port)
    next(a, "page")

    put(a, %{"op" => "submit", "to" => "/k/widget/W-1/delete", "values" => %{}})
    assert %{"blocks" => [%{"type" => "confirm", "props" => props}]} = next(a, "page")
    assert props["text"] =~ "still has 1 part."
    assert next(a, "notice", 200) == nil
  end

  test "a key taken meanwhile: Facts refuses it, and Control tries the next number", %{port: port} do
    FakeStore.put("W-01", %{"title" => "One"})
    FakeStore.reserve("W-02")
    FakeStore.reserve("W-03")
    a = client(port)
    next(a, "page")

    put(a, %{"op" => "submit", "to" => "/k/widget/new", "values" => %{"title" => "Two"}})
    assert %{"text" => "Sent to Facts; waiting until it is stored…"} = next(a, "notice")
    assert %{"text" => "W-02 is taken; trying W-03…"} = next(a, "notice")
    assert %{"text" => "W-03 is taken; trying W-04…"} = next(a, "notice")

    assert %{"tone" => "ok", "text" => "Stored as W-04 (position 1); W-02, W-03 were taken."} =
             next(a, "notice")

    assert %{"path" => "/k/widget/W-04", "reason" => "stored"} = next(a, "page")
  end

  test "a client of the other environment is sent away", %{port: port} do
    c = client(port, "prod")
    assert %{"op" => "bye", "text" => text} = JSON.decode!(elem(:gen_tcp.recv(c, 0, 1_000), 1))
    assert text =~ "does not serve \"prod\""
    assert {:error, :closed} = :gen_tcp.recv(c, 0, 1_000)
  end

  test "Control prod sends a test client away", %{port: port} do
    Application.put_env(:atlas_bus, :environment, "prod")
    on_exit(fn -> Application.put_env(:atlas_bus, :environment, "test") end)
    c = client(port, "test")
    assert %{"op" => "bye", "text" => text} = JSON.decode!(elem(:gen_tcp.recv(c, 0, 1_000), 1))
    assert text =~ "This is Control prod; it does not serve \"test\""
  end

  @tag timeout: 15_000
  test "a fact without an answer is sent again with the same id", %{port: port} do
    a = client(port)
    next(a, "page")
    FakeStore.silent(true)

    put(a, %{
      "op" => "submit",
      "to" => "/k/widget/new",
      "values" => %{"title" => "One"}
    })

    assert %{"tone" => "pending"} = next(a, "notice")
    FakeStore.silent(false)

    assert %{"tone" => "pending", "text" => "No answer from Facts yet; sent again."} =
             next(a, "notice", 7_000)

    assert %{"tone" => "ok"} = next(a, "notice")
  end

  describe "read retry correlation" do
    setup do
      Application.put_env(:atlas_control, :read_timeout_ms, 100)
      on_exit(fn -> Application.delete_env(:atlas_control, :read_timeout_ms) end)
      :ok
    end

    defp intercept_reads do
      endpoint = "read-proxy-#{System.unique_integer([:positive])}"
      :ok = AtlasBus.attach(endpoint)
      Application.put_env(:atlas_bus, :store, endpoint)
      endpoint
    end

    defp store_answer(envelope, content, proxy) do
      send(Process.whereis(FakeStore), {:atlas_bus, %{envelope | sender: proxy}, content})
      id = envelope.id
      assert_receive {:atlas_bus, %AtlasBus.Envelope{id: ^id, class: "answer"}, answer}
      answer
    end

    defp answer_read(envelope, answer) do
      :ok = AtlasBus.send(AtlasBus.Envelope.reply(envelope, "answer"), answer)
    end

    test "a late first answer succeeds and a later logical read gets fresh data", %{port: port} do
      FakeStore.put("W-1", %{"title" => "Before"})
      a = client(port)
      next(a, "page")
      proxy = intercept_reads()
      put(a, %{"op" => "open", "to" => "/k/widget"})
      assert_receive {:atlas_bus, first, content}
      answer = store_answer(first, content, proxy)
      assert_receive {:atlas_bus, retry, ^content}, 500
      assert retry.id == first.id
      answer_read(first, answer)
      assert rows(next(a, "page")) == ["Before"]

      FakeStore.put("W-1", %{"title" => "Fresh"})
      put(a, %{"op" => "open", "to" => "/k/widget"})
      assert_receive {:atlas_bus, fresh, content}
      refute fresh.id == first.id
      answer_read(fresh, store_answer(fresh, content, proxy))
      assert rows(next(a, "page")) == ["Fresh"]
    end

    test "lost first requests and lost first answers recover on the same-id retry", %{port: port} do
      FakeStore.put("W-1", %{"title" => "Recovered"})
      a = client(port)
      next(a, "page")
      proxy = intercept_reads()

      for loss <- [:request, :answer] do
        put(a, %{"op" => "open", "to" => "/k/widget"})
        assert_receive {:atlas_bus, first, content}
        if loss == :answer, do: store_answer(first, content, proxy)
        assert_receive {:atlas_bus, retry, ^content}, 500
        assert retry.id == first.id
        answer_read(retry, store_answer(retry, content, proxy))
        assert rows(next(a, "page")) == ["Recovered"]
      end
    end

    test "unrelated answers do not extend the three-attempt silence budget", %{port: port} do
      a = client(port)
      next(a, "page")
      intercept_reads()
      started = System.monotonic_time(:millisecond)
      put(a, %{"op" => "open", "to" => "/k/widget"})
      assert_receive {:atlas_bus, first, content}

      for _ <- 1..2 do
        assert_receive {:atlas_bus, retry, ^content}, 500
        assert retry.id == first.id

        answer_read(%{retry | id: "unrelated-#{System.unique_integer([:positive])}"}, %{
          "facts" => []
        })
      end

      assert %{"title" => "Facts did not answer"} = next(a, "page", 200)
      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed >= 300 and elapsed < 500
      refute_receive {:atlas_bus, _, _}, 120
    end

    test "Open work retains the collection-scaled wait budget", %{port: port} do
      description =
        Map.put(FakeStore.description(), "start", %{
          "assigned" => %{"relation" => "checked_by", "title" => "Assigned"},
          "open" => %{"title" => "Open work", "empty" => "Nothing open"}
        })

      FakeStore.describe(description)
      a = client(port)
      next(a, "page")
      intercept_reads()
      started = System.monotonic_time(:millisecond)
      put(a, %{"op" => "open", "to" => "/k/widget"})
      assert_receive {:atlas_bus, first, %{"kinds" => kinds} = content}
      assert first.kind == "_page"
      assert kinds == ["widget", "part"]
      assert_receive {:atlas_bus, retry, ^content}, 500
      assert retry.id == first.id
      assert System.monotonic_time(:millisecond) - started >= 200
      Process.sleep(110)
      answer_read(first, %{"answers" => [%{"facts" => []}, %{"facts" => []}]})
      assert %{"title" => "Open work"} = next(a, "page")
    end
  end

  describe "when Facts does not answer" do
    setup do
      # A read waits this long for each of its tries, so the tests need not wait 6 s.
      Application.put_env(:atlas_control, :read_timeout_ms, 50)
      on_exit(fn -> Application.delete_env(:atlas_control, :read_timeout_ms) end)
    end

    test "a page says Facts did not answer; No such page only where Control has no page",
         %{port: port} do
      FakeStore.put("W-1", %{"title" => "One"})
      FakeStore.silent_reads(true)
      # Its hello asks for the description, and gets no answer.
      a = client(port)
      next(a, "page")

      put(a, %{"op" => "open", "to" => "/nowhere"})
      assert %{"title" => "No such page"} = next(a, "page")

      put(a, %{"op" => "open", "to" => "/k/_/W-1"})

      assert %{"title" => "Facts did not answer", "path" => "/k/_/W-1", "blocks" => [block]} =
               next(a, "page")

      assert block["props"]["text"] =~ "Facts did not answer"

      # Facts answers again: a refresh works the page out.
      FakeStore.silent_reads(false)
      put(a, %{"op" => "refresh"})
      assert %{"path" => "/k/widget/W-1", "reason" => "reconcile"} = next(a, "page")
    end

    test "a page whose own read gets no answer says so", %{port: port} do
      FakeStore.put("W-1", %{"title" => "One"})
      a = client(port)
      next(a, "page")
      FakeStore.silent_reads(["widget"])

      put(a, %{"op" => "open", "to" => "/k/_/W-1"})
      assert %{"title" => "Facts did not answer"} = next(a, "page")
    end
  end

  test "a links form becomes a change of those links, with who sent it and the note as cause",
       %{port: port} do
    FakeStore.put("W-1", %{"title" => "One"})
    FakeStore.put("ada", %{"name" => "Ada"}, "member")
    Application.put_env(:atlas_control, :tui_user, "ada")
    on_exit(fn -> Application.delete_env(:atlas_control, :tui_user) end)

    {:ok, tui} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :line, active: false])

    put(tui, %{
      "op" => "hello",
      "env" => "test",
      "client" => "tui",
      "spec" => AtlasControl.Blocks.version()
    })

    next(tui, "page")
    put(tui, %{"op" => "open", "to" => "/k/_/W-1/links/checked_by"})
    assert %{"blocks" => [%{"type" => "form"}]} = next(tui, "page")

    put(tui, %{
      "op" => "submit",
      "to" => "/k/widget/W-1/links/checked_by",
      "values" => %{"to" => "ada", "note" => "tested it"}
    })

    assert %{"reason" => "stored", "path" => "/k/widget/W-1"} = next(tui, "page")

    assert %{
             "op" => "change",
             "key" => "W-1",
             "values" => %{},
             "links" => %{"checked_by" => ["ada"]},
             "by" => "ada",
             "cause" => "tested it"
           } = List.last(FakeStore.sent())

    # Any other client is an agent; a submit's cause goes with its fact.
    a = client(port)
    next(a, "page")
    put(a, %{"op" => "open", "to" => "/k/widget/W-1/edit"})
    next(a, "page")

    put(a, %{
      "op" => "submit",
      "to" => "/k/widget/W-1/edit",
      "values" => %{"title" => "Uno"},
      "cause" => "a better name"
    })

    assert %{"reason" => "stored"} = next(a, "page")
    assert %{"by" => "agent", "cause" => "a better name"} = List.last(FakeStore.sent())

    put(a, %{
      "op" => "submit",
      "to" => "/k/widget/W-1/links/checked_by",
      "values" => %{"to" => ""}
    })

    assert %{"reason" => "stored"} = next(a, "page")
    assert %{"links" => %{"checked_by" => []}, "by" => "agent"} = List.last(FakeStore.sent())
    refute Map.has_key?(List.last(FakeStore.sent()), "cause")

    # An agent that says which fact it is (`as`, IS-Atlas-54) is that fact; the migration
    # stays the migration whatever it says.
    {:ok, b} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :line, active: false])

    put(b, %{
      "op" => "hello",
      "env" => "test",
      "client" => "agent",
      "as" => "ada",
      "spec" => AtlasControl.Blocks.version()
    })

    next(b, "page")
    put(b, %{"op" => "open", "to" => "/k/widget/W-1/edit"})
    next(b, "page")
    put(b, %{"op" => "submit", "to" => "/k/widget/W-1/edit", "values" => %{"title" => "Una"}})
    assert %{"reason" => "stored"} = next(b, "page")
    assert %{"by" => "ada"} = List.last(FakeStore.sent())
  end

  test "an update sends only what was edited, with what the form was read with (was)",
       %{port: port} do
    FakeStore.put("W-1", %{"title" => "One", "shade" => "light"})
    a = client(port)
    next(a, "page")
    put(a, %{"op" => "open", "to" => "/k/widget/W-1/edit"})
    next(a, "page")

    put(a, %{
      "op" => "submit",
      "to" => "/k/widget/W-1/edit",
      "values" => %{"title" => "Uno", "shade" => "light"}
    })

    assert %{"reason" => "stored"} = next(a, "page")

    # The shade was left as it was: it is not sent, so it can never put an old value back.
    assert %{"values" => values, "version" => "v0", "was" => was} = List.last(FakeStore.sent())
    assert values == %{"title" => "Uno"}
    assert was == %{"title" => "One"}
  end

  test "a link only a migration sets is never sent", %{port: port} do
    FakeStore.put("W-1", %{"title" => "One"})
    a = client(port)
    next(a, "page")
    sent = FakeStore.sent()

    put(a, %{
      "op" => "submit",
      "to" => "/k/widget/W-1/links/seen_in",
      "values" => %{"to" => "T-1"}
    })

    assert %{"reason" => "refused", "blocks" => [%{"type" => "confirm"}]} = next(a, "page")
    assert FakeStore.sent() == sent

    # A client that says it is the migration may.
    FakeStore.put("T-1", %{"name" => "#t/1"}, "tag")
    {:ok, m} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :line, active: false])

    put(m, %{
      "op" => "hello",
      "env" => "test",
      "client" => "migration",
      "spec" => AtlasControl.Blocks.version()
    })

    next(m, "page")

    put(m, %{
      "op" => "submit",
      "to" => "/k/widget/W-1/links/seen_in",
      "values" => %{"to" => "T-1"}
    })

    assert %{"reason" => "stored"} = next(m, "page")

    assert %{"links" => %{"seen_in" => ["T-1"]}, "by" => "migration"} =
             List.last(FakeStore.sent())
  end

  test "approve and withdraw: only the member at the TUI, as itself; withdraw needs a note",
       %{port: port} do
    FakeStore.put("W-1", %{"title" => "One"})
    FakeStore.put("ada", %{"name" => "Ada"}, "member")
    Application.put_env(:atlas_control, :tui_user, "ada")
    on_exit(fn -> Application.delete_env(:atlas_control, :tui_user) end)

    {:ok, tui} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :line, active: false])

    put(tui, %{
      "op" => "hello",
      "env" => "test",
      "client" => "tui",
      "spec" => AtlasControl.Blocks.version()
    })

    next(tui, "page")

    put(tui, %{"op" => "submit", "to" => "/k/widget/W-1/set/approved_by", "values" => %{}})
    assert %{"reason" => "stored", "path" => "/k/widget/W-1"} = next(tui, "page")

    assert %{"links" => %{"approved_by" => ["ada"]}, "by" => "ada"} =
             List.last(FakeStore.sent())

    put(tui, %{"op" => "open", "to" => "/k/widget/W-1/remove/approved_by"})
    next(tui, "page")

    put(tui, %{
      "op" => "submit",
      "to" => "/k/widget/W-1/remove/approved_by",
      "values" => %{"note" => " "}
    })

    assert %{"reason" => "refused", "blocks" => [%{"props" => %{"errors" => [why]}}]} =
             next(tui, "page")

    assert why =~ "a note is required"

    put(tui, %{
      "op" => "submit",
      "to" => "/k/widget/W-1/remove/approved_by",
      "values" => %{"note" => "found a bug"}
    })

    assert %{"reason" => "stored"} = next(tui, "page")

    assert %{"links" => %{"approved_by" => []}, "cause" => "found a bug"} =
             List.last(FakeStore.sent())

    # An agent is refused, and nothing is sent.
    a = client(port)
    next(a, "page")
    sent = FakeStore.sent()
    put(a, %{"op" => "submit", "to" => "/k/widget/W-1/set/approved_by", "values" => %{}})
    assert %{"text" => text} = next(a, "notice")
    assert text =~ "only a member approves"

    put(a, %{
      "op" => "submit",
      "to" => "/k/widget/W-1/links/approved_by",
      "values" => %{"to" => "ada"}
    })

    assert %{"reason" => "refused"} = next(a, "page")
    assert FakeStore.sent() == sent
  end

  test "nothing new is created under an approved fact", %{port: port} do
    FakeStore.put("W-1", %{"title" => "One"}, "widget", %{"approved_by" => ["ada"]})
    a = client(port)
    next(a, "page")
    sent = FakeStore.sent()

    put(a, %{
      "op" => "submit",
      "to" => "/k/part/new/of_widget/W-1",
      "values" => %{"title" => "Wheel"}
    })

    assert %{"reason" => "refused", "blocks" => [%{"props" => %{"errors" => [why]}}]} =
             next(a, "page")

    assert why == "W-1 is approved; withdraw it first, or put this under another widget"
    assert FakeStore.sent() == sent
  end

  test "nothing is moved under an approved fact", %{port: port} do
    FakeStore.put("W-1", %{"title" => "One"})
    FakeStore.put("W-2", %{"title" => "Two"}, "widget", %{"approved_by" => ["ada"]})
    FakeStore.link("P-1", "W-1")
    a = client(port)
    next(a, "page")
    put(a, %{"op" => "open", "to" => "/k/part/P-1/edit"})
    next(a, "page")
    sent = FakeStore.sent()

    put(a, %{
      "op" => "submit",
      "to" => "/k/part/P-1/edit",
      "values" => %{"title" => "P-1", "of_widget" => "W-2"}
    })

    assert %{"reason" => "refused", "blocks" => [%{"props" => %{"errors" => [why]}}]} =
             next(a, "page")

    assert why == "W-2 is approved; withdraw it first, or put this under another widget"
    assert FakeStore.sent() == sent
  end
end

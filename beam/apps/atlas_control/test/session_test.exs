defmodule AtlasControl.SessionTest do
  use ExUnit.Case, async: false

  alias AtlasControl.{FakeStore, Pages, Shop}

  setup do
    Application.put_env(:atlas_bus, :store, "store-#{System.unique_integer([:positive])}")
    AtlasBus.drop_hints(0)
    start_supervised!(FakeStore)
    start_supervised!(AtlasControl.FakeFlow)
    start_supervised!({AtlasControl.Gateway, port: 0, name: :gateway, model: AtlasControl.Shop})

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

  # A Gateway for another composition of the shop, with Facts' stand-in on it too.
  defp gateway(model) do
    stop_supervised!(FakeStore)
    start_supervised!({FakeStore, model: model})
    name = :"gateway_#{System.unique_integer([:positive])}"
    start_supervised!({AtlasControl.Gateway, port: 0, name: name, model: model}, id: name)
    AtlasControl.Gateway.port(name)
  end

  # The next message with this op, skipping others; nil when none comes. A page pushed
  # for a recent path off screen (a hint for another path than the last page) is skipped
  # too, as a client does that keeps no pages of other paths (`pushed/3` takes them), and
  # so is a page sent again with its rows marked (`reason: "pending"`; the marker's tests
  # read them with `sync/1`).
  defp next(socket, op, timeout \\ 1_000) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, line} ->
        message = JSON.decode!(line)

        cond do
          message["op"] != op ->
            next(socket, op, timeout)

          op == "page" and push?(socket, message) ->
            next(socket, op, timeout)

          true ->
            if op == "page", do: Process.put({:on_screen, socket}, message["path"])
            message
        end

      {:error, :timeout} ->
        nil
    end
  end

  defp push?(socket, %{"reason" => "hint", "path" => path}),
    do: Process.get({:on_screen, socket}) not in [nil, path]

  defp push?(_socket, %{"reason" => "pending"}), do: true

  defp push?(_socket, _page), do: false

  # The next page pushed for `path` off screen, skipping other messages; nil when none.
  defp pushed(socket, path, timeout \\ 1_000) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, line} ->
        case JSON.decode!(line) do
          %{"op" => "page", "reason" => "hint", "path" => ^path} = page -> page
          _ -> pushed(socket, path, timeout)
        end

      {:error, :timeout} ->
        nil
    end
  end

  defp rows(page),
    do: page["blocks"] |> hd() |> get_in(["props", "rows"]) |> Enum.map(& &1["label"])

  # How long a message may take to arrive: an upper bound for delivery under load, never a
  # duration under test. Every wait under test is held (`hold_clock/0`) and run out here.
  @arrives 5_000

  # The test decides when each of Control's waits runs out (`AtlasControl.Clock`).
  defp hold_clock(holder \\ self()) do
    AtlasControl.Clock.hold(holder)
    on_exit(&AtlasControl.Clock.release/0)
  end

  # The wait a process started for `message`, as the held clock is told of it.
  defmacrop held_wait(message) do
    quote do
      assert_receive {:clock, pid, unquote(message) = message, ms}, @arrives
      {pid, message, ms}
    end
  end

  defp run_out({pid, message, _ms}), do: send(pid, message)

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
    # A reconcile sends a page once Facts is past what b saw: a write whose hint was lost.
    :ok = AtlasBus.drop_hints(1)
    FakeStore.hint("widget", "W-01", [])
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
    assert %{"env" => "test", "spec" => "0.15.0"} = next(c, "welcome")
    assert %{"path" => "/", "title" => "Widgets", "reason" => "open"} = page = next(c, "page")
    assert rows(page) == ["One"]
  end

  test "a row names the fact it opens (contract 0.15.0), and is not pending without a write",
       %{port: port} do
    FakeStore.put("W-1", %{"title" => "One"})
    c = client(port)
    page = next(c, "page")
    assert [row] = page["blocks"] |> hd() |> get_in(["props", "rows"])
    assert %{"key" => "W-1", "to" => "/k/widget/W-1"} = row
    refute Map.has_key?(row, "pending")
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
    hold_clock()
    a = client(port)
    next(a, "page")
    :ok = AtlasControl.Gateway.offline(400, :gateway)
    assert {:error, :closed} = :gen_tcp.recv(a, 0, @arrives)
    assert {gateway, {:online, _}, 400} = while = held_wait({:online, _})

    # A client that connects meanwhile is closed at once; after the while, served again.
    c = client(port)
    assert {:error, :closed} = :gen_tcp.recv(c, 0, @arrives)
    run_out(while)
    # Its while is over before it is asked anything after.
    AtlasControl.Gateway.port(gateway)
    d = client(port)
    assert %{"op" => "page"} = next(d, "page", @arrives)
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

  # How many facts a parent takes (a relation's `limit`) is the model's rule, and Facts
  # enforces it (AtlasFacts.RelationRulesTest): Control sends the create and the move, and
  # shows what Facts says.
  test "a create or a move under a limited parent is sent; Facts says when it is full",
       %{port: port} do
    FakeStore.link("P-1", "W-1")
    FakeStore.put("T-a-1", %{"name" => "#a/1", "note" => "live"}, "tag", %{"on_part" => ["P-1"]})
    FakeStore.put("T-b-1", %{"name" => "#b/1", "note" => "live"}, "tag")
    FakeStore.refuse("T-b-1", "P-1 already has T-a-1 (live); one tag per part")
    a = client(port)
    next(a, "page")

    put(a, %{"op" => "submit", "to" => "/k/tag/new/on_part/P-1", "values" => %{"name" => "#c/1"}})
    assert %{"path" => "/k/tag/T-c-1", "reason" => "stored"} = next(a, "page")
    assert %{"op" => "create", "links" => %{"on_part" => ["P-1"]}} = FakeStore.last_fact()

    put(a, %{"op" => "open", "to" => "/k/tag/T-b-1/edit"})
    next(a, "page")

    put(a, %{
      "op" => "submit",
      "to" => "/k/tag/T-b-1/edit",
      "values" => %{"name" => "#b/1", "on_part" => "P-1"}
    })

    assert %{"reason" => "refused", "blocks" => [%{"props" => %{"errors" => errors}}]} =
             next(a, "page")

    assert errors == ["P-1 already has T-a-1 (live); one tag per part"]

    assert %{"op" => "change", "links" => %{"on_part" => ["P-1"]}} = FakeStore.last_fact()
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

  test "a fact without an answer is sent again with the same id", %{port: port} do
    hold_clock()
    a = client(port)
    next(a, "page")
    FakeStore.silent(true)

    put(a, %{
      "op" => "submit",
      "to" => "/k/widget/new",
      "values" => %{"title" => "One"}
    })

    assert %{"tone" => "pending"} = next(a, "notice", @arrives)
    assert {_, {:resend, id}, 5_000} = first = held_wait({:resend, _})
    FakeStore.silent(false)
    run_out(first)

    assert %{"tone" => "pending", "text" => "No answer from Facts yet; sent again."} =
             next(a, "notice", @arrives)

    # Sent again, it waits twice as long for its answer; it comes.
    assert {_, _, 10_000} = held_wait({:resend, ^id})
    assert %{"tone" => "ok"} = next(a, "notice", @arrives)
  end

  describe "read retry correlation" do
    setup do
      # Each try of a read is told to the held clock as this long.
      Application.put_env(:atlas_control, :read_timeout_ms, 100)
      on_exit(fn -> Application.delete_env(:atlas_control, :read_timeout_ms) end)
      hold_clock()
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
      assert_receive {:atlas_bus, %AtlasBus.Envelope{id: ^id, class: "answer"}, answer}, @arrives
      answer
    end

    defp answer_read(envelope, answer) do
      :ok = AtlasBus.send(AtlasBus.Envelope.reply(envelope, "answer"), answer)
    end

    # The wait of a read's try; it runs out when the test says (`run_out/1`).
    defp try_wait(id), do: held_wait({:read_expired, ^id, _})

    test "a late first answer succeeds and a later logical read gets fresh data", %{port: port} do
      FakeStore.put("W-1", %{"title" => "Before"})
      a = client(port)
      next(a, "page")
      proxy = intercept_reads()
      put(a, %{"op" => "open", "to" => "/k/widget"})
      assert_receive {:atlas_bus, first, content}, @arrives
      answer = store_answer(first, content, proxy)
      run_out(try_wait(first.id))
      assert_receive {:atlas_bus, retry, ^content}, @arrives
      assert retry.id == first.id
      answer_read(first, answer)
      assert rows(next(a, "page", @arrives)) == ["Before"]

      FakeStore.put("W-1", %{"title" => "Fresh"})
      put(a, %{"op" => "open", "to" => "/k/widget"})
      assert_receive {:atlas_bus, fresh, content}, @arrives
      refute fresh.id == first.id
      answer_read(fresh, store_answer(fresh, content, proxy))
      assert rows(next(a, "page", @arrives)) == ["Fresh"]
    end

    test "lost first requests and lost first answers recover on the same-id retry", %{port: port} do
      FakeStore.put("W-1", %{"title" => "Recovered"})
      a = client(port)
      next(a, "page")
      proxy = intercept_reads()

      for loss <- [:request, :answer] do
        put(a, %{"op" => "open", "to" => "/k/widget"})
        assert_receive {:atlas_bus, first, content}, @arrives
        if loss == :answer, do: store_answer(first, content, proxy)
        run_out(try_wait(first.id))
        assert_receive {:atlas_bus, retry, ^content}, @arrives
        assert retry.id == first.id
        answer_read(retry, store_answer(retry, content, proxy))
        assert rows(next(a, "page", @arrives)) == ["Recovered"]
      end
    end

    test "unrelated answers do not extend the three-attempt silence budget", %{port: port} do
      a = client(port)
      next(a, "page")
      intercept_reads()
      put(a, %{"op" => "open", "to" => "/k/widget"})
      assert_receive {:atlas_bus, first, content}, @arrives

      # Each try waits once, its full wait; an answer to another read, come meanwhile,
      # neither ends that wait nor starts another.
      for try <- 1..3 do
        assert {_, _, 100} = wait = try_wait(first.id)

        answer_read(%{first | id: "unrelated-#{System.unique_integer([:positive])}"}, %{
          "facts" => []
        })

        run_out(wait)

        if try < 3 do
          assert_receive {:atlas_bus, retry, ^content}, @arrives
          assert retry.id == first.id
        end
      end

      assert %{"title" => "Facts did not answer"} = next(a, "page", @arrives)
      # Its reads and waits come before its page: three of each, no more.
      refute_received {:atlas_bus, _, _}
      id = first.id
      refute_received {:clock, _, {:read_expired, ^id, _}, _}
    end

    test "Open work retains the collection-scaled wait budget" do
      # What is checked by someone is open work (`Shop.CheckedOpen`).
      port = gateway(Shop.CheckedOpen)
      a = client(port)
      next(a, "page")
      intercept_reads()
      put(a, %{"op" => "open", "to" => "/k/widget"})
      assert_receive {:atlas_bus, first, %{"reads" => reads} = content}, @arrives
      assert first.kind == "_page"
      assert reads == [["widget", %{}], ["part", %{}]]
      # One read for two collections waits as long as their two reads would.
      assert {_, _, 200} = wait = try_wait(first.id)
      run_out(wait)
      assert_receive {:atlas_bus, retry, ^content}, @arrives
      assert retry.id == first.id
      # The first try's answer, come during the second, is the read's answer.
      answer_read(first, %{"answers" => [%{"facts" => []}, %{"facts" => []}]})
      assert %{"title" => "Open work"} = next(a, "page", @arrives)
    end
  end

  describe "when Facts does not answer" do
    setup do
      # A read's try runs out as soon as Facts has left it unanswered, never before; no
      # other wait runs out. So the tests need not wait 6 s, nor race an answer.
      clock = spawn_link(fn -> run_out_unanswered(%{}, %{}) end)
      FakeStore.tell_unanswered(clock)
      hold_clock(clock)
    end

    # Pairs each try's wait with Facts leaving that try unanswered (one of each per try,
    # in order), and runs the wait out then.
    defp run_out_unanswered(waits, unanswered) do
      {waits, unanswered} =
        receive do
          {:clock, pid, {:read_expired, id, _} = message, _ms} ->
            {Map.update(waits, id, [{pid, message}], &(&1 ++ [{pid, message}])), unanswered}

          {:clock, _pid, _message, _ms} ->
            {waits, unanswered}

          {:unanswered, id} ->
            {waits, Map.update(unanswered, id, 1, &(&1 + 1))}
        end

      paired = for {id, [_ | _]} <- waits, Map.get(unanswered, id, 0) > 0, do: id

      {waits, unanswered} =
        Enum.reduce(paired, {waits, unanswered}, fn id, {waits, unanswered} ->
          [{pid, message} | rest] = waits[id]
          send(pid, message)
          {Map.put(waits, id, rest), Map.update!(unanswered, id, &(&1 - 1))}
        end)

      run_out_unanswered(waits, unanswered)
    end

    test "a page says Facts did not answer; No such page only where Control has no page",
         %{port: port} do
      FakeStore.put("W-1", %{"title" => "One"})
      FakeStore.silent_reads(true)
      # Its hello asks Facts who the client is, and gets no answer.
      a = client(port)
      next(a, "page", @arrives)

      put(a, %{"op" => "open", "to" => "/nowhere"})
      assert %{"title" => "No such page"} = next(a, "page", @arrives)

      # The model says which kind the key is; the fact's own read gets no answer.
      put(a, %{"op" => "open", "to" => "/k/_/W-1"})

      assert %{"title" => "Facts did not answer", "path" => "/k/widget/W-1", "blocks" => [block]} =
               next(a, "page", @arrives)

      assert block["props"]["text"] =~ "Facts did not answer"

      # Facts answers again: a refresh works the page out.
      FakeStore.silent_reads(false)
      put(a, %{"op" => "refresh"})
      assert %{"path" => "/k/widget/W-1", "reason" => "reconcile"} = next(a, "page", @arrives)
    end

    test "a page whose own read gets no answer says so", %{port: port} do
      FakeStore.put("W-1", %{"title" => "One"})
      a = client(port)
      next(a, "page", @arrives)
      FakeStore.silent_reads(["widget"])

      put(a, %{"op" => "open", "to" => "/k/_/W-1"})
      assert %{"title" => "Facts did not answer"} = next(a, "page", @arrives)
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

  # Who sets a link (`set_by`, `only_target`) is the model's rule, and Facts enforces it:
  # Control sends the link as the client, and shows what Facts says.
  test "a link only a migration sets is sent as the client; Facts refuses anyone else",
       %{port: port} do
    FakeStore.put("W-1", %{"title" => "One"})
    FakeStore.put("T-1", %{"name" => "#t/1"}, "tag")
    a = client(port)
    next(a, "page")
    FakeStore.refuse("W-1", "only a migration sets seen_in")

    put(a, %{
      "op" => "submit",
      "to" => "/k/widget/W-1/links/seen_in",
      "values" => %{"to" => "T-1"}
    })

    assert %{"reason" => "refused"} = next(a, "page")

    assert %{"links" => %{"seen_in" => ["T-1"]}, "by" => "agent"} = FakeStore.last_fact()

    # A client that says it is the migration sends it as the migration.
    FakeStore.put("W-2", %{"title" => "Two"})
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
      "to" => "/k/widget/W-2/links/seen_in",
      "values" => %{"to" => "T-1"}
    })

    assert %{"reason" => "stored"} = next(m, "page")

    assert %{"key" => "W-2", "links" => %{"seen_in" => ["T-1"]}, "by" => "migration"} =
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

    # An agent's link goes to Facts as the agent's; Facts refuses it (only_target).
    a = client(port)
    next(a, "page")
    FakeStore.refuse("W-1", "only a member approves, as themselves")

    put(a, %{
      "op" => "submit",
      "to" => "/k/widget/W-1/links/approved_by",
      "values" => %{"to" => "ada"}
    })

    assert %{"reason" => "refused"} = next(a, "page")

    assert %{"links" => %{"approved_by" => ["ada"]}, "by" => "agent"} = FakeStore.last_fact()
  end

  # A parent closed by a link (`closes_parent`) is the model's rule, and Facts enforces it.
  test "a create or a move under an approved fact is sent; Facts says it is closed",
       %{port: port} do
    closed = "W-2 is approved; withdraw it first, or put this under another widget"
    FakeStore.put("W-1", %{"title" => "One"})
    FakeStore.put("W-2", %{"title" => "Two"}, "widget", %{"approved_by" => ["ada"]})
    FakeStore.link("P-1", "W-1")
    FakeStore.refuse("P-1", closed)
    a = client(port)
    next(a, "page")
    put(a, %{"op" => "open", "to" => "/k/part/P-1/edit"})
    next(a, "page")

    put(a, %{
      "op" => "submit",
      "to" => "/k/part/P-1/edit",
      "values" => %{"title" => "P-1", "of_widget" => "W-2"}
    })

    assert %{"reason" => "refused"} = next(a, "page")
    assert %{"op" => "change", "links" => %{"of_widget" => ["W-2"]}} = FakeStore.last_fact()
  end

  test "a declared answer submits one self change, requires its note, and rechecks a stale owner" do
    # A subflow reviews each widget; in its check state the card's holder answers
    # (`Shop.Reviewed`): accept makes its state final, reject (with a note) dropped.
    port = gateway(Shop.Reviewed)

    holder = fn by ->
      FakeStore.put("C-W-1", %{"of" => "W-1", "step" => "check"}, "card", %{"held_by" => [by]})
    end

    FakeStore.put("W-1", %{"title" => "One"}, "widget", %{"card" => ["C-W-1"]})
    holder.("ada")
    FakeStore.put("ada", %{"name" => "Ada"}, "member")
    Application.put_env(:atlas_control, :tui_user, "ada")
    on_exit(fn -> Application.delete_env(:atlas_control, :tui_user) end)
    {:ok, tui} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :line, active: false])
    on_exit(fn -> :gen_tcp.close(tui) end)

    put(tui, %{
      "op" => "hello",
      "env" => "test",
      "client" => "tui",
      "spec" => AtlasControl.Blocks.version()
    })

    next(tui, "page")
    put(tui, %{"op" => "submit", "to" => "/k/widget/W-1/answer/f", "values" => %{"note" => " "}})
    assert %{"reason" => "refused"} = next(tui, "page")
    assert FakeStore.sent() == []

    put(tui, %{
      "op" => "submit",
      "to" => "/k/widget/W-1/answer/f",
      "values" => %{"note" => "Needs work"}
    })

    assert %{"reason" => "stored"} = next(tui, "page")

    assert %{
             "by" => "ada",
             "cause" => "Needs work",
             "links" => %{"checked_by" => ["ada"]},
             "values" => %{"state" => "dropped"}
           } = List.last(FakeStore.sent())

    put(tui, %{"op" => "submit", "to" => "/k/widget/W-1/answer/a", "values" => %{}})
    assert %{"reason" => "stored"} = next(tui, "page")
    assert List.last(FakeStore.sent())["values"] == %{"state" => "final"}
    sent = FakeStore.sent()

    holder.("bob")

    put(tui, %{"op" => "submit", "to" => "/k/widget/W-1/answer/a", "values" => %{}})
    assert %{"reason" => "refused"} = next(tui, "page")
    assert FakeStore.sent() == sent
  end

  test "an update that decides goes as the client's, with what it read; a kind never deleted refuses unsent" do
    # Who checked a widget decides its dark shade; a widget is never deleted (`Shop.Kept`).
    port = gateway(Shop.Kept)
    FakeStore.put("W-1", %{"title" => "One", "shade" => "light"})
    a = client(port)
    next(a, "page")

    put(a, %{"op" => "open", "to" => "/k/widget/W-1"})
    %{"blocks" => [%{"props" => %{"actions" => actions}} | _]} = next(a, "page")
    assert Enum.any?(actions, &(&1["to"] == "/k/widget/W-1/edit"))
    refute Enum.any?(actions, &(&1["to"] == "/k/widget/W-1/delete"))

    put(a, %{"op" => "open", "to" => "/k/widget/W-1/edit"})
    next(a, "page")

    put(a, %{
      "op" => "submit",
      "to" => "/k/widget/W-1/edit",
      "values" => %{"title" => "One", "shade" => "dark"}
    })

    assert %{"reason" => "stored"} = next(a, "page")

    # The client here is the agent: it decides as itself. Facts links it as the one who
    # decides (the model's rule) and checks it may; Control sends what the form read of
    # the links, so Facts can tell when they changed meanwhile.
    sent = List.last(FakeStore.sent())

    assert %{"by" => "agent", "values" => %{"shade" => "dark"}, "was" => %{"shade" => "light"}} =
             sent

    refute Map.has_key?(sent, "links")

    # A change that decides nothing is sent the same way.
    put(a, %{"op" => "open", "to" => "/k/widget/W-1/edit"})
    next(a, "page")
    put(a, %{"op" => "submit", "to" => "/k/widget/W-1/edit", "values" => %{"title" => "Uno"}})
    assert %{"reason" => "stored"} = next(a, "page")
    refute Map.has_key?(List.last(FakeStore.sent()), "links")
    sent = FakeStore.sent()

    put(a, %{"op" => "open", "to" => "/k/widget/W-1/delete"})
    assert %{"blocks" => [%{"props" => props}]} = next(a, "page")
    assert inspect(props) =~ "Widgets are kept; record another."
    put(a, %{"op" => "submit", "to" => "/k/widget/W-1/delete", "values" => %{}})
    assert %{"reason" => "refused"} = next(a, "page")
    assert FakeStore.sent() == sent
  end

  describe "page freshness (docs/design/page-freshness.md §5)" do
    alias AtlasControl.FakeFlow
    import ExUnit.CaptureLog

    # What a `stored` says a write changed, for one fact.
    defp changed(kind, key, fields, links \\ %{}, relinked \\ []),
      do: %{
        "kind" => kind,
        "key" => key,
        "op" => "change",
        "fields" => fields,
        "relinked" => relinked,
        "links" => links
      }

    # Every message up to the session's answer to a request it does not know: what it
    # sent before, in order. The session handles messages one by one, so whatever it was
    # given before is done by then.
    defp sync(socket) do
      put(socket, %{"op" => "sync"})
      collect(socket, [])
    end

    defp collect(socket, seen) do
      {:ok, line} = :gen_tcp.recv(socket, 0, @arrives)

      case JSON.decode!(line) do
        %{"op" => "notice", "text" => "Unknown op \"sync\""} -> Enum.reverse(seen)
        message -> collect(socket, [message | seen])
      end
    end

    defp pages(messages), do: for(%{"op" => "page"} = page <- messages, do: page)

    # The reads Facts was sent since `before` (`FakeStore.reads/0` earlier).
    defp reads_since(before), do: Enum.drop(FakeStore.reads(), length(before))

    # The session's next wait for hints to be handled; the test runs it out.
    defp flush_wait, do: held_wait(:flush)

    # Per row of a page: its key, and whether it is marked pending.
    defp flags(page),
      do:
        for(
          %{"props" => %{"rows" => rows}} <- page["blocks"],
          row <- rows,
          do: {row["key"], row["pending"] == true}
        )

    # The next page sent again with its rows marked anew (`reason: "pending"`).
    defp marked(socket) do
      {:ok, line} = :gen_tcp.recv(socket, 0, @arrives)

      case JSON.decode!(line) do
        %{"op" => "page", "reason" => "pending"} = page -> page
        _ -> marked(socket)
      end
    end

    # The change form of a widget, opened; the submit is the test's.
    defp edit(socket, key) do
      put(socket, %{"op" => "open", "to" => "/k/widget/#{key}/edit"})
      assert %{"blocks" => [%{"type" => "form"}]} = next(socket, "page")
    end

    defp submit_title(socket, key, title),
      do:
        put(socket, %{
          "op" => "submit",
          "to" => "/k/widget/#{key}/edit",
          "values" => %{"title" => title}
        })

    defp create(socket, title) do
      put(socket, %{"op" => "open", "to" => "/k/widget/new"})
      assert %{"title" => "Create widget"} = next(socket, "page")
      put(socket, %{"op" => "submit", "to" => "/k/widget/new", "values" => %{"title" => title}})
      assert %{"tone" => "pending"} = next(socket, "notice")
    end

    test "a submit waits for Flow to settle, then reads its page once; a recent page it changed is pushed",
         %{port: port} do
      FakeFlow.hold()
      FakeFlow.tell(self())
      a = client(port)
      assert %{"path" => "/"} = next(a, "page")
      create(a, "One")

      # Stored, but Flow is not done: nothing shows yet.
      assert_receive {:settled_asked, 1}, @arrives
      before = FakeStore.reads()
      assert pages(sync(a)) == []
      refute_received {:settled_asked, _}

      FakeFlow.settle(1)
      assert %{"tone" => "ok", "text" => "Stored as W-01 (position 1)."} = next(a, "notice")

      assert %{"path" => "/k/widget/W-01", "reason" => "stored", "position" => 1} =
               next(a, "page")

      # The list it was made from was viewed before, and lists it now.
      assert rows(pushed(a, "/")) == ["One"]
      assert reads_since(before) == ["_page", "_page"]
      refute_received {:settled_asked, _}
    end

    test "a settle timeout sends the page as Facts has it, logs one line, and says nothing more",
         %{port: port} do
      hold_clock()
      FakeFlow.hold()
      a = client(port)
      next(a, "page")
      create(a, "One")
      assert {_, _, 1_000} = wait = held_wait({:settle_timeout, _})

      log =
        capture_log(fn ->
          run_out(wait)

          assert [
                   %{"op" => "notice", "tone" => "ok"},
                   %{"op" => "page", "reason" => "stored", "path" => "/k/widget/W-01"} | rest
                 ] = sync(a)

          # The rest: the list it was made from, pushed, its row still being processed;
          # no notice.
          assert [%{"path" => "/", "reason" => "hint"} = list] = rest
          assert flags(list) == [{"W-01", true}]
        end)

      assert log =~
               "control: settle timeout position=1 budget_ms=1000 settled=none marked_keys=1"

      assert length(String.split(log, "settle timeout")) == 2
      # The wait is over: a late answer from Flow shows no stored page again; it only
      # clears the marker, on the page as it was sent, without a read.
      before = FakeStore.reads()
      FakeFlow.settle(1)
      assert %{"path" => "/", "position" => 1} = list = marked(a)
      assert flags(list) == [{"W-01", false}]
      assert pages(sync(a)) == []
      assert reads_since(before) == []
    end

    test "an open while the write settles: its notice comes, its page does not",
         %{port: port} do
      FakeFlow.hold()
      FakeFlow.tell(self())
      a = client(port)
      next(a, "page")
      create(a, "One")
      assert_receive {:settled_asked, 1}, @arrives
      put(a, %{"op" => "open", "to" => "/k/part"})
      assert %{"path" => "/k/part", "reason" => "open"} = next(a, "page")

      FakeFlow.settle(1)
      assert %{"tone" => "ok"} = next(a, "notice")
      refute Enum.any?(pages(sync(a)), &(&1["reason"] == "stored"))
    end

    test "50 hints and one flush give one read; a hint of something not shown gives none",
         %{port: port} do
      FakeStore.put("W-1", %{"title" => "One"})
      hold_clock()
      a = client(port)
      assert %{"path" => "/"} = next(a, "page")
      before = FakeStore.reads()

      # Flow's writes: no wait for Flow to settle.
      for _ <- 1..50,
          do: FakeStore.hint("widget", "W-1", [changed("widget", "W-1", ["title"])], "flow")

      {pid, _, _} = flush_wait()
      send(pid, :flush)
      assert [%{"reason" => "hint", "path" => "/", "position" => 50}] = pages(sync(a))
      assert reads_since(before) == ["_page"]

      before = FakeStore.reads()
      FakeStore.hint("part", "P-9", [changed("part", "P-9", ["title"])], "flow")
      {pid, _, _} = flush_wait()
      send(pid, :flush)
      assert pages(sync(a)) == []
      assert reads_since(before) == []
    end

    test "others' writes: the flush reads and sends at once; it waits for no Flow work",
         %{port: port} do
      FakeStore.put("W-1", %{"title" => "One"})
      hold_clock()
      # Flow never answers: what another wrote is shown as stored, not once Flow settles.
      FakeFlow.hold()
      FakeFlow.tell(self())
      a = client(port)
      next(a, "page")
      before = FakeStore.reads()

      FakeStore.hint("widget", "W-1", [changed("widget", "W-1", ["title"])], "ada")
      {pid, _, _} = flush_wait()
      send(pid, :flush)
      assert [%{"reason" => "hint", "position" => 1}] = pages(sync(a))
      assert reads_since(before) == ["_page"]
      refute_received {:clock, ^pid, {:settle_timeout, _}, _}
      refute_received {:settled_asked, _}
    end

    test "at most 3 recent pages are pushed per flush, the most recently viewed first; the rest are forgotten",
         %{port: port} do
      for n <- 1..4, do: FakeStore.put("W-#{n}", %{"title" => "#{n}"})
      hold_clock()
      a = client(port)
      next(a, "page")

      for n <- 1..4 do
        put(a, %{"op" => "open", "to" => "/k/widget/W-#{n}"})
        assert %{"path" => "/k/widget/W-" <> _} = next(a, "page")
      end

      put(a, %{"op" => "open", "to" => "/k/part"})
      assert %{"path" => "/k/part"} = next(a, "page")
      before = FakeStore.reads()

      every = for n <- 1..4, do: changed("widget", "W-#{n}", ["title"])
      FakeStore.hint("widget", "W-1", every, "flow")
      {pid, _, _} = flush_wait()
      send(pid, :flush)

      # The page on screen lists parts: not sent again.
      assert for(p <- pages(sync(a)), do: {p["path"], p["reason"]}) == [
               {"/k/widget/W-4", "hint"},
               {"/k/widget/W-3", "hint"},
               {"/k/widget/W-2", "hint"}
             ]

      assert reads_since(before) == ["_page", "_page", "_page"]

      # W-1 and the start page were forgotten: read again only when opened again.
      before = FakeStore.reads()
      FakeStore.hint("widget", "W-1", [changed("widget", "W-1", ["title"])], "flow")
      {pid, _, _} = flush_wait()
      send(pid, :flush)
      assert pages(sync(a)) == []
      assert reads_since(before) == []
    end

    test "a form gets a notice only when what it was read from changed, and is never redrawn",
         %{port: port} do
      FakeStore.put("W-1", %{"title" => "One"})
      FakeStore.put("W-2", %{"title" => "Two"})
      hold_clock()
      a = client(port)
      next(a, "page")
      put(a, %{"op" => "open", "to" => "/k/widget/W-1/edit"})
      assert %{"blocks" => [%{"type" => "form"}]} = next(a, "page")

      # Another widget: no notice. The start page, off screen, lists it: pushed.
      FakeStore.hint("widget", "W-2", [changed("widget", "W-2", ["title"])], "flow")
      {pid, _, _} = flush_wait()
      send(pid, :flush)
      assert [%{"op" => "page", "path" => "/", "reason" => "hint"}] = sync(a)

      FakeStore.hint("widget", "W-1", [changed("widget", "W-1", ["title"])], "flow")
      {pid, _, _} = flush_wait()
      send(pid, :flush)

      assert [%{"op" => "notice", "tone" => "info", "text" => text} | rest] = sync(a)
      assert text == "W-1 was changed elsewhere (position 2)."
      assert for(p <- pages(rest), do: p["path"]) == ["/"]
    end

    test "a submit that changes what is counted: its stored page carries the new count, once" do
      port = gateway(Shop.Assigning)
      FakeStore.put("K-1", %{"title" => "Kay"}, "keeper")
      FakeStore.put("W-1", %{"title" => "One"}, "widget", %{"kept_by" => ["K-1"]})
      FakeStore.put("W-2", %{"title" => "Two"})
      Application.put_env(:atlas_control, :tui_user, "K-1")
      on_exit(fn -> Application.delete_env(:atlas_control, :tui_user) end)

      {:ok, tui} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :line, active: false])

      put(tui, %{
        "op" => "hello",
        "env" => "test",
        "client" => "tui",
        "spec" => AtlasControl.Blocks.version()
      })

      assert %{"count" => "1 kept by you"} = next(tui, "page")
      put(tui, %{"op" => "open", "to" => "/k/widget/W-2/links/kept_by"})
      assert %{"blocks" => [%{"type" => "form"}]} = next(tui, "page")

      put(tui, %{
        "op" => "submit",
        "to" => "/k/widget/W-2/links/kept_by",
        "values" => %{"to" => "K-1"}
      })

      assert %{"path" => "/k/widget/W-2", "reason" => "stored", "count" => "2 kept by you"} =
               next(tui, "page")

      # What is kept by the client, viewed before, is pushed; the page on screen is not sent
      # again.
      assert [%{"path" => "/", "reason" => "hint", "count" => "2 kept by you"}] = pages(sync(tui))
    end

    test "the header's count is read again only when what it was read from changed",
         %{port: _port} do
      port = gateway(Shop.Assigning)
      FakeStore.put("K-1", %{"title" => "Kay"}, "keeper")
      FakeStore.put("W-1", %{"title" => "One"}, "widget", %{"kept_by" => ["K-1"]})
      FakeStore.put("W-2", %{"title" => "Two"})
      Application.put_env(:atlas_control, :tui_user, "K-1")
      on_exit(fn -> Application.delete_env(:atlas_control, :tui_user) end)
      hold_clock()

      {:ok, tui} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :line, active: false])

      put(tui, %{
        "op" => "hello",
        "env" => "test",
        "client" => "tui",
        "spec" => AtlasControl.Blocks.version()
      })

      assert %{"title" => "Kept by you", "count" => "1 kept by you"} = next(tui, "page")

      # Another page reuses the count: one read, for the page.
      before = FakeStore.reads()
      put(tui, %{"op" => "open", "to" => "/k/part"})
      assert %{"path" => "/k/part", "count" => "1 kept by you"} = next(tui, "page")
      assert reads_since(before) == ["_page"]

      # A widget not kept by the client changed: nothing it counts.
      before = FakeStore.reads()
      FakeStore.hint("widget", "W-2", [changed("widget", "W-2", ["title"])], "flow")
      {pid, _, _} = flush_wait()
      send(pid, :flush)
      assert pages(sync(tui)) == []
      assert reads_since(before) == []

      # It is kept by the client now: the count is read again, with the page it heads.
      FakeStore.put("W-2", %{"title" => "Two"}, "widget", %{"kept_by" => ["K-1"]})

      FakeStore.hint(
        "widget",
        "W-2",
        [changed("widget", "W-2", [], %{"kept_by" => ["K-1"]}, ["kept_by"])],
        "flow"
      )

      {pid, _, _} = flush_wait()
      send(pid, :flush)

      # The page on screen with its count, then what is kept by the client, pushed.
      assert [
               %{"path" => "/k/part", "reason" => "hint", "count" => "2 kept by you"},
               %{"path" => "/", "reason" => "hint", "title" => "Kept by you"} = kept
             ] = pages(sync(tui))

      assert rows(kept) == ["One", "Two"] or rows(kept) == ["Two", "One"]
      assert reads_since(before) == ["_page", "_page", "_page"]
    end

    test "a marked key's row carries pending on every page and push; an unrelated row is not marked",
         %{port: port} do
      FakeStore.put("W-1", %{"title" => "One"})
      FakeStore.put("W-2", %{"title" => "Two"})
      hold_clock()
      FakeFlow.hold()
      FakeFlow.tell(self())
      a = client(port)
      assert %{"path" => "/", "position" => 0} = start = next(a, "page")
      assert flags(start) == [{"W-1", false}, {"W-2", false}]
      edit(a, "W-1")
      before = FakeStore.reads()
      submit_title(a, "W-1", "Uno")

      # Stored, not settled: the list viewed before is sent again as it was, with the same
      # position, its row of W-1 marked; no read. The marker says nothing of the outcome:
      # the row's label is still the one read.
      assert_receive {:settled_asked, 1}, @arrives
      wait = held_wait({:settle_timeout, _})
      assert [%{"path" => "/", "reason" => "pending", "position" => 0} = overlay] = pages(sync(a))
      assert flags(overlay) == [{"W-1", true}, {"W-2", false}]
      assert rows(overlay) == rows(start)

      assert Map.drop(overlay, ["blocks", "reason", "at"]) ==
               Map.drop(start, ["blocks", "reason", "at"])

      assert reads_since(before) == []

      # The settle timeout: the stored page and the list's push, still marked.
      log =
        capture_log(fn ->
          run_out(wait)

          assert [
                   %{"path" => "/k/widget/W-1", "reason" => "stored"},
                   %{"path" => "/", "reason" => "hint", "position" => 1} = pushed
                 ] = pages(sync(a))

          assert rows(pushed) == ["Uno", "Two"]
          assert flags(pushed) == [{"W-1", true}, {"W-2", false}]
        end)

      assert log =~ "control: settle timeout position=1 budget_ms=1000 settled=none marked_keys=1"

      # Opened again: still marked.
      put(a, %{"op" => "open", "to" => "/"})
      assert %{"path" => "/", "reason" => "open"} = opened = next(a, "page")
      assert flags(opened) == [{"W-1", true}, {"W-2", false}]

      # A reconcile: nothing new in Facts, so no page; Flow is asked again, briefly.
      put(a, %{"op" => "refresh"})
      assert_receive {:settled_asked, 1}, @arrives
      assert {_, _, 250} = wait = held_wait({:settle_timeout, _})
      run_out(wait)
      assert pages(sync(a)) == []

      # A hint of W-2 (Flow's): the flush sends the page at once, marking W-1 only, and only
      # then asks Flow again.
      FakeStore.hint("widget", "W-2", [changed("widget", "W-2", ["title"])], "flow")
      {pid, _, _} = flush_wait()
      send(pid, :flush)
      assert [%{"path" => "/", "reason" => "hint", "position" => 2} = hinted] = pages(sync(a))
      assert flags(hinted) == [{"W-1", true}, {"W-2", false}]
      assert_receive {:settled_asked, 1}, @arrives
      assert {_, _, 250} = wait = held_wait({:settle_timeout, _})
      run_out(wait)
      assert pages(sync(a)) == []

      # Flow settles: the marker goes from the page on screen, as it was sent, no read.
      before = FakeStore.reads()
      FakeFlow.settle(1)
      assert %{"path" => "/", "position" => 2} = cleared = marked(a)
      assert flags(cleared) == [{"W-1", false}, {"W-2", false}]
      assert pages(sync(a)) == []
      assert reads_since(before) == []

      # Nothing is held any more: a reconcile asks Flow nothing, and sends no page.
      put(a, %{"op" => "refresh"})
      assert pages(sync(a)) == []
      refute_received {:settled_asked, _}
    end

    test "marks clear on settled: the stored page and the pushes read after it carry none",
         %{port: port} do
      FakeStore.put("W-1", %{"title" => "One"})
      FakeFlow.hold()
      FakeFlow.tell(self())
      a = client(port)
      next(a, "page")
      put(a, %{"op" => "open", "to" => "/k/widget/W-1"})
      assert %{"path" => "/k/widget/W-1"} = next(a, "page")
      edit(a, "W-1")
      submit_title(a, "W-1", "Uno")
      assert_receive {:settled_asked, 1}, @arrives
      assert [%{"path" => "/"} = overlay] = pages(sync(a))
      assert flags(overlay) == [{"W-1", true}]

      before = FakeStore.reads()
      FakeFlow.settle(1)
      assert %{"tone" => "ok"} = next(a, "notice")

      assert [
               %{"path" => "/k/widget/W-1", "reason" => "stored", "position" => 1},
               %{"path" => "/", "reason" => "hint"} = pushed
             ] = pages(sync(a))

      assert rows(pushed) == ["Uno"]
      assert flags(pushed) == [{"W-1", false}]
      assert reads_since(before) == ["_page", "_page"]
      refute_received {:settled_asked, _}
    end

    test "a second submit before the first settles: each keeps its own marks",
         %{port: port} do
      FakeStore.put("W-1", %{"title" => "One"})
      FakeStore.put("W-2", %{"title" => "Two"})
      hold_clock()
      FakeFlow.hold()
      FakeFlow.tell(self())
      a = client(port)
      next(a, "page")

      edit(a, "W-1")
      submit_title(a, "W-1", "Uno")
      assert_receive {:settled_asked, 1}, @arrives
      held_wait({:settle_timeout, _})
      assert [overlay] = pages(sync(a))
      assert flags(overlay) == [{"W-1", true}, {"W-2", false}]

      edit(a, "W-2")
      submit_title(a, "W-2", "Dos")
      assert_receive {:settled_asked, 2}, @arrives
      held_wait({:settle_timeout, _})
      assert [%{"path" => "/", "reason" => "pending"} = overlay] = pages(sync(a))
      assert flags(overlay) == [{"W-1", true}, {"W-2", true}]

      # Flow settled past the first write only: its mark goes, the second's stays.
      FakeFlow.settle(1)
      assert flags(marked(a)) == [{"W-1", false}, {"W-2", true}]

      FakeFlow.settle(2)
      assert %{"tone" => "ok", "text" => "Stored by Facts (position 2)."} = next(a, "notice")

      assert [%{"path" => "/k/widget/W-2", "reason" => "stored"}, %{"path" => "/"} = pushed] =
               pages(sync(a))

      assert rows(pushed) == ["Uno", "Dos"]
      assert flags(pushed) == [{"W-1", false}, {"W-2", false}]
    end

    test "nothing is marked before Facts stored a write, nor when it refused it",
         %{port: port} do
      FakeStore.put("W-1", %{"title" => "One"})
      FakeFlow.tell(self())
      a = client(port)
      next(a, "page")

      # Facts has not answered: the client is told it waits, and no page changes.
      FakeStore.silent(true)
      edit(a, "W-1")
      submit_title(a, "W-1", "Uno")
      assert [%{"op" => "notice", "tone" => "pending"}] = sync(a)
      FakeStore.silent(false)

      FakeStore.refuse("W-1", "no")
      edit(a, "W-1")
      submit_title(a, "W-1", "Uno")
      assert %{"reason" => "refused"} = next(a, "page")
      put(a, %{"op" => "open", "to" => "/"})
      assert flags(next(a, "page")) == [{"W-1", false}]
      refute Enum.any?(pages(sync(a)), &(&1["reason"] == "pending"))
      refute_received {:settled_asked, _}
    end

    test "a reconcile reads Facts' position only; the page again only past what the session saw (F9)",
         %{port: port} do
      FakeStore.put("W-1", %{"title" => "One"})
      a = client(port)
      assert %{"path" => "/"} = next(a, "page")

      # Nothing happened since the page was read: one position read, no page, and the model
      # is never asked for again.
      before = FakeStore.reads()
      put(a, %{"op" => "refresh"})
      assert pages(sync(a)) == []
      assert reads_since(before) == ["_position"]

      # A hint the session had (handled at its flush): Facts is not past it.
      hold_clock()
      FakeStore.hint("part", "P-9", [changed("part", "P-9", ["title"])])
      {pid, _, _} = flush_wait()
      send(pid, :flush)
      assert pages(sync(a)) == []
      before = FakeStore.reads()
      put(a, %{"op" => "refresh"})
      assert pages(sync(a)) == []
      assert reads_since(before) == ["_position"]

      # A write whose hint was lost: Facts is past it, so the page is read again, once.
      :ok = AtlasBus.drop_hints(1)
      FakeStore.put("W-1", %{"title" => "Uno"})
      FakeStore.hint("widget", "W-1", [changed("widget", "W-1", ["title"])])
      assert pages(sync(a)) == []
      before = FakeStore.reads()
      put(a, %{"op" => "refresh"})
      assert [%{"path" => "/", "reason" => "reconcile", "position" => 2} = page] = pages(sync(a))
      assert rows(page) == ["Uno"]
      # Who the client is is found again too (a lost hint may have been about it).
      assert reads_since(before) == ["_position", "member", "_page"]

      # Seen now: the next reconcile reads the position only again.
      before = FakeStore.reads()
      put(a, %{"op" => "refresh"})
      assert pages(sync(a)) == []
      assert reads_since(before) == ["_position"]

      # A value on the page changes by time alone, and that time has passed: read again,
      # without asking the position first.
      FakeStore.until("2000-01-01T00:00:00Z")
      put(a, %{"op" => "open", "to" => "/"})
      assert %{"path" => "/"} = next(a, "page")
      before = FakeStore.reads()
      put(a, %{"op" => "refresh"})
      assert [%{"path" => "/", "reason" => "reconcile"}] = pages(sync(a))
      assert reads_since(before) == ["_page"]
    end

    test "a session that closes drops its marks: a new one shows Facts' state unmarked",
         %{port: port} do
      FakeStore.put("W-1", %{"title" => "One"})
      FakeFlow.hold()
      FakeFlow.tell(self())
      a = client(port)
      next(a, "page")
      edit(a, "W-1")
      submit_title(a, "W-1", "Uno")
      assert_receive {:settled_asked, 1}, @arrives
      assert [overlay] = pages(sync(a))
      assert flags(overlay) == [{"W-1", true}]

      assert [session] =
               for(
                 {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasControl.Sessions),
                 do: pid
               )

      ref = Process.monitor(session)
      :gen_tcp.close(a)
      assert_receive {:DOWN, ^ref, :process, ^session, _}, @arrives

      b = client(port)
      assert %{"path" => "/"} = start = next(b, "page")
      assert rows(start) == ["Uno"]
      assert flags(start) == [{"W-1", false}]
      # A reconcile has nothing to add, and no mark to send.
      put(b, %{"op" => "refresh"})
      assert pages(sync(b)) == []
      refute_received {:settled_asked, _}
    end
  end
end

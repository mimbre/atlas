defmodule AtlasRuntimeBackend.Generator.Targets.RestContractsTest do
  @moduledoc """
  One router for several contracts (`contracts:`): each route reaches its own contract's
  facade with its own statuses, the facades' refusals are answered alike for every
  contract, and the router refuses at compile time what one router cannot serve.
  """
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias AtlasRuntimeBackend.Generator.Example.{Combined, DeskFacade, Facade}

  @staff {"ann", [:lend, :browse, :staff, :visit]}

  defp request(method, path, body \\ "", client \\ @staff) do
    conn(method, path, body) |> assign(:client, client) |> Combined.call(Combined.init([]))
  end

  defp json(conn), do: JSON.decode!(conn.resp_body)

  defp problem(conn, status, type) do
    assert conn.status == status
    assert get_resp_header(conn, "content-type") == ["application/problem+json"]
    assert %{"type" => ^type, "status" => ^status} = body = json(conn)
    body
  end

  describe "one router, each route to its own contract" do
    test "routes of both contracts reach their own facade" do
      conn = request("GET", "/v1/books/b1")
      assert conn.status == 200
      assert_received {:example_called, :find_book, @staff, %Facade.FindBookInput{book_id: "b1"}}
      refute_received {:desk_called, _, _, _}

      conn = request("POST", "/v1/desk/close", ~s({"hard":true}))
      assert conn.status == 202
      assert json(conn) == %{"open" => false, "seats" => 4}
      assert_received {:desk_called, :close_desk, @staff, %DeskFacade.CloseInput{hard: true}}
      refute_received {:example_called, _, _, _}

      assert request("POST", "/v1/desk/open").status == 200
      assert request("GET", "/v1/count").status == 200
    end

    test "the stream of the one contract that has it" do
      conn = request("GET", "/v1/events", "")
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    end

    test "an outcome name both contracts have keeps each contract's status" do
      # refused: by reason, with each contract's own cases.
      problem(request("GET", "/v1/seats/taken"), 409, "occupied")
      problem(request("GET", "/v1/seats/odd"), 400, "invalid")
      problem(request("POST", "/v1/books", ~s({"title":"taken"})), 409, "taken")
      problem(request("POST", "/v1/books", ~s({"title":"not yours"})), 403, "not-permitted")

      assert problem(request("GET", "/v1/seats/none"), 404, "not-found") |> map_size() == 3
      assert problem(request("GET", "/v1/books/missing"), 404, "not-found") |> map_size() == 3
    end

    test "a request no contract routes is the router's own no-route" do
      problem(request("GET", "/v1/desk"), 404, "no-route")
      problem(request("GET", "/v1/desk/open"), 404, "no-route")
    end
  end

  describe "the facades' refusals, alike for every contract" do
    test "a client without the right: 403 not-permitted, for either contract" do
      guest = {"guest", [:browse, :visit]}

      body = problem(request("POST", "/v1/desk/open", "", guest), 403, "not-permitted")
      assert body["detail"] =~ "staff"

      body =
        problem(request("POST", "/v1/books", ~s({"title":"Dune"}), guest), 403, "not-permitted")

      assert body["detail"] =~ "lend"

      # A route of the other contract with the right still answers.
      assert request("GET", "/v1/seats/s1", "", guest).status == 200
    end

    test "an input the facade does not accept: 400 invalid, for either contract" do
      body = problem(request("GET", "/v1/seats/unchecked"), 400, "invalid")
      assert body["detail"] == "seat is not checked"
      body = problem(request("POST", "/v1/books", ~s({"title":"unchecked"})), 400, "invalid")
      assert body["detail"] == "title is not checked"
    end

    test "any other value that is no outcome raises" do
      assert_raise ArgumentError, ~r/no declared outcome/, fn ->
        request("POST", "/v1/books", ~s({"title":"undeclared"}))
      end
    end
  end

  test "__rights__/1: every contract's rights on a listener, in contract order, each once" do
    assert Combined.__rights__(:socket) == [:lend, :browse, :staff, :visit]
    assert Combined.__rights__(:guest) == [:browse, :visit]
    assert_raise KeyError, fn -> Combined.__rights__(:tcp) end
  end

  test "__routes__/0 names each route's contract" do
    by_capability = Map.new(Combined.__routes__(), &{&1.capability, &1})
    assert %{contract: :lending, path: "/v1/books/:book_id"} = by_capability.find_book
    assert %{contract: :lending, stream: true} = by_capability.watch

    assert %{contract: :desk, method: :post, path: "/v1/desk/close", outcomes: [closing]} =
             by_capability.close_desk

    assert %{outcome: :closing, status: 202} = closing
  end

  ## Compile errors, on contracts written on the spot over Example.Things

  @errors """
      error :invalid, 400, type: "invalid"
      error :not_permitted, 403, type: "not-permitted"
      error :no_route, 404, type: "no-route"
  """

  @things [:get_thing, :latest_thing, :thing_parts, :watch_things]

  # A backend contract over Example.Things exposing `exposed`, with `routes` in its target.
  defp contract(exposed, routes, opts \\ []) do
    module =
      :"Elixir.AtlasRuntimeBackend.Generator.RestContractsTest.C#{System.unique_integer([:positive])}"

    not_exposed = @things -- exposed
    errors = Keyword.get(opts, :errors, @errors)

    statuses =
      [
        if(Enum.any?(exposed, &(&1 != :watch_things)), do: "status :shown, 200"),
        Keyword.get(opts, :statuses)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    Code.compile_string("""
    defmodule #{inspect(module)} do
      use AtlasRuntimeBackend.Generator.Schema
      version "1.0.0"
      boundary AtlasRuntimeBackend.Generator.Example.Things
      #{if exposed != [], do: "expose #{inspect(exposed)}"}
      #{if not_exposed != [], do: "not_exposed #{inspect(not_exposed)}"}
      rights :socket, [:look]
      event :thing, :thing

      target :rest do
        #{routes}
        #{statuses}
    #{errors}
      end
    end
    """)

    module
  end

  defp router(contracts) do
    module =
      :"Elixir.AtlasRuntimeBackend.Generator.RestContractsTest.R#{System.unique_integer([:positive])}"

    entries =
      Enum.map_join(contracts, ",\n", fn {name, contract, extra} ->
        "#{name}: {#{inspect(contract)}, #{extra}}"
      end)

    Code.compile_string("""
    defmodule #{inspect(module)} do
      use AtlasRuntimeBackend.Generator.Targets.Rest, contracts: [#{entries}]
    end
    """)

    module
  end

  @a "facade: AtlasRuntimeBackend.Generator.Example.ThingsA"
  @b "facade: AtlasRuntimeBackend.Generator.Example.ThingsB"
  @loop "stream: AtlasRuntimeBackend.Generator.Example.Loop"

  describe "the per-contract checks still hold" do
    test "(a) a capability neither exposed nor not_exposed" do
      error =
        assert_raise CompileError, fn ->
          Code.compile_string("""
          defmodule AtlasRuntimeBackend.Generator.RestContractsTest.Unmarked do
            use AtlasRuntimeBackend.Generator.Schema
            version "1.0.0"
            boundary AtlasRuntimeBackend.Generator.Example.Things
            expose [:get_thing]
            not_exposed [:latest_thing, :thing_parts]

            target :rest do
              resource :get, "/v1/things/:thing_id", capability: :get_thing
              status :shown, 200
          #{@errors}
            end
          end
          """)
        end

      assert Exception.message(error) =~ "neither exposed nor not_exposed"
      assert Exception.message(error) =~ ":watch_things"
    end

    test "(b) an exposed capability no resource maps" do
      error =
        assert_raise CompileError, fn ->
          contract(
            [:get_thing, :latest_thing],
            ~s(resource :get, "/v1/latest", capability: :latest_thing)
          )
        end

      assert Exception.message(error) =~ "does not map the exposed capability :get_thing"
    end
  end

  describe "overlapping paths across contracts" do
    test "(c) a literal against a parameter is an overlap" do
      a =
        contract([:get_thing], ~s(resource :get, "/v1/things/:thing_id", capability: :get_thing))

      b =
        contract(
          [:latest_thing],
          ~s(resource :get, "/v1/things/latest", capability: :latest_thing)
        )

      error = assert_raise CompileError, fn -> router([{:a, a, @a}, {:b, b, @b}]) end

      assert Exception.message(error) =~
               "overlapping paths: GET /v1/things/:thing_id (a) and GET /v1/things/latest (b)"
    end

    test "the same path, and a stream's path, overlap too" do
      a = contract([:latest_thing], ~s(resource :get, "/v1/things", capability: :latest_thing))

      b =
        contract(
          [:get_thing],
          ~s(resource :get, "/v1/things", capability: :get_thing, query: [id: :thing_id])
        )

      assert_raise CompileError, ~r/overlapping paths/, fn ->
        router([{:a, a, @a}, {:b, b, @b}])
      end

      a = contract([:get_thing], ~s(resource :get, "/v1/:thing_id", capability: :get_thing))

      b =
        contract(
          [:watch_things],
          ~s(stream "/v1/events", capability: :watch_things, events: [:thing], resume_header: "Last-Event-ID", into: :from, open: [watching: nil])
        )

      assert_raise CompileError, ~r/overlapping paths/, fn ->
        router([{:a, a, @a}, {:b, b, "#{@b}, #{@loop}"}])
      end
    end

    test "(d) as many parameters but a different count of segments, or another method, compile" do
      a =
        contract([:get_thing], ~s(resource :get, "/v1/things/:thing_id", capability: :get_thing))

      b =
        contract(
          [:thing_parts, :latest_thing],
          """
          resource :get, "/v1/things/:thing_id/parts", capability: :thing_parts
          resource :post, "/v1/things/latest", capability: :latest_thing
          """
        )

      r = router([{:a, a, @a}, {:b, b, @b}])
      client = {"x", [:look]}

      for {method, path, id} <- [
            {"GET", "/v1/things/t1", "t1"},
            {"GET", "/v1/things/t2/parts", "t2"},
            {"POST", "/v1/things/latest", "latest"}
          ] do
        conn = conn(method, path) |> assign(:client, client) |> r.call([])
        assert {conn.status, json(conn)} == {200, %{"thing_id" => id}}
      end
    end

    test "within one contract, its own rules still decide: a literal beats a parameter" do
      a =
        contract(
          [:get_thing, :latest_thing],
          """
          resource :get, "/v1/things/:thing_id", capability: :get_thing
          resource :get, "/v1/things/latest", capability: :latest_thing
          """
        )

      r = router([{:a, a, @a}])
      conn = conn("GET", "/v1/things/latest") |> assign(:client, {"x", [:look]}) |> r.call([])
      assert json(conn) == %{"thing_id" => "latest"}
    end
  end

  describe "what one router cannot serve" do
    @watch ~s(stream "/v1/events", capability: :watch_things, events: [:thing], resume_header: "Last-Event-ID", into: :from, open: [watching: nil])

    test "(e) more than one stream" do
      a = contract([:watch_things], @watch)
      b = contract([:watch_things], String.replace(@watch, "/v1/events", "/v1/other-events"))

      error =
        assert_raise CompileError, fn ->
          router([{:a, a, "#{@a}, #{@loop}"}, {:b, b, "#{@b}, #{@loop}"}])
        end

      assert Exception.message(error) =~ "more than one stream"
      assert Exception.message(error) =~ "a router has one event stream"
    end

    test "errors that differ between contracts" do
      a =
        contract([:get_thing], ~s(resource :get, "/v1/things/:thing_id", capability: :get_thing))

      b =
        contract([:latest_thing], ~s(resource :get, "/v1/latest", capability: :latest_thing),
          errors: String.replace(@errors, ~s(404, type: "no-route"), ~s(404, type: "nowhere"))
        )

      assert_raise CompileError, ~r/contracts a and b declare different errors/, fn ->
        router([{:a, a, @a}, {:b, b, @b}])
      end
    end

    test "a name, a contract or a facade given twice" do
      a =
        contract([:get_thing], ~s(resource :get, "/v1/things/:thing_id", capability: :get_thing))

      b = contract([:latest_thing], ~s(resource :get, "/v1/latest", capability: :latest_thing))

      assert_raise CompileError, ~r/the name :a is given twice/, fn ->
        router([{:a, a, @a}, {:a, b, @b}])
      end

      assert_raise CompileError, ~r/the contract .* is given twice \(:a, :b\)/, fn ->
        router([{:a, a, @a}, {:b, a, @b}])
      end

      assert_raise CompileError, ~r/the facade .*ThingsA is given twice/, fn ->
        router([{:a, a, @a}, {:b, b, @a}])
      end
    end

    test "a malformed contracts: entry, and contracts: with the one-contract options" do
      assert_raise CompileError, ~r/contracts: a is \{Contract, facade: \.\.\.\}/, fn ->
        Code.compile_string("""
        defmodule AtlasRuntimeBackend.Generator.RestContractsTest.Bad1 do
          use AtlasRuntimeBackend.Generator.Targets.Rest, contracts: [a: AtlasRuntimeBackend.Generator.Example.Api]
        end
        """)
      end

      assert_raise CompileError, ~r/contracts: a takes facade:/, fn ->
        Code.compile_string("""
        defmodule AtlasRuntimeBackend.Generator.RestContractsTest.Bad2 do
          use AtlasRuntimeBackend.Generator.Targets.Rest,
            contracts: [a: {AtlasRuntimeBackend.Generator.Example.Api, stream: X}]
        end
        """)
      end

      assert_raise CompileError, ~r/takes contracts: \[name:/, fn ->
        Code.compile_string("""
        defmodule AtlasRuntimeBackend.Generator.RestContractsTest.Bad3 do
          use AtlasRuntimeBackend.Generator.Targets.Rest,
            contracts: [], facade: AtlasRuntimeBackend.Generator.Example.Facade
        end
        """)
      end
    end
  end
end

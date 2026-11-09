defmodule AtlasBFF.Targets.SwiftTest do
  use ExUnit.Case, async: true

  alias AtlasBFF.Header
  alias AtlasBFF.Targets.Swift

  # A plain-data contract, not the DSL: the target reads only `__schema__/0`'s data. Two
  # channels; a request that takes a model, a reply with a view model, one that carries a
  # block, a push, and two replies of one op told apart by a field's presence.
  @page_fields %{"path" => :string, "title" => :string, "blocks" => :list, "markup" => :list}

  @schema %{
    version: "3.1.0",
    file: "/contracts/neutral.ex",
    models: [
      %{
        name: :link,
        fields: [
          %{name: :label, type: :string, required: true},
          %{name: :to, type: :string, required: false}
        ]
      },
      %{
        name: :greeting,
        fields: [
          %{name: :name, type: :string, required: true},
          %{name: :tags, type: {:map, :string}, required: false},
          %{name: :links, type: {:list, :link}, required: false}
        ]
      }
    ],
    blocks: [
      %{
        name: :card,
        fields: [
          %{name: :title, type: :string, required: true},
          %{name: :count, type: :integer, required: false},
          %{name: :links, type: {:list, :link}, required: false},
          %{name: :in, type: :boolean, required: false}
        ]
      },
      %{name: :rule_line, fields: []}
    ],
    markup: [%{name: :group, fields: [%{name: :title, type: :string, required: true}]}],
    pages: [
      %{name: :home, path: "/", params: []},
      %{name: :card, path: "/cards/:id", params: [:id]},
      %{name: :new_card, path: "/cards/new", params: []}
    ],
    protocol: [
      %{
        name: :greet,
        channel: :front,
        direction: :request,
        request: %{
          select: %{"op" => "greet"},
          required: %{"name" => :string, "links" => :list},
          optional: %{"tags" => {:map, :string}}
        },
        replies: [
          %{
            name: :hi,
            # A literal more than the op names no case while the op is unique.
            select: %{"op" => "hi", "version" => "1.0"},
            effect: :progress,
            required: %{"name" => :string}
          },
          %{
            name: :page,
            select: %{"op" => "page", "reason" => "open"},
            effect: :complete,
            required: @page_fields,
            optional: %{"position" => :integer}
          }
        ]
      },
      %{
        name: :look,
        channel: :front,
        direction: :request,
        request: %{select: %{"op" => "look"}, optional: %{"to" => :string}},
        replies: [
          %{
            name: :seen,
            select: %{"op" => "look"},
            absent: ["error"],
            effect: :complete,
            required: %{"links" => :list}
          },
          %{
            name: :error,
            select: %{"op" => "look"},
            present: ["error"],
            effect: :error,
            required: %{"error" => :string}
          }
        ]
      },
      %{
        name: :nudge,
        channel: :front,
        direction: :push,
        replies: [
          %{
            name: :page,
            select: %{"op" => "page", "reason" => "nudge"},
            effect: :progress,
            required: @page_fields,
            optional: %{"position" => :integer}
          }
        ]
      },
      %{
        name: :sketch,
        channel: :side,
        direction: :stream,
        request: %{select: %{"op" => "sketch"}},
        replies: [
          %{
            name: :drawn,
            select: %{"op" => "drawn"},
            effect: :progress,
            required: %{"block" => :map}
          }
        ]
      },
      %{
        name: :unused,
        channel: :elsewhere,
        direction: :request,
        request: %{select: %{"op" => "unused"}},
        replies: [%{name: :ok, select: %{"op" => "ok"}, effect: :complete}]
      }
    ],
    endpoints: [
      %{
        wire: :greet,
        name: :greet,
        call: :greet,
        page: nil,
        path: nil,
        params: [],
        takes: :greeting,
        replies: [%{name: :hi, returns: :greeting}, %{name: :page, returns: :view_model}]
      },
      %{
        wire: :look,
        name: :look,
        call: :look,
        page: nil,
        path: nil,
        params: [],
        takes: nil,
        replies: [%{name: :seen, returns: :greeting}, %{name: :error, returns: :greeting}]
      },
      %{
        wire: :nudge,
        name: :nudge,
        call: :page,
        page: nil,
        path: nil,
        params: [],
        takes: nil,
        replies: [%{name: :page, returns: :view_model}]
      },
      %{
        wire: :sketch,
        name: :sketch,
        call: :sketch,
        page: nil,
        path: nil,
        params: [],
        takes: nil,
        replies: [%{name: :drawn, returns: :card}]
      }
    ]
  }

  defp files(schema \\ @schema, opts \\ [package: "MyKit"]),
    do: Map.new(Swift.files(schema, opts))

  defp file(name, schema \\ @schema), do: files(schema) |> Map.fetch!(name)

  test "a package of the contract: its manifest, sources and tests, for macOS and iOS" do
    assert files() |> Map.keys() |> Enum.sort() == [
             "Package.swift",
             "Sources/MyKit/Blocks.swift",
             "Sources/MyKit/Contract.swift",
             "Sources/MyKit/Fallback.swift",
             "Sources/MyKit/JSONValue.swift",
             "Sources/MyKit/Markup.swift",
             "Sources/MyKit/Messages.swift",
             "Sources/MyKit/Models.swift",
             "Sources/MyKit/Pages.swift",
             "Tests/MyKitTests/ContractTests.swift",
             "Tests/MyKitTests/FixtureTests.swift"
           ]

    manifest = file("Package.swift")
    assert manifest =~ ~r/\A\/\/ swift-tools-version: 6\.0\n/
    assert manifest =~ ~s|.library(name: "MyKit", targets: ["MyKit"])|
    assert manifest =~ "platforms: [.macOS(.v14), .iOS(.v17)]"
    assert manifest =~ "swiftLanguageModes: [.v6]"
    assert file("Sources/MyKit/Contract.swift") =~ ~s(public static let version = "3.1.0")

    assert Swift.files(@schema)
           |> Enum.map(&elem(&1, 0))
           |> Enum.all?(&(&1 == "Package.swift" or &1 =~ "ContractKit"))

    assert_raise ArgumentError, ~r/package/, fn -> Swift.files(@schema, package: "my kit") end
  end

  test "Foundation only: no platform framework in what it writes" do
    for {path, body} <- files() do
      for import <-
            Regex.scan(~r/^import (\w+)/m, body, capture: :all_but_first) |> List.flatten() do
        assert import in ~w(Foundation PackageDescription XCTest MyKit),
               "#{path} imports #{import}"
      end
    end
  end

  test "every file carries the generated header, which --check recognises" do
    for {path, body} <- files() do
      written = Header.put(Path.extname(path), "contracts/neutral.ex", body)
      assert Header.generated?(Path.extname(path), written), path
      refute Header.generated?(Path.extname(path), body), path
    end

    manifest = Header.put(".swift", "c.ex", file("Package.swift"))
    assert [tools, header | _] = String.split(manifest, "\n")
    assert tools == "// swift-tools-version: 6.0"
    assert header == "// " <> Header.text("c.ex")
  end

  test "a struct per model, block and kind of markup, required fields required" do
    models = file("Sources/MyKit/Models.swift")
    blocks = file("Sources/MyKit/Blocks.swift")
    markup = file("Sources/MyKit/Markup.swift")

    for {source, type} <- [
          {models, "LinkModel"},
          {models, "GreetingModel"},
          {blocks, "CardBlock"},
          {blocks, "RuleLineBlock"},
          {markup, "GroupMarkup"}
        ] do
      assert source =~ "public struct #{type}: Codable, Sendable, Equatable {"
    end

    assert models =~ "    public var label: String\n"
    assert models =~ "    public var to: String?\n"
    assert models =~ "    public var tags: [String: String]?\n"
    assert models =~ "    public var links: [LinkModel]?\n"
    assert blocks =~ "    public var title: String\n"
    assert blocks =~ "    public var count: Int?\n"
    # A Swift keyword is escaped; a snake_case name is camelCased, keyed by its wire name.
    assert blocks =~ "    public var `in`: Bool?\n"

    assert blocks =~
             "public init(title: String, count: Int? = nil, links: [LinkModel]? = nil, `in`: Bool? = nil)"

    assert markup =~ "    public var title: String\n"
  end

  test "an unknown or broken block, or markup entry, falls back with a reason and its JSON" do
    blocks = file("Sources/MyKit/Blocks.swift")

    assert blocks =~
             "        case card(CardBlock)\n        case ruleLine(RuleLineBlock)\n        case fallback(Fallback)\n"

    # The reason is a case (and a path), never text: the tests compare those.
    assert blocks =~ "reason: .untyped, raw: raw"
    assert blocks =~ "reason: .unknownType, raw: raw"
    assert blocks =~ "reason: Fallback.Reason(error), raw: raw"
    assert blocks =~ "case .fallback(let fallback): try fallback.raw.encode(to: encoder)"

    markup = file("Sources/MyKit/Markup.swift")
    assert markup =~ "case group(GroupMarkup)\n        case fallback(Fallback)\n"
    assert markup =~ "reason: .noRange, raw: raw"
    assert markup =~ "reason: .unknownType, raw: raw"

    fallback = file("Sources/MyKit/Fallback.swift")

    for reason <-
          ~w(untyped unknownType noRange missing(path: wrongType(path: invalid(path: undecodable) do
      assert fallback =~ "        case #{reason}", reason
    end

    named = put_in(@schema, [:blocks], [%{name: :fallback, fields: []}])
    assert_raise ArgumentError, ~r/named fallback/, fn -> Swift.files(named) end
  end

  test "pages build and match their paths by the rules of AtlasBFF.Paths" do
    pages = file("Sources/MyKit/Pages.swift")
    assert pages =~ "    case home\n    case card\n    case newCard = \"new_card\"\n"
    assert pages =~ ~s|case .card: "/cards/:id"|
    assert pages =~ "public static func match(_ path: String) -> PageMatch?"

    assert pages =~
             "public func path(_ params: [String: String] = [:]) throws(PathError) -> String"
  end

  # What the target makes of the descriptors, as data; the generated Swift tests check what
  # the code does with it.
  defp channel(name), do: Swift.messages(@schema) |> Enum.find(&(&1.channel == name))
  defp cases(list), do: Enum.map(list, &{&1.case, &1.struct})
  defp types(msg), do: Map.new(msg.fields, &{&1.name, {&1.type, &1.required}})

  test "the messages of each channel the endpoints name, keyed on op and selectors" do
    # A descriptor no endpoint names is not a message of the package.
    assert Swift.messages(@schema) |> Enum.map(& &1.channel) == [:front, :side]

    front = channel(:front)
    # Requests, by wire descriptor; a request without fields has no struct.
    assert cases(front.requests) == [{"greet", "GreetRequest"}, {"look", "LookRequest"}]
    assert cases(channel(:side).requests) == [{"sketch", nil}]

    # A case per reply and push, by its op alone while the op is unique (hi has a literal
    # more); by its other literals where an op has several (pageOpen, pageNudge, which
    # share a struct, being of one shape); by the reply's name where those are not enough.
    assert cases(front.messages) == [
             {"hi", "HiMessage"},
             {"pageOpen", "PageMessage"},
             {"lookSeen", "LookSeenMessage"},
             {"lookError", "LookErrorMessage"},
             {"pageNudge", "PageMessage"}
           ]

    [_hi, _open, seen, error, nudge] = front.messages
    assert nudge.literals == [{"op", "page"}, {"reason", "nudge"}]
    assert {seen.absent, error.present} == {["error"], ["error"]}

    assert cases(channel(:side).messages) == [{"drawn", "DrawnMessage"}]

    for reserved <- [:unknown, :undecodable] do
      [greet | rest] = @schema.protocol
      reply = %{name: reserved, select: %{"op" => to_string(reserved)}, effect: :progress}
      schema = %{@schema | protocol: [%{greet | replies: greet.replies ++ [reply]} | rest]}
      assert_raise ArgumentError, ~r/no Swift case/, fn -> Swift.messages(schema) end
    end
  end

  test "a received message of a known case whose fields fail is undecodable, never a throw" do
    messages = file("Sources/MyKit/Messages.swift")

    assert messages =~
             "    case unknown(JSONValue)\n    case undecodable(JSONValue, Fallback.Reason)\n"

    assert messages =~
             "do { self = .lookSeen(try raw.decode(LookSeenMessage.self)) } catch { self = .undecodable(raw, Fallback.Reason(error)) }"

    assert messages =~ "case .undecodable(let raw, _): try raw.encode(to: encoder)"

    # A request that is no case of its channel does not decode: requests fail closed.
    request = Regex.run(~r/public enum FrontRequest:.*?\n}\n/s, messages) |> hd()
    refute request =~ "undecodable"
    assert request =~ "self = .greet(try raw.decode(GreetRequest.self)); return"
  end

  test "an untyped field takes the endpoint's type: its model, a view model, a block" do
    [greet, _look] = channel(:front).requests
    [_hi, open, seen, error, _nudge] = channel(:front).messages

    # greet takes a greeting: its links are the model's.
    assert types(greet) == %{
             "links" => {{:list, :link}, true},
             "name" => {:string, true},
             "tags" => {{:map, :string}, false}
           }

    # A page's blocks and markup are a view model's.
    assert types(open) == %{
             "blocks" => {{:list, :"$block"}, true},
             "markup" => {{:list, :"$markup"}, true},
             "path" => {:string, true},
             "position" => {:integer, false},
             "title" => {:string, true}
           }

    assert types(hd(channel(:side).messages)) == %{"block" => {:"$block", true}}
    assert types(seen) == %{"links" => {{:list, :link}, true}}
    assert types(error) == %{"error" => {:string, true}}
    assert Swift.swift_type({:list, :"$block"}) == "[Block]"
    assert Swift.swift_type({:map, :string}) == "[String: String]"
  end

  test "replies that one selector cannot tell apart are refused" do
    [greet | rest] = @schema.protocol

    clash = %{
      name: :hello,
      select: %{"op" => "hi"},
      effect: :progress,
      required: %{"other" => :string}
    }

    schema = %{@schema | protocol: [%{greet | replies: greet.replies ++ [clash]} | rest]}

    schema =
      update_in(schema.endpoints, fn [e | es] ->
        [%{e | replies: e.replies ++ [%{name: :hello, returns: :greeting}]} | es]
      end)

    assert_raise ArgumentError, ~r/select/, fn -> Swift.files(schema) end
  end

  test "a contract without wire descriptors has pages and blocks, and no messages" do
    schema = %{@schema | protocol: []} |> Map.put(:endpoints, [])
    assert Swift.messages(schema) == []
    assert file("Sources/MyKit/Blocks.swift", schema) =~ "public struct CardBlock"
  end

  test "the tests it writes cover each block, markup kind, page and message, and the fallbacks" do
    tests = file("Tests/MyKitTests/ContractTests.swift")

    for name <- ~w(
          test_version
          test_block_card_decodes_and_round_trips
          test_block_card_without_title_or_with_a_wrong_one_falls_back
          test_block_rule_line_decodes_and_round_trips
          test_an_unknown_block_or_one_that_is_none_falls_back_and_round_trips
          test_a_list_of_blocks_keeps_every_known_block_around_a_fallback
          test_markup_group_decodes_and_round_trips
          test_markup_of_an_unknown_kind_or_without_an_end_falls_back_and_round_trips
          test_page_home_builds_and_matches_its_path
          test_page_card_builds_and_matches_its_path
          test_page_new_card_builds_and_matches_its_path
          test_a_path_that_is_no_page_matches_none
          test_front_request_greet_decodes_and_round_trips
          test_front_message_look_error_decodes_and_round_trips
          test_front_message_page_nudge_decodes_and_round_trips
          test_front_message_of_an_unknown_op_is_unknown_and_round_trips
          test_front_request_of_an_unknown_op_does_not_decode
          test_front_message_hi_whose_fields_do_not_decode_is_undecodable
          test_side_message_drawn_decodes_and_round_trips
        ) do
      assert tests =~ "func #{name}()", name
    end

    # Reasons are compared as cases with paths, not as text.
    assert tests =~ ~s|Fallback.Reason.missing(path: ["title"])|
    assert tests =~ ~s|Fallback.Reason.wrongType(path: ["title"])|
    assert tests =~ ~s|Fallback.Reason.missing(path: ["name"])|
    refute tests =~ "is missing"
    refute tests =~ "wrong type\""

    # drawn carries only a block, which never fails: no undecodable test on side.
    refute tests =~ "test_side_message_drawn_whose_fields_do_not_decode"

    fixtures = file("Tests/MyKitTests/FixtureTests.swift")
    assert fixtures =~ "func test_front_sent_lines_decode_and_round_trip()"
    assert fixtures =~ "func test_front_received_lines_decode_and_round_trip()"
    assert fixtures =~ "func test_side_received_lines_decode_and_round_trip()"
    assert fixtures =~ ~s|appendingPathComponent("Fixtures")|
    # A missing fixture fails; it is not skipped.
    refute fixtures =~ "XCTSkip"
    assert fixtures =~ "XCTFail(\"no fixtures at"
    # Without version_field, no version test.
    refute fixtures =~ "of_this_contract_version"
  end

  test "the undecodable test never leaves out or breaks a field the selector names" do
    # drawn is selected by `mark` being present and by a literal `kind`, both also required
    # fields: left out, the message would match no case, so neither is a candidate.
    drawn = %{
      name: :drawn,
      select: %{"op" => "drawn", "kind" => "line"},
      present: ["mark"],
      effect: :progress,
      required: %{"block" => :map, "kind" => :string, "mark" => :string}
    }

    with_drawn = fn drawn ->
      update_in(@schema.protocol, fn wires ->
        Enum.map(wires, fn
          %{name: :sketch} = w -> %{w | replies: [drawn]}
          w -> w
        end)
      end)
    end

    tests = file("Tests/MyKitTests/ContractTests.swift", with_drawn.(drawn))
    refute tests =~ "test_side_message_drawn_whose_fields_do_not_decode"
    refute tests =~ ~s|missing(path: ["mark"])|
    refute tests =~ ~s|missing(path: ["kind"])|

    # With a required field the selector does not name, that field is the one.
    drawn = %{drawn | required: Map.put(drawn.required, "size", :integer)}
    tests = file("Tests/MyKitTests/ContractTests.swift", with_drawn.(drawn))
    assert tests =~ "func test_side_message_drawn_whose_fields_do_not_decode_is_undecodable()"
    assert tests =~ ~s|Fallback.Reason.missing(path: ["size"])|
    assert tests =~ ~s|Fallback.Reason.wrongType(path: ["size"])|
  end

  test "with version_field, the fixtures of a channel whose messages carry it must carry this version" do
    fixtures =
      Swift.files(@schema, package: "MyKit", version_field: "name")
      |> Map.new()
      |> Map.fetch!("Tests/MyKitTests/FixtureTests.swift")

    # front's greet and hi carry `name`; side's messages do not.
    assert fixtures =~ "func test_front_fixtures_are_of_this_contract_version()"
    refute fixtures =~ "test_side_fixtures_are_of_this_contract_version"
    assert fixtures =~ ~s|for name in ["sent", "received"]|
    assert fixtures =~ ~s|XCTAssertEqual(version, .string(Contract.version)|
    assert fixtures =~ "XCTAssertGreaterThan(carrying, 0"
  end
end

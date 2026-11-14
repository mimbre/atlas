defmodule AtlasBFF.Targets.Swift.Tests do
  @moduledoc """
  The Swift package's tests, made from the contract: each block, kind of markup, page and
  message on samples of its fields (required only, and all), the fallbacks, and the
  message lines a server sent, kept in `Tests/Fixtures/<channel>/{sent,received}.jsonl`.
  """

  import AtlasBFF.Targets.Swift, only: [member: 1, type_name: 1]
  alias AtlasBFF.Names

  @depth 3

  @doc "`ContractTests.swift`."
  def contract(schema, channels, package) do
    ctx = %{
      models: Map.new(schema.models, &{&1.name, &1.fields}),
      blocks: schema.blocks,
      markup: schema.markup
    }

    tests =
      [
        version_test(schema)
        | Enum.flat_map(schema.blocks, &block_tests(&1, ctx))
      ] ++
        fallback_tests(ctx) ++
        Enum.flat_map(schema.markup, &markup_tests(&1, ctx)) ++
        markup_fallback_tests(ctx) ++
        page_tests(schema.pages) ++
        Enum.flat_map(channels, &message_tests(&1, ctx))

    [
      """
      import Foundation
      import XCTest
      import #{package}

      final class ContractTests: XCTestCase {
          private func json(_ text: String) throws -> JSONValue {
              try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
          }

          private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
              try JSONDecoder().decode(type, from: Data(text.utf8))
          }

          /// `value` encodes as `text`, and decodes from what it encodes as.
          private func assertRoundTrip<T: Codable & Equatable>(
              _ value: T, _ text: String, file: StaticString = #filePath, line: UInt = #line
          ) throws {
              XCTAssertEqual(try JSONValue(encoding: value), try json(text), file: file, line: line)
              let again = try JSONDecoder().decode(T.self, from: try JSONEncoder().encode(value))
              XCTAssertEqual(again, value, file: file, line: line)
          }
      """,
      Enum.map(tests, &["\n", &1]),
      "}\n"
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  `FixtureTests.swift`. With `version_field` (the field a handshake carries the contract's
  version in), a channel whose messages have that field must have lines that carry it, all
  with `Contract.version`: a new version needs new fixtures.
  """
  def fixtures(channels, package, version_field \\ nil) do
    tests =
      for ch <- channels do
        [
          version_test(ch, version_field),
          if ch.requests == [] do
            []
          else
            """

                func test_#{ch.channel}_sent_lines_decode_and_round_trip() throws {
                    for line in try lines(#{JSON.encode!(to_string(ch.channel))}, "sent") {
                        let request = try WireLine.decode(#{type_name(ch.channel)}Request.self, from: line)
                        XCTAssertEqual(try JSONValue(encoding: request), withoutNulls(try WireLine.decode(JSONValue.self, from: line)))
                    }
                }
            """
          end,
          """

              func test_#{ch.channel}_received_lines_decode_and_round_trip() throws {
                  for line in try lines(#{JSON.encode!(to_string(ch.channel))}, "received") {
                      let raw = try WireLine.decode(JSONValue.self, from: line)
                      let message = try WireLine.decode(#{type_name(ch.channel)}Message.self, from: line)
                      if case .unknown = message { XCTFail("not a known message: \\(raw)") }
                      if case .undecodable(_, let reason) = message { XCTFail("does not decode: \\(reason)") }
                      XCTAssertEqual(try JSONValue(encoding: message), withoutNulls(raw))
                      try assertBlocks(raw) { try $0.decode(#{type_name(ch.channel)}Message.self) }
                  }
              }
          """
        ]
      end

    [
      """
      import Foundation
      import XCTest
      import #{package}

      /// Lines a server sent and received, kept in Tests/Fixtures/<channel>/: each decodes into
      /// its case and encodes back to the same JSON (a member that is null is one without a
      /// value, which encodes as left out); no block in it falls back, and a block of an
      /// unknown type added to it does, while the rest still decode.
      final class FixtureTests: XCTestCase {
          private func lines(_ channel: String, _ name: String) throws -> [Data] {
              let url = URL(fileURLWithPath: #filePath)
                  .deletingLastPathComponent().deletingLastPathComponent()
                  .appendingPathComponent("Fixtures").appendingPathComponent(channel)
                  .appendingPathComponent(name + ".jsonl")
              guard FileManager.default.fileExists(atPath: url.path) else {
                  XCTFail("no fixtures at \\(url.path): capture them from a server")
                  return []
              }
              let lines = try String(contentsOf: url, encoding: .utf8)
                  .split(separator: "\\n").filter { !$0.isEmpty }.map { Data($0.utf8) }
              XCTAssertFalse(lines.isEmpty, "\\(url.path) is empty")
              return lines
          }

          private func withoutNulls(_ value: JSONValue) -> JSONValue {
              switch value {
              case .object(let members): .object(members.filter { $0.value != .null }.mapValues(withoutNulls))
              case .array(let items): .array(items.map(withoutNulls))
              default: value
              }
          }

          private func assertBlocks<M: Encodable>(_ raw: JSONValue, decode: (JSONValue) throws -> M) throws {
              guard case .object(var object) = raw, case .array(let blocks)? = object[#{JSON.encode!("blocks")}] else { return }
              for block in try JSONValue.array(blocks).decode([Block].self) {
                  if case .fallback(let fallback) = block.content { XCTFail("fell back: \\(fallback.reason)") }
              }
              let unknown = JSONValue.object(["id": .string("zz-unknown"), "type": .string("zz_unknown"), "props": .object([:])])
              object[#{JSON.encode!("blocks")}] = .array(blocks + [unknown])
              let decoded = try JSONValue.array(blocks + [unknown]).decode([Block].self)
              XCTAssertEqual(decoded.count, blocks.count + 1)
              for block in decoded.dropLast() {
                  if case .fallback = block.content { XCTFail("a known block fell back") }
              }
              XCTAssertEqual(decoded.last?.content, .fallback(Fallback(type: "zz_unknown", reason: .unknownType, raw: unknown)))
              XCTAssertEqual(try JSONValue(encoding: try decode(.object(object))), withoutNulls(.object(object)))
          }
      """,
      tests,
      "}\n"
    ]
    |> IO.iodata_to_binary()
  end

  defp version_test(_ch, nil), do: []

  defp version_test(ch, field) do
    carries = for m <- ch.requests ++ ch.messages, f <- m.fields, f.name == field, do: m

    if carries == [] do
      []
    else
      names = if ch.requests == [], do: ~s(["received"]), else: ~s(["sent", "received"])

      """

          func test_#{ch.channel}_fixtures_are_of_this_contract_version() throws {
              var carrying = 0
              for name in #{names} {
                  for line in try lines(#{JSON.encode!(to_string(ch.channel))}, name) {
                      guard let version = try WireLine.decode(JSONValue.self, from: line)[#{JSON.encode!(field)}] else { continue }
                      XCTAssertEqual(version, .string(Contract.version), "recapture the fixtures for this contract")
                      carrying += 1
                  }
              }
              XCTAssertGreaterThan(carrying, 0, "no line carries #{field}")
          }
      """
    end
  end

  # --- Tests ---------------------------------------------------------------------------

  defp version_test(schema) do
    """
        func test_version() {
            XCTAssertEqual(Contract.version, #{JSON.encode!(schema.version)})
        }
    """
  end

  defp block_tests(block, ctx) do
    name = to_string(block.name)
    required = block_json(block, ctx, :required)
    full = block_json(block, ctx, :full)

    decodes = """
        func test_block_#{name}_decodes_and_round_trips() throws {
            for text in [#{raw(required)}, #{raw(full)}] {
                let block = try decode(Block.self, text)
                guard case .#{member(block.name)} = block.content else { return XCTFail("#{name} fell back: \\(block.content)") }
                XCTAssertEqual(block.type, #{JSON.encode!(name)})
                XCTAssertEqual(block.id, "b1")
                try assertRoundTrip(block, text)
            }
        }
    """

    case Enum.find(block.fields, & &1.required) do
      nil ->
        [decodes]

      field ->
        missing = %{required | "props" => Map.delete(required["props"], to_string(field.name))}

        wrong = %{
          required
          | "props" => Map.put(required["props"], to_string(field.name), wrong(field.type))
        }

        [
          decodes,
          """
              func test_block_#{name}_without_#{field.name}_or_with_a_wrong_one_falls_back() throws {
                  for (text, reason) in [
                      (#{raw(missing)}, Fallback.Reason.missing(path: [#{JSON.encode!(to_string(field.name))}])),
                      (#{raw(wrong)}, Fallback.Reason.wrongType(path: [#{JSON.encode!(to_string(field.name))}])),
                  ] {
                      let block = try decode(Block.self, text)
                      XCTAssertEqual(block.content, .fallback(Fallback(type: #{JSON.encode!(name)}, reason: reason, raw: try json(text))))
                      try assertRoundTrip(block, text)
                  }
              }
          """
        ]
    end
  end

  defp fallback_tests(ctx) do
    good = Enum.map(ctx.blocks, &block_json(&1, ctx, :required))
    unknown = %{"id" => "zz", "type" => "zz_unknown", "props" => %{"a" => 1}}

    [
      """
          func test_an_unknown_block_or_one_that_is_none_falls_back_and_round_trips() throws {
              for (text, type, reason) in [
                  (#{raw(unknown)}, "zz_unknown" as String?, Fallback.Reason.unknownType),
                  (#{raw(["not", "a", "block"])}, nil, Fallback.Reason.untyped),
                  (#{raw(%{"props" => %{}})}, nil, Fallback.Reason.untyped),
              ] {
                  let block = try decode(Block.self, text)
                  XCTAssertEqual(block.content, .fallback(Fallback(type: type, reason: reason, raw: try json(text))))
                  try assertRoundTrip(block, text)
              }
          }
      """,
      """
          func test_a_list_of_blocks_keeps_every_known_block_around_a_fallback() throws {
              let text = #{raw(Enum.intersperse(good, unknown) ++ [unknown])}
              let blocks = try decode([Block].self, text)
              XCTAssertEqual(blocks.count, #{2 * length(good)})
              for (i, block) in blocks.enumerated() {
                  if case .fallback(let fallback) = block.content {
                      XCTAssertEqual(i % 2, 1)
                      XCTAssertEqual(fallback.reason, .unknownType)
                  } else {
                      XCTAssertEqual(i % 2, 0)
                  }
              }
              try assertRoundTrip(blocks, text)
          }
      """
    ]
  end

  defp markup_tests(kind, ctx) do
    name = to_string(kind.name)
    required = markup_json(kind, ctx, :required)
    full = markup_json(kind, ctx, :full) |> Map.put("group", "g1")

    [
      """
          func test_#{Names.markup()}_#{name}_decodes_and_round_trips() throws {
              for text in [#{raw(required)}, #{raw(full)}] {
                  let entry = try decode(MarkupEntry.self, text)
                  guard case .#{member(kind.name)} = entry.content else { return XCTFail("#{name} fell back: \\(entry.content)") }
                  XCTAssertEqual(entry.start, "b1")
                  try assertRoundTrip(entry, text)
              }
          }
      """
    ]
  end

  defp markup_fallback_tests(ctx) do
    markup = Names.markup()

    no_end =
      case ctx.markup do
        [kind | _] -> markup_json(kind, ctx, :required) |> Map.delete("end")
        [] -> %{"kind" => "zz", "start" => "b1"}
      end

    [
      """
          func test_#{markup}_of_an_unknown_kind_or_without_an_end_falls_back_and_round_trips() throws {
              for (text, reason) in [
                  (#{raw(%{"kind" => "zz_unknown", "start" => "b1", "end" => "b1"})}, Fallback.Reason.unknownType),
                  (#{raw(no_end)}, Fallback.Reason.noRange),
              ] {
                  let entry = try decode(MarkupEntry.self, text)
                  guard case .fallback(let fallback) = entry.content else { return XCTFail("decoded: \\(entry)") }
                  XCTAssertEqual(fallback.reason, reason)
                  try assertRoundTrip(entry, text)
              }
          }
      """
    ]
  end

  defp page_tests(pages) do
    tests =
      Enum.map(pages, fn page ->
        params = Map.new(page.params, &{to_string(&1), "v #{&1}/1"})

        swift_params =
          if params == %{},
            do: "[:]",
            else:
              "[" <>
                Enum.map_join(params, ", ", fn {k, v} ->
                  "#{JSON.encode!(k)}: #{JSON.encode!(v)}"
                end) <> "]"

        missing =
          case page.params do
            [first | _] ->
              "\n        XCTAssertThrowsError(try Page.#{member(page.name)}.path([:])) { XCTAssertEqual($0 as? PathError, .missing(page: .#{member(page.name)}, param: #{JSON.encode!(to_string(first))})) }"

            [] ->
              ""
          end

        """
            func test_page_#{page.name}_builds_and_matches_its_path() throws {
                let params: [String: String] = #{swift_params}
                let path = try Page.#{member(page.name)}.path(params)
                XCTAssertEqual(Page.match(path), PageMatch(page: .#{member(page.name)}, params: params))
                XCTAssertEqual(Page.#{member(page.name)}.template, #{JSON.encode!(page.path)})#{missing}
            }
        """
      end)

    tests ++
      [
        """
            func test_a_path_that_is_no_page_matches_none() {
                XCTAssertNil(Page.match(#{JSON.encode!("/" <> Enum.join(List.duplicate("zz", 12), "/"))}))
            }
        """
      ]
  end

  defp message_tests(ch, ctx) do
    channel = to_string(ch.channel)
    enum = type_name(ch.channel)

    requests =
      Enum.map(ch.requests, fn m ->
        text = message_json(m, ctx)

        """
            func test_#{channel}_request_#{m.case |> String.trim("`") |> Macro.underscore()}_decodes_and_round_trips() throws {
                let text = #{raw(text)}
                let request = try decode(#{enum}Request.self, text)
                guard case .#{m.case} = request else { return XCTFail("decoded as \\(request)") }
                try assertRoundTrip(request, text)
            }
        """
      end)

    messages =
      Enum.map(ch.messages, fn m ->
        text = message_json(m, ctx)

        """
            func test_#{channel}_message_#{m.case |> String.trim("`") |> Macro.underscore()}_decodes_and_round_trips() throws {
                let text = #{raw(text)}
                let message = try decode(#{enum}Message.self, text)
                guard case .#{m.case} = message else { return XCTFail("decoded as \\(message)") }
                try assertRoundTrip(message, text)
            }
        """
      end)

    unknown = %{"op" => "zz_unknown", "a" => 1}

    requests ++
      messages ++
      [
        """
            func test_#{channel}_message_of_an_unknown_op_is_unknown_and_round_trips() throws {
                let text = #{raw(unknown)}
                XCTAssertEqual(try decode(#{enum}Message.self, text), .unknown(try json(text)))
                try assertRoundTrip(try decode(#{enum}Message.self, text), text)
            }
        """
        | if(ch.requests == [],
            do: [],
            else: [
              """
                  func test_#{channel}_request_of_an_unknown_op_does_not_decode() {
                      XCTAssertThrowsError(try decode(#{enum}Request.self, #{raw(unknown)}))
                  }
              """
            ]
          )
      ] ++ undecodable_tests(ch, ctx)
  end

  # A type a wrong value fails to decode as: not a block or markup entry (which fall back)
  # nor an untyped value.
  defp strict?(type) when type in [:map, :list, :"$block", :"$markup"], do: false
  defp strict?({:list, inner}), do: strict?(inner)
  defp strict?(_type), do: true

  # A message whose selector matches a case but whose fields do not decode: undecodable,
  # with the path of the field, and encoded back as it came. One per channel, on the first
  # message with a required field a wrong value fails and its selector does not name (left
  # out, a field the selector needs present would no longer match the case).
  defp undecodable_tests(ch, ctx) do
    enum = type_name(ch.channel)

    candidate = fn m, f ->
      f.required and strict?(f.type) and f.name not in m.present and
        not List.keymember?(m.literals, f.name, 0)
    end

    case Enum.find(
           ch.messages,
           &(&1.struct != nil and Enum.any?(&1.fields, fn f -> candidate.(&1, f) end))
         ) do
      nil ->
        []

      m ->
        field = Enum.find(m.fields, &candidate.(m, &1))
        good = message_json(m, ctx)
        missing = Map.delete(good, field.name)
        wrong = Map.put(good, field.name, wrong(field.type))

        [
          """
              func test_#{ch.channel}_message_#{m.case |> String.trim("`") |> Macro.underscore()}_whose_fields_do_not_decode_is_undecodable() throws {
                  for (text, reason) in [
                      (#{raw(missing)}, Fallback.Reason.missing(path: [#{JSON.encode!(field.name)}])),
                      (#{raw(wrong)}, Fallback.Reason.wrongType(path: [#{JSON.encode!(field.name)}])),
                  ] {
                      XCTAssertEqual(try decode(#{enum}Message.self, text), .undecodable(try json(text), reason))
                      try assertRoundTrip(try decode(#{enum}Message.self, text), text)
                  }
              }
          """
        ]
    end
  end

  # --- Samples -------------------------------------------------------------------------

  defp block_json(block, ctx, which),
    do: %{
      "id" => "b1",
      "type" => to_string(block.name),
      "props" => fields(block.fields, ctx, which, 0)
    }

  defp markup_json(kind, ctx, which),
    do: %{
      "kind" => to_string(kind.name),
      "start" => "b1",
      "end" => "b1",
      "props" => fields(kind.fields, ctx, which, 0)
    }

  defp message_json(m, ctx) do
    m.fields
    |> Enum.map(&{&1.name, sample(&1.type, &1.name, ctx, :full, 0)})
    |> Map.new()
    |> Map.merge(Map.new(m.literals))
  end

  defp fields(fields, ctx, which, depth) do
    for f <- fields, f.required or (which == :full and depth < @depth), into: %{} do
      {to_string(f.name), sample(f.type, f.name, ctx, which, depth + 1)}
    end
  end

  defp sample(:string, name, _ctx, _which, _depth), do: "#{name} 1"
  defp sample(:integer, _name, _ctx, _which, _depth), do: 7
  defp sample(:boolean, _name, _ctx, _which, _depth), do: true
  defp sample(:map, _name, _ctx, _which, _depth), do: %{}
  defp sample(:list, _name, _ctx, _which, _depth), do: []

  defp sample({:map, inner}, name, ctx, which, depth),
    do: %{"k" => sample(inner, name, ctx, which, depth)}

  defp sample({:list, inner}, name, ctx, which, depth),
    do: if(depth > @depth, do: [], else: [sample(inner, name, ctx, which, depth)])

  defp sample(:"$block", _name, %{blocks: [block | _]} = ctx, _which, _depth),
    do: block_json(block, ctx, :required)

  defp sample(:"$markup", _name, %{markup: [kind | _]} = ctx, _which, _depth),
    do: markup_json(kind, ctx, :required)

  defp sample(model, _name, ctx, which, depth) when is_atom(model),
    do: fields(Map.fetch!(ctx.models, model), ctx, which, depth)

  # A value of another type than `type`.
  defp wrong(:string), do: 1
  defp wrong(_type), do: "zz"

  # A Swift raw string of `value` as JSON.
  defp raw(value), do: "##\"" <> JSON.encode!(value) <> "\"##"
end

defmodule AtlasBFF.Targets.Swift do
  @moduledoc """
  A file target: a Swift package of the contract, for clients on Apple's platforms. It
  reads only `__schema__/0`, and holds Foundation code only (no AppKit, UIKit or other
  platform API), so one package serves a macOS and an iOS client.

      config :atlas_bff, targets: [swift: {"../targets/swift", package: "MyKit"}]

  It writes, in the folder, a package `package` (option, default `"ContractKit"`) with
  one library product of that name and a test target. The option `version_field:` names
  the field a handshake carries the contract's version in (see the fixture tests below).

  - `Package.swift`: macOS 14 and iOS 17, Swift 6 language mode.
  - `Contract.swift`: `Contract.version`, the contract's version.
  - `JSONValue.swift`: any JSON value, for an untyped field and for what cannot be shown.
  - `Models.swift`, `Blocks.swift`, `Markup.swift`: a `Codable`, `Sendable`, `Equatable`
    struct per model (`<Name>Model`), block (`<Name>Block`) and kind of markup
    (`<Name>Markup`), its required fields required and its optional ones optional (left
    out when encoded without a value). `Block` and `MarkupEntry` are what a view model
    holds: an unknown block or kind, or one that fails to decode, becomes a `Fallback`
    with a `Fallback.Reason` (a case and the path of the field that failed, never text to
    compare) and the JSON it came as, so a newer server never breaks an older
    client and the rest of the page still decodes. Unknown keys are ignored.
  - `Pages.swift`: `Page`, a case per page, with `path(_:)` and `Page.match(_:)` by the
    rules of `AtlasBFF.Paths`.
  - `Messages.swift`: for each channel of the wire descriptors the endpoints name, the
    messages a client sends (`<Channel>Request`, a case per request) and receives
    (`<Channel>Message`, a case per reply and push; `unknown` for one it does not know,
    and `undecodable` with its `Fallback.Reason` for one whose selector matches a case but
    whose fields do not decode, so a newer server never breaks an older client; a
    request that is none of a channel's cases does not decode), encoded and decoded on `op` and the descriptors' other selectors. A field the
    descriptor leaves untyped takes the type the endpoint names: the model it takes or
    replies, a view model's blocks and markup, or the block a reply carries. `WireLine`
    reads and writes one message per line.
  - `Tests/<package>Tests/`: tests of all of it on samples made from the contract, and of
    the message lines kept in `Tests/Fixtures/<channel>/{sent,received}.jsonl` (kept by
    hand, captured from a server). A channel's fixtures must be there: a missing file
    fails. With the option `version_field:` (the field a handshake carries the version
    in), the lines that carry it must carry `Contract.version`, so a new version needs
    new fixtures..
  """

  alias AtlasBFF.Names
  alias AtlasBFF.Targets.Swift.{Support, Tests}

  @platforms ".macOS(.v14), .iOS(.v17)"

  @keywords ~w(associatedtype class deinit enum extension fileprivate func import init inout
    internal let open operator private precedencegroup protocol public rethrows static struct
    subscript typealias var break case catch continue default defer do else fallthrough for
    guard if in repeat return throw switch where while Any as await false is nil self Self
    super throws true try Type Protocol)

  @doc "`[{path, body}]`, paths relative to the target's folder."
  def files(schema, opts \\ []) do
    package = Keyword.get(opts, :package, "ContractKit")
    unless package =~ ~r/^[A-Z][A-Za-z0-9]*$/, do: raise(ArgumentError, "package: #{package}")
    sources = "Sources/#{package}/"
    tests = "Tests/#{package}Tests/"
    messages = messages(schema)

    [
      {"Package.swift", package_swift(package)},
      {sources <> "Contract.swift", contract_swift(schema)},
      {sources <> "JSONValue.swift", Support.json_value()},
      {sources <> "Fallback.swift", Support.fallback()},
      {sources <> "Models.swift", models_swift(schema)},
      {sources <> "Blocks.swift", blocks_swift(schema)},
      {sources <> "Markup.swift", markup_swift(schema)},
      {sources <> "Pages.swift", pages_swift(schema)},
      {sources <> "Messages.swift", messages_swift(messages)},
      {tests <> "ContractTests.swift", Tests.contract(schema, messages, package)},
      {tests <> "FixtureTests.swift",
       Tests.fixtures(messages, package, Keyword.get(opts, :version_field))}
    ]
  end

  # --- Names ---------------------------------------------------------------------------

  @doc false
  def type_name(name), do: name |> to_string() |> sanitize() |> Macro.camelize()

  @doc false
  def member(name) do
    camel = type_name(name)
    escape(String.downcase(String.first(camel)) <> String.slice(camel, 1..-1//1))
  end

  defp sanitize(text), do: String.replace(text, ~r/[^A-Za-z0-9_]/, "_")

  defp escape(name) when name in @keywords, do: "`#{name}`"
  defp escape(name), do: name

  @doc false
  def model_type(name), do: type_name(name) <> "Model"
  @doc false
  def block_type(name), do: type_name(name) <> "Block"
  @doc false
  def markup_type(name), do: type_name(name) <> "Markup"

  # --- Types ---------------------------------------------------------------------------

  # A field's type: a contract type, an envelope type (`:map`, `:list`), or `:"$block"` /
  # `:"$markup"`, a view model's block and markup entry.
  @doc false
  def swift_type(:string), do: "String"
  def swift_type(:integer), do: "Int"
  def swift_type(:boolean), do: "Bool"
  def swift_type(:map), do: "[String: JSONValue]"
  def swift_type(:list), do: "[JSONValue]"
  def swift_type(:"$block"), do: "Block"
  def swift_type(:"$markup"), do: "MarkupEntry"
  def swift_type({:list, inner}), do: "[#{swift_type(inner)}]"
  def swift_type({:map, inner}), do: "[String: #{swift_type(inner)}]"
  def swift_type(model) when is_atom(model), do: model_type(model)

  # A struct of `fields` (`%{name, type, required}`, `name` the wire key): its properties,
  # coding keys and a public initialiser. Swift synthesises `Codable`: a missing optional
  # field decodes as nil and is left out when encoded.
  @doc false
  def struct_swift(name, doc, fields) do
    props =
      Enum.map(fields, fn f ->
        "    public var #{member(f.name)}: #{swift_type(f.type)}#{if f.required, do: "", else: "?"}\n"
      end)

    keys =
      Enum.map(fields, fn f ->
        if member(f.name) == to_string(f.name),
          do: "        case #{member(f.name)}\n",
          else: "        case #{member(f.name)} = #{JSON.encode!(to_string(f.name))}\n"
      end)

    args =
      Enum.map_join(fields, ", ", fn f ->
        "#{member(f.name)}: #{swift_type(f.type)}#{if f.required, do: "", else: "? = nil"}"
      end)

    assigns =
      Enum.map(fields, &"        self.#{member(&1.name)} = #{member(&1.name)}\n")

    keys_enum =
      if fields == [],
        do: [],
        else: ["\n    enum CodingKeys: String, CodingKey {\n", keys, "    }\n"]

    [
      "/// #{doc}\n",
      "public struct #{name}: Codable, Sendable, Equatable {\n",
      props,
      if(fields == [], do: [], else: "\n"),
      "    public init(#{args}) {\n",
      assigns,
      "    }\n",
      keys_enum,
      "}\n"
    ]
  end

  # --- Package and version ---------------------------------------------------------------

  defp package_swift(package) do
    """
    // swift-tools-version: 6.0
    import PackageDescription

    let package = Package(
        name: "#{package}",
        platforms: [#{@platforms}],
        products: [
            .library(name: "#{package}", targets: ["#{package}"])
        ],
        targets: [
            .target(name: "#{package}"),
            .testTarget(name: "#{package}Tests", dependencies: ["#{package}"])
        ],
        swiftLanguageModes: [.v6]
    )
    """
  end

  defp contract_swift(schema) do
    """
    /// The contract this package is generated from.
    public enum Contract {
        /// The contract's version: what a client says it implements.
        public static let version = #{JSON.encode!(schema.version)}
    }
    """
  end

  # --- Models, blocks, markup ------------------------------------------------------------

  defp models_swift(schema) do
    structs =
      Enum.map(schema.models, fn m ->
        struct_swift(model_type(m.name), "The model `#{m.name}`.", m.fields)
      end)

    ["import Foundation\n\n" | Enum.intersperse(structs, "\n")] |> IO.iodata_to_binary()
  end

  defp blocks_swift(schema) do
    reserved!(schema.blocks, "block")

    structs =
      Enum.map(schema.blocks, fn b ->
        struct_swift(block_type(b.name), "The props of the block `#{b.name}`.", b.fields)
      end)

    cases = Enum.map(schema.blocks, &"        case #{member(&1.name)}(#{block_type(&1.name)})\n")

    decodes =
      Enum.map(schema.blocks, fn b ->
        "            case #{JSON.encode!(to_string(b.name))}: content = .#{member(b.name)}(try props.decode(#{block_type(b.name)}.self))\n"
      end)

    encodes =
      Enum.map(schema.blocks, fn b ->
        "        case .#{member(b.name)}(let props): try BlockWire(id: id, type: #{JSON.encode!(to_string(b.name))}, props: props).encode(to: encoder)\n"
      end)

    types =
      Enum.map(schema.blocks, fn b ->
        "        case .#{member(b.name)}: #{JSON.encode!(to_string(b.name))}\n"
      end)

    [
      "import Foundation\n\n",
      Enum.intersperse(structs, "\n"),
      """

      /// One block of a #{Names.view_model()}: its id and what it shows. A block of a type this
      /// package does not know, or that fails to decode, is a `Fallback`, so a page of a newer
      /// server still decodes; it encodes back as it came.
      public struct Block: Codable, Sendable, Equatable {
          public var id: String?
          public var content: Content

          public enum Content: Sendable, Equatable {
      """,
      cases,
      """
              case fallback(Fallback)
          }

          public init(id: String?, content: Content) {
              self.id = id
              self.content = content
          }

          /// The block's type on the wire.
          public var type: String? {
              switch content {
      """,
      types,
      """
              case .fallback(let fallback): fallback.type
              }
          }

          /// The block in `raw`, its JSON; never fails.
          public init(raw: JSONValue) {
              id = raw["id"]?.string
              guard case .object(let object) = raw, let type = object["type"]?.string else {
                  content = .fallback(Fallback(type: nil, reason: .untyped, raw: raw))
                  return
              }
              let props = object["props"].flatMap { $0 == .null ? nil : $0 } ?? .object([:])
              do {
                  switch type {
      """,
      decodes,
      """
                  default: content = .fallback(Fallback(type: type, reason: .unknownType, raw: raw))
                  }
              } catch {
                  content = .fallback(Fallback(type: type, reason: Fallback.Reason(error), raw: raw))
              }
          }

          public init(from decoder: any Decoder) throws {
              self.init(raw: try JSONValue(from: decoder))
          }

          public func encode(to encoder: any Encoder) throws {
              switch content {
      """,
      encodes,
      """
              case .fallback(let fallback): try fallback.raw.encode(to: encoder)
              }
          }
      }

      private struct BlockWire<Props: Encodable>: Encodable {
          let id: String?
          let type: String
          let props: Props
      }
      """
    ]
    |> IO.iodata_to_binary()
  end

  defp markup_swift(schema) do
    reserved!(schema.markup, Names.markup())
    markup = Names.markup()

    structs =
      Enum.map(schema.markup, fn k ->
        struct_swift(
          markup_type(k.name),
          "The props of the #{markup} kind `#{k.name}`.",
          k.fields
        )
      end)

    cases = Enum.map(schema.markup, &"        case #{member(&1.name)}(#{markup_type(&1.name)})\n")

    decodes =
      Enum.map(schema.markup, fn k ->
        "            case #{JSON.encode!(to_string(k.name))}: content = .#{member(k.name)}(try props.decode(#{markup_type(k.name)}.self))\n"
      end)

    encodes =
      Enum.map(schema.markup, fn k ->
        "        case .#{member(k.name)}(let props): try MarkupWire(kind: #{JSON.encode!(to_string(k.name))}, start: start, end: end, group: group, props: props).encode(to: encoder)\n"
      end)

    [
      "import Foundation\n\n",
      Enum.intersperse(structs, "\n"),
      """

      /// One #{markup} entry of a #{Names.view_model()}: what the blocks from `start` to `end`
      /// (block ids, both included) mean, and `group` on the pieces of split #{markup}. An
      /// entry of a kind this package does not know, or that fails to decode, is a
      /// `Fallback`: a client leaves it out. It encodes back as it came.
      public struct MarkupEntry: Codable, Sendable, Equatable {
          public var start: String
          public var end: String
          public var group: String?
          public var content: Content

          public enum Content: Sendable, Equatable {
      """,
      cases,
      """
              case fallback(Fallback)
          }

          public init(start: String, end: String, group: String? = nil, content: Content) {
              self.start = start
              self.end = end
              self.group = group
              self.content = content
          }

          /// The entry in `raw`, its JSON; never fails.
          public init(raw: JSONValue) {
              start = raw["start"]?.string ?? ""
              end = raw["end"]?.string ?? ""
              group = raw["group"]?.string
              guard case .object(let object) = raw, let kind = object["kind"]?.string else {
                  content = .fallback(Fallback(type: nil, reason: .untyped, raw: raw))
                  return
              }
              guard raw["start"]?.string != nil, raw["end"]?.string != nil else {
                  content = .fallback(Fallback(type: kind, reason: .noRange, raw: raw))
                  return
              }
              let props = object["props"].flatMap { $0 == .null ? nil : $0 } ?? .object([:])
              do {
                  switch kind {
      """,
      decodes,
      """
                  default: content = .fallback(Fallback(type: kind, reason: .unknownType, raw: raw))
                  }
              } catch {
                  content = .fallback(Fallback(type: kind, reason: Fallback.Reason(error), raw: raw))
              }
          }

          public init(from decoder: any Decoder) throws {
              self.init(raw: try JSONValue(from: decoder))
          }

          public func encode(to encoder: any Encoder) throws {
              switch content {
      """,
      encodes,
      """
              case .fallback(let fallback): try fallback.raw.encode(to: encoder)
              }
          }
      }

      private struct MarkupWire<Props: Encodable>: Encodable {
          let kind: String
          let start: String
          let end: String
          let group: String?
          let props: Props
      }
      """
    ]
    |> IO.iodata_to_binary()
  end

  defp reserved!(entries, what) do
    for e <- entries,
        member(e.name) == "fallback",
        do: raise(ArgumentError, "a #{what} named fallback has no Swift case of its own")
  end

  # --- Pages -----------------------------------------------------------------------------

  defp pages_swift(%{pages: []}),
    do:
      Support.path_rules() <>
        "\n/// The contract has no pages.\npublic enum Page: String, CaseIterable, Sendable {}\n"

  defp pages_swift(schema) do
    cases =
      Enum.map(schema.pages, fn p ->
        if member(p.name) == to_string(p.name),
          do: "    case #{member(p.name)}\n",
          else: "    case #{member(p.name)} = #{JSON.encode!(to_string(p.name))}\n"
      end)

    templates =
      Enum.map(schema.pages, &"        case .#{member(&1.name)}: #{JSON.encode!(&1.path)}\n")

    [
      Support.path_rules(),
      """

      /// The pages the contract lists: a client with a screen follows only these.
      public enum Page: String, CaseIterable, Sendable {
      """,
      cases,
      """

          /// The page's path, with `:name` for each parameter.
          public var template: String {
              switch self {
      """,
      templates,
      """
              }
          }

          /// The page's parameters, in path order.
          public var params: [String] { PathRules.params(template) }

          /// The path of this page with `params` (each value percent-encoded).
          public func path(_ params: [String: String] = [:]) throws(PathError) -> String {
              try PathRules.build(self, template, params)
          }

          /// The page `path` is, and its parameters (decoded); nil for a path that is no page.
          /// A literal segment wins over a parameter, from the first segment on.
          public static func match(_ path: String) -> PageMatch? {
              PathRules.match(path, Page.allCases.map { ($0, $0.template) })
          }
      }
      """
    ]
    |> IO.iodata_to_binary()
  end

  # --- Messages --------------------------------------------------------------------------

  @doc false
  # The messages of each channel the endpoints' wire descriptors are on:
  # `[%{channel, requests: [msg], messages: [msg]}]`, where a msg is
  # `%{case, struct, literals, present, absent, fields}`.
  def messages(schema) do
    wires = Map.get(schema, :protocol, [])
    named = schema.endpoints |> Enum.map(& &1[:wire]) |> Enum.reject(&is_nil/1)
    used = Enum.filter(wires, &(&1.name in named))

    models =
      Map.new(schema.models, &{&1.name, Map.new(&1.fields, fn f -> {to_string(f.name), f} end)})

    blocks = Enum.map(schema.blocks, & &1.name)

    channels =
      used
      |> Enum.map(& &1.channel)
      |> Enum.uniq()
      |> Enum.map(fn channel ->
        in_channel = Enum.filter(used, &(&1.channel == channel))

        requests =
          for wire <- in_channel, wire.direction != :push do
            refine =
              schema.endpoints
              |> Enum.filter(&(&1[:wire] == wire.name))
              |> Enum.map(&refinement(&1.takes, models, blocks))

            envelope(wire.request, refine)
            |> Map.merge(%{case: member(wire.name), struct: type_name(wire.name) <> "Request"})
          end

        replies =
          for wire <- in_channel,
              reply <- wire.replies do
            refine =
              for endpoint <- schema.endpoints,
                  endpoint[:wire] == wire.name,
                  r <- Map.get(endpoint, :replies, []),
                  r.name == reply.name,
                  do: refinement(r.returns, models, blocks)

            envelope(reply, refine) |> Map.put(:reply, reply.name)
          end

        %{channel: channel, requests: requests, messages: replies |> dedupe() |> name_cases()}
      end)

    channels |> name_structs() |> disjoint!()
  end

  defp refinement(:view_model, _models, _blocks), do: :view_model
  defp refinement(nil, _models, _blocks), do: nil
  defp refinement(:values, _models, _blocks), do: nil

  defp refinement(name, models, blocks) do
    cond do
      Map.has_key?(models, name) -> {:model, models[name]}
      name in blocks -> :block
      true -> nil
    end
  end

  defp envelope(envelope, refinements) do
    select = Map.get(envelope, :select, %{})

    fields =
      for {key, required} <- [required: true, optional: false],
          {name, type} <- Enum.sort(Map.get(envelope, key, %{})) do
        %{name: name, type: resolve(name, type, refinements), required: required}
      end
      |> Enum.sort_by(& &1.name)

    %{
      literals: Enum.sort(select),
      present: Enum.sort(Map.get(envelope, :present, [])),
      absent: Enum.sort(Map.get(envelope, :absent, [])),
      fields: fields
    }
  end

  # An untyped envelope field takes the type the endpoint names, the first that has one.
  defp resolve(name, type, refinements) do
    Enum.find_value(refinements, type, fn
      {:model, fields} ->
        case {type, fields[name]} do
          {:list, %{type: {:list, _} = t}} -> t
          {:map, %{type: {:map, _} = t}} -> t
          {:map, %{type: t}} when is_atom(t) and t not in [:string, :integer, :boolean] -> t
          _ -> nil
        end

      :view_model ->
        markup = Names.markup()

        case {name, type} do
          {"blocks", :list} -> {:list, :"$block"}
          {^markup, :list} -> {:list, :"$markup"}
          _ -> nil
        end

      :block ->
        if type == :map, do: :"$block"

      nil ->
        nil
    end)
  end

  defp selector(msg), do: {msg.literals, msg.present, msg.absent}

  # One message per selector: the same reply in several exchanges (a page, a notice) is
  # one message of the channel.
  defp dedupe(messages) do
    messages
    |> Enum.group_by(&selector/1)
    |> Enum.map(fn {_selector, [first | _] = same} ->
      shape = fn m -> Enum.map(m.fields, &{&1.name, &1.required}) end

      for other <- same, shape.(other) != shape.(first) do
        raise ArgumentError,
              "two replies select #{inspect(selector(first))} with other fields"
      end

      fields =
        Enum.map(first.fields, fn f ->
          types = for m <- same, g <- m.fields, g.name == f.name, do: g.type
          %{f | type: Enum.find(types, f.type, &(&1 not in [:list, :map]))}
        end)

      {Enum.find_index(messages, &(selector(&1) == selector(first))), %{first | fields: fields}}
    end)
    |> Enum.sort()
    |> Enum.map(&elem(&1, 1))
  end

  # A message's case: its op; where several messages have that op, its other literals
  # too; and the reply's name where those are not enough (a reply named as its op adds
  # nothing).
  defp name_cases(messages) do
    ops = Enum.frequencies_by(messages, &op/1)

    base = fn m ->
      if ops[op(m)] == 1,
        do: [op(m)],
        else: Enum.map(m.literals, &elem(&1, 1)) |> op_first(m)
    end

    counts = Enum.frequencies_by(messages, base)

    named =
      Enum.map(messages, fn m ->
        words = base.(m)

        words =
          if counts[words] > 1 and List.last(words) != to_string(m.reply),
            do: words ++ [to_string(m.reply)],
            else: words

        Map.put(m, :case, member(Enum.join(words, "_")))
      end)

    cases = Enum.map(named, & &1.case)

    if length(cases) != length(Enum.uniq(cases)),
      do: raise(ArgumentError, "replies without names of their own: #{inspect(cases)}")

    for reserved <- ~w(unknown undecodable),
        reserved in cases,
        do: raise(ArgumentError, "a reply named #{reserved} has no Swift case of its own")

    named
  end

  defp op_first(values, m) do
    op = m.literals |> List.keyfind("op", 0) |> elem(1)
    [op | List.delete(values, op)]
  end

  # A message's struct: `<Op>Message` when every message of that op in the channel has the
  # same fields, else `<Case>Message`; a channel's name first where two channels' structs
  # of one name differ. A message without fields has none.
  defp name_structs(channels) do
    local =
      Enum.map(channels, fn ch ->
        by_op = Enum.group_by(ch.messages, &op/1)

        messages =
          Enum.map(ch.messages, fn m ->
            same = by_op[op(m)] |> Enum.map(& &1.fields) |> Enum.uniq()

            name =
              if length(same) == 1,
                do: type_name(op(m)) <> "Message",
                else: type_name(m.case) <> "Message"

            Map.put(m, :struct, name)
          end)

        %{ch | messages: messages}
      end)

    shapes =
      for ch <- local, m <- ch.messages, m.fields != [], reduce: %{} do
        acc -> Map.update(acc, m.struct, MapSet.new([m.fields]), &MapSet.put(&1, m.fields))
      end

    Enum.map(local, fn ch ->
      messages =
        Enum.map(ch.messages, fn m ->
          cond do
            m.fields == [] ->
              %{m | struct: nil}

            MapSet.size(shapes[m.struct]) > 1 ->
              %{m | struct: type_name(ch.channel) <> m.struct}

            true ->
              m
          end
        end)

      requests = Enum.map(ch.requests, &if(&1.fields == [], do: %{&1 | struct: nil}, else: &1))
      %{ch | messages: messages, requests: requests}
    end)
  end

  defp op(m), do: m.literals |> List.keyfind("op", 0) |> elem(1)

  # What decodes must be one message: selectors in a channel and direction do not overlap.
  defp disjoint!(channels) do
    for ch <- channels,
        list <- [ch.requests, ch.messages],
        {a, i} <- Enum.with_index(list),
        b <- Enum.drop(list, i + 1),
        overlap?(a, b) do
      raise ArgumentError, "#{ch.channel}: #{a.case} and #{b.case} select the same messages"
    end

    channels
  end

  defp overlap?(a, b) do
    la = Map.new(a.literals)
    lb = Map.new(b.literals)
    disagree = Enum.any?(la, fn {k, v} -> Map.has_key?(lb, k) and lb[k] != v end)

    not disagree and
      Enum.all?(Map.keys(la) ++ a.present, &(&1 not in b.absent)) and
      Enum.all?(Map.keys(lb) ++ b.present, &(&1 not in a.absent))
  end

  defp messages_swift(channels) do
    structs =
      for ch <- channels, m <- ch.requests ++ ch.messages, m.struct != nil, uniq: true do
        {m.struct, m.fields}
      end
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.map(fn {name, fields} ->
        struct_swift(name, "The fields of a message (its selectors are the case's).", fields)
      end)

    enums =
      for ch <- channels do
        [
          if(ch.requests == [], do: [], else: enum_swift(ch, :requests)),
          enum_swift(ch, :messages)
        ]
      end

    [
      "import Foundation\n\n",
      Support.wire_line(),
      "\n",
      Enum.intersperse(structs, "\n"),
      "\n",
      enums
    ]
    |> IO.iodata_to_binary()
  end

  defp enum_swift(ch, which) do
    {name, doc, unknown} =
      case which do
        :requests ->
          {type_name(ch.channel) <> "Request",
           "What a client sends on the channel `#{ch.channel}`. A message that is none of these does not decode.",
           false}

        :messages ->
          {type_name(ch.channel) <> "Message",
           "What a client receives on the channel `#{ch.channel}`; `unknown` for a message it does not know, which a client skips; `undecodable` for one of a known case whose fields do not decode.",
           true}
      end

    list = Map.fetch!(ch, which)

    cases =
      Enum.map(list, fn m ->
        if m.struct, do: "    case #{m.case}(#{m.struct})\n", else: "    case #{m.case}\n"
      end)

    selector = fn m ->
      lits =
        Enum.map_join(m.literals, ", ", fn {k, v} -> "#{JSON.encode!(k)}: #{JSON.encode!(v)}" end)

      "Selector(literals: [#{lits}], present: #{swift_strings(m.present)}, absent: #{swift_strings(m.absent)})"
    end

    decodes =
      Enum.map(list, fn m ->
        value =
          if m.struct, do: ".#{m.case}(try raw.decode(#{m.struct}.self))", else: ".#{m.case}"

        cond do
          not unknown or m.struct == nil ->
            "        if #{selector.(m)}.matches(object) { self = #{value}; return }\n"

          true ->
            "        if #{selector.(m)}.matches(object) {\n            do { self = #{value} } catch { self = .undecodable(raw, Fallback.Reason(error)) }\n            return\n        }\n"
        end
      end)

    encodes =
      Enum.map(list, fn m ->
        lits =
          Enum.map_join(m.literals, ", ", fn {k, v} ->
            "#{JSON.encode!(k)}: #{JSON.encode!(v)}"
          end)

        if m.struct,
          do:
            "        case .#{m.case}(let fields): try Envelope.encode(fields, literals: [#{lits}], to: encoder)\n",
          else:
            "        case .#{m.case}: try Envelope.encode(nil as JSONValue?, literals: [#{lits}], to: encoder)\n"
      end)

    fallback =
      if unknown,
        do: "        self = .unknown(raw)\n",
        else:
          "        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: \"not a request of this channel\"))\n"

    not_object =
      if unknown,
        do: "self = .unknown(raw); return",
        else:
          "throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: \"not an object\"))"

    [
      "\n/// #{doc}\n",
      "public enum #{name}: Codable, Sendable, Equatable {\n",
      cases,
      if(unknown,
        do: "    case unknown(JSONValue)\n    case undecodable(JSONValue, Fallback.Reason)\n",
        else: []
      ),
      "\n    public init(from decoder: any Decoder) throws {\n",
      "        let raw = try JSONValue(from: decoder)\n",
      "        guard case .object(let object) = raw else { #{not_object} }\n",
      decodes,
      fallback,
      "    }\n\n",
      "    public func encode(to encoder: any Encoder) throws {\n",
      "        switch self {\n",
      encodes,
      if(unknown,
        do:
          "        case .unknown(let raw): try raw.encode(to: encoder)\n        case .undecodable(let raw, _): try raw.encode(to: encoder)\n",
        else: []
      ),
      "        }\n",
      "    }\n",
      "}\n"
    ]
  end

  defp swift_strings(list), do: "[" <> Enum.map_join(list, ", ", &JSON.encode!/1) <> "]"
end

defmodule AtlasBFF.Targets.Swift.Support do
  @moduledoc """
  The Swift package's code that no contract changes: rules of the format (any JSON value,
  the fallback, the paths of `AtlasBFF.Paths`, one message per line), the same for every
  contract. `AtlasBFF.Targets.Swift` writes it next to the contract's own types.
  Foundation only, so it builds for macOS and iOS.
  """

  @doc "`JSONValue`: any JSON value."
  def json_value do
    ~S"""
    import Foundation

    /// Any JSON value: what a field the contract leaves untyped holds, and what a block or
    /// markup entry that cannot be shown keeps, so it encodes back as it came.
    public enum JSONValue: Codable, Sendable, Equatable, Hashable {
        case null
        case bool(Bool)
        case integer(Int)
        case number(Double)
        case string(String)
        case array([JSONValue])
        case object([String: JSONValue])

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(Int.self) {
                self = .integer(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode([JSONValue].self) {
                self = .array(value)
            } else {
                self = .object(try container.decode([String: JSONValue].self))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .null: try container.encodeNil()
            case .bool(let value): try container.encode(value)
            case .integer(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            }
        }

        /// `value` as JSON.
        public init(encoding value: some Encodable) throws {
            self = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        }

        /// This JSON decoded as `type`.
        public func decode<T: Decodable>(_ type: T.Type) throws -> T {
            try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
        }

        /// The member `key` of an object; nil for another value.
        public subscript(key: String) -> JSONValue? {
            if case .object(let object) = self { object[key] } else { nil }
        }

        /// The text of a string; nil for another value.
        public var string: String? {
            if case .string(let text) = self { text } else { nil }
        }
    }
    """
  end

  @doc "`Fallback` and `Fallback.Reason`: what cannot be shown, and why."
  def fallback do
    ~S"""
    import Foundation

    /// A block or markup entry this package cannot show: its type (or kind) when it has one,
    /// why, and the JSON it came as. A client shows a block's fallback in its place and
    /// leaves a markup entry's out; the rest of the page still renders.
    public struct Fallback: Sendable, Equatable, CustomStringConvertible {
        public var type: String?
        public var reason: Reason
        public var raw: JSONValue

        public init(type: String?, reason: Reason, raw: JSONValue) {
            self.type = type
            self.reason = reason
            self.raw = raw
        }

        /// Why something cannot be shown or decoded. A path names the fields (and list
        /// indexes) from the props, or from the message, down to the one that failed.
        /// Compare the case and the path; `description` is only for showing.
        public enum Reason: Sendable, Equatable, CustomStringConvertible {
            /// Not an object with a type (a block) or a kind (markup).
            case untyped
            /// A type or kind this package does not know.
            case unknownType
            /// Markup without a start or an end.
            case noRange
            /// A required field is missing or null.
            case missing(path: [String])
            /// A field holds another type than the contract's.
            case wrongType(path: [String])
            /// A field's value is not valid.
            case invalid(path: [String])
            /// It does not decode for another reason.
            case undecodable

            /// The reason `error`, from decoding, gives.
            init(_ error: any Error) {
                func path(_ keys: [any CodingKey]) -> [String] {
                    keys.map { $0.intValue.map(String.init) ?? $0.stringValue }
                }
                switch error as? DecodingError {
                case .keyNotFound(let key, let context)?: self = .missing(path: path(context.codingPath + [key]))
                case .valueNotFound(_, let context)?: self = .missing(path: path(context.codingPath))
                case .typeMismatch(_, let context)?: self = .wrongType(path: path(context.codingPath))
                case .dataCorrupted(let context)?: self = .invalid(path: path(context.codingPath))
                default: self = .undecodable
                }
            }

            public var description: String {
                func at(_ path: [String]) -> String { path.isEmpty ? "the value" : path.joined(separator: ".") }
                switch self {
                case .untyped: return "not an object with a type or kind"
                case .unknownType: return "unknown type or kind"
                case .noRange: return "no start or end"
                case .missing(let path): return "\(at(path)) is missing"
                case .wrongType(let path): return "\(at(path)) has the wrong type"
                case .invalid(let path): return "\(at(path)) is not valid"
                case .undecodable: return "does not decode"
                }
            }
        }

        public var description: String { "\(type ?? "?"): \(reason)" }
    }
    """
  end

  @doc "`PageMatch`, `PathError` and the rules of a page's path."
  def path_rules do
    ~S"""
    import Foundation

    /// A path's page, and the values of its parameters.
    public struct PageMatch: Sendable, Equatable {
        public let page: Page
        public let params: [String: String]

        public init(page: Page, params: [String: String]) {
            self.page = page
            self.params = params
        }
    }

    /// A path that cannot be built: `param` of `page` has no value.
    public enum PathError: Error, Equatable {
        case missing(page: Page, param: String)
    }

    /// The rules of a page's path (as `AtlasBFF.Paths` has them): segments separated by `/`,
    /// a literal or a parameter `:name` that takes any one nonempty segment. A value in a
    /// path is percent-encoded (all but `A-Z a-z 0-9 - . _ ~`) and decoded when matched.
    enum PathRules {
        enum Segment: Equatable {
            case literal(String)
            case param(String)
        }

        static func segments(_ template: String) -> [Segment] {
            let rest = template.drop { $0 == "/" }
            guard !rest.isEmpty else { return [] }
            return rest.split(separator: "/", omittingEmptySubsequences: false).map {
                $0.hasPrefix(":") ? .param(String($0.dropFirst())) : .literal(String($0))
            }
        }

        static func params(_ template: String) -> [String] {
            segments(template).compactMap { if case .param(let name) = $0 { name } else { nil } }
        }

        private static let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

        static func build(_ page: Page, _ template: String, _ params: [String: String]) throws(PathError) -> String {
            var parts: [String] = []
            for segment in segments(template) {
                switch segment {
                case .literal(let text):
                    parts.append(text)
                case .param(let name):
                    guard let value = params[name], !value.isEmpty,
                          let encoded = value.addingPercentEncoding(withAllowedCharacters: unreserved)
                    else { throw .missing(page: page, param: name) }
                    parts.append(encoded)
                }
            }
            return "/" + parts.joined(separator: "/")
        }

        static func match(_ path: String, _ pages: [(Page, String)]) -> PageMatch? {
            let rest = path.drop { $0 == "/" }
            let given = rest.isEmpty ? [] : rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            var best: (rank: [Int], match: PageMatch)?
            for (page, template) in pages {
                let segments = segments(template)
                guard let params = bind(segments, given) else { continue }
                let rank = segments.map { if case .literal = $0 { 1 } else { 0 } }
                if best == nil || best!.rank.lexicographicallyPrecedes(rank) {
                    best = (rank, PageMatch(page: page, params: params))
                }
            }
            return best?.match
        }

        private static func bind(_ segments: [Segment], _ given: [String]) -> [String: String]? {
            guard segments.count == given.count else { return nil }
            var params: [String: String] = [:]
            for (segment, part) in zip(segments, given) {
                guard let decoded = part.removingPercentEncoding else { return nil }
                switch segment {
                case .literal(let text):
                    guard decoded == text else { return nil }
                case .param(let name):
                    guard !part.isEmpty else { return nil }
                    params[name] = decoded
                }
            }
            return params
        }
    }
    """
  end

  @doc "`WireLine`, the message selectors and envelopes."
  def wire_line do
    ~S"""
    /// One message per line, as JSON: how messages travel between a client and its server.
    public enum WireLine {
        /// `message` as one line of JSON, with its newline.
        public static func encode(_ message: some Encodable) throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var line = try encoder.encode(message)
            line.append(0x0A)
            return line
        }

        /// The message in `line`, one line of JSON (its newline may be left on).
        public static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
            try JSONDecoder().decode(type, from: line)
        }
    }

    /// Which messages are one case: literal string fields, and fields present or absent.
    struct Selector {
        let literals: [String: String]
        let present: [String]
        let absent: [String]

        func matches(_ object: [String: JSONValue]) -> Bool {
            literals.allSatisfy { object[$0.key] == .string($0.value) }
                && present.allSatisfy { object[$0] != nil }
                && absent.allSatisfy { object[$0] == nil }
        }
    }

    /// A message on the wire: its fields, with its case's literals.
    enum Envelope {
        static func encode(_ fields: (some Encodable)?, literals: [String: String], to encoder: any Encoder) throws {
            var object: [String: JSONValue] = [:]
            if let fields, case .object(let members) = try JSONValue(encoding: fields) {
                object = members
            }
            for (key, value) in literals { object[key] = .string(value) }
            try JSONValue.object(object).encode(to: encoder)
        }
    }
    """
  end
end

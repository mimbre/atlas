import Foundation

/// The app as it is installed: what its bundle says it is (`Info.plist`, written by
/// `tools/package_release_app.py` in the release job of `.github/workflows/ci.yml`).
/// A build without these keys (`swift run`, a local bundle) is no release and does not
/// update itself.
public struct InstalledApp: Sendable, Equatable {
    /// The commit the app was built from (`AtlasRevision`).
    public var revision: String
    /// The release's number (`CFBundleVersion`, the CI run number): a later release has a
    /// higher one.
    public var build: Int
    /// The contract it speaks (`AtlasContract`, `Contract.version` when it was built).
    public var contract: String
    /// Where the feed naming the newest release is (`AtlasUpdateFeed`).
    public var feed: URL

    public init(revision: String, build: Int, contract: String, feed: URL) {
        self.revision = revision
        self.build = build
        self.contract = contract
        self.feed = feed
    }

    /// The release in a bundle's info dictionary; nil for a build that is no release.
    public init?(info: [String: Any]?) {
        guard let info,
              let revision = info["AtlasRevision"] as? String, !revision.isEmpty,
              let text = info["CFBundleVersion"] as? String, let build = Int(text),
              let contract = info["AtlasContract"] as? String, !contract.isEmpty,
              let feedText = info["AtlasUpdateFeed"] as? String, let feed = URL(string: feedText),
              feed.scheme == "https"
        else { return nil }
        self.init(revision: revision, build: build, contract: contract, feed: feed)
    }
}

/// A published release, as the feed names it (`feed.json` of the release `atlas-console`).
public struct AppRelease: Sendable, Equatable, Codable {
    public var revision: String
    public var build: Int
    public var contract: String
    /// The zip holding `Atlas Console.app`.
    public var url: URL
    /// The zip's SHA-256, lowercase hex.
    public var sha256: String

    public init(revision: String, build: Int, contract: String, url: URL, sha256: String) {
        self.revision = revision
        self.build = build
        self.contract = contract
        self.url = url
        self.sha256 = sha256
    }

    /// A feed's bytes, or why they name no release.
    public static func feed(_ data: Data) throws(FeedProblem) -> AppRelease {
        guard let release = try? JSONDecoder().decode(AppRelease.self, from: data) else { throw .unreadable }
        guard !release.revision.isEmpty, release.build > 0, ContractVersion(release.contract) != nil,
              release.url.scheme == "https", release.sha256.count == 64,
              release.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else { throw .unreadable }
        return release
    }
}

/// Why the feed gave no release.
public enum FeedProblem: Error, Sendable, Equatable {
    /// Not reached (no network, no tunnel to GitHub, a status other than 200), and why.
    case unreachable(String)
    /// Reached, but not a feed this app reads.
    case unreadable
}

/// A contract version, x.y.z, ordered as Control orders them (`Version.compare`).
public struct ContractVersion: Comparable, Sendable {
    let parts: [Int]

    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 3, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        self.parts = parts.map { $0! }
    }

    public static func < (a: ContractVersion, b: ContractVersion) -> Bool {
        a.parts.lexicographicallyPrecedes(b.parts)
    }
}

/// The short form of a revision the texts use.
func short(_ revision: String) -> String { String(revision.prefix(7)) }

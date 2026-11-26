// swift-tools-version: 6.0
// The Apple clients' hand-written code (docs/design/apple-clients.md §2). The contract is
// the generated package AtlasControlKit, published in github.com/mimbre/atlas-swift with a
// tag per contract version; nothing here is generated.
import Foundation
import PackageDescription

// The contract version this app speaks: `version` in
// platform/atlas_control/backend/contract/lib/contract.ex (CI fails when they differ).
let contractVersion: Version = "0.25.0"

// ATLAS_SWIFT_PACKAGE, a folder, builds against that package instead of the published one:
// the one `bin/generate atlas` writes (platform/atlas_control/backend/targets/swift), for a
// contract whose version is not published yet.
let local = ProcessInfo.processInfo.environment["ATLAS_SWIFT_PACKAGE"].flatMap { $0.isEmpty ? nil : $0 }
let contract: Package.Dependency = local.map { .package(path: $0) }
    ?? .package(url: "https://github.com/mimbre/atlas-swift", exact: contractVersion)
// A package's identity is its URL's or folder's last component.
let identity = local.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() } ?? "atlas-swift"
let kit: Target.Dependency = .product(name: "AtlasControlKit", package: identity)

let package = Package(
    name: "AtlasApple",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // Transport and session state, no UI; the same on macOS and iOS.
        .library(name: "ControlSession", targets: ["ControlSession"]),
        // SwiftUI views of blocks; the same on macOS and iOS.
        .library(name: "BlockViews", targets: ["BlockViews"]),
        // The app's update from the release feed (IS-Atlas-66): the decision, its texts and
        // the updater, on an injected feed and installer. Foundation only.
        .library(name: "AppUpdate", targets: ["AppUpdate"]),
        // The macOS app: the three-column window (§2, "The shell").
        .executable(name: "AtlasMac", targets: ["AtlasMac"]),
    ],
    dependencies: [contract],
    targets: [
        .target(name: "ControlSession", dependencies: [kit]),
        .target(name: "BlockViews", dependencies: ["ControlSession", kit]),
        .target(name: "AppUpdate"),
        .executableTarget(name: "AtlasMac", dependencies: ["ControlSession", "BlockViews", "AppUpdate", kit], path: "Mac"),
        .testTarget(name: "ControlSessionTests", dependencies: ["ControlSession", kit]),
        .testTarget(name: "AppUpdateTests", dependencies: ["AppUpdate"]),
        .testTarget(name: "BlockViewsTests", dependencies: ["BlockViews", "ControlSession", kit]),
    ],
    swiftLanguageModes: [.v6]
)

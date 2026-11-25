// swift-tools-version: 6.0
// The Apple clients' hand-written code (docs/design/apple-clients.md §2). The contract is
// the generated package AtlasControlKit (platform/atlas_control/backend/targets/swift); nothing here is generated.
import PackageDescription

let kit: Target.Dependency = .product(name: "AtlasControlKit", package: "swift")

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
    dependencies: [
        .package(path: "../../atlas_control/backend/targets/swift")
    ],
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

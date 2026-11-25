#if os(macOS)
import AppKit
import AppUpdate
import CryptoKit
import Foundation
import Security

/// Takes a release in place of this app (IS-Atlas-66): downloads its zip, checks the
/// feed's digest, unpacks it, checks that it is `Atlas Console.app` of that revision,
/// validly signed and meeting this app's own designated requirement (the same identifier
/// and the same Developer ID team), then swaps it for this app's bundle. Nothing is
/// replaced until every check passed. A local build (ad-hoc signed) has no team, so no
/// release meets its requirement: it never replaces itself.
struct BundleInstaller: ReleaseInstaller {
    /// This app's bundle.
    let app: URL
    /// The launch arguments for the app started on a page.
    let arguments: @Sendable (String?) -> [String]

    static let bundleName = "Atlas Console.app"

    func install(_ release: AppRelease) async throws {
        let files = FileManager.default
        guard files.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            throw InstallProblem("\(app.deletingLastPathComponent().path) cannot be written by this user; move Atlas Console to ~/Applications")
        }
        // On the app's volume, so the swap is a rename.
        let work: URL
        do {
            work = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        } catch {
            throw InstallProblem("no room next to \(app.path) to unpack it (\(error.localizedDescription))")
        }
        defer { try? files.removeItem(at: work) }

        let zip = work.appending(path: "release.zip")
        do {
            let (download, response) = try await URLSession.shared.download(from: release.url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw InstallProblem("the download answered \(status)") }
            try files.moveItem(at: download, to: zip)
        } catch let problem as InstallProblem {
            throw problem
        } catch {
            throw InstallProblem("the download failed (\(error.localizedDescription))")
        }
        guard try Self.sha256(zip) == release.sha256 else {
            throw InstallProblem("the download is not the release the feed names (its SHA-256 differs)")
        }

        let unpacked = work.appending(path: "unpacked")
        try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path], doing: "unpacking it")
        let new = unpacked.appending(path: Self.bundleName)
        let info = NSDictionary(contentsOf: new.appending(path: "Contents/Info.plist")) as? [String: Any]
        guard let found = InstalledApp(info: info) else {
            throw InstallProblem("the download holds no \(Self.bundleName) release")
        }
        guard found.revision == release.revision, found.build == release.build else {
            throw InstallProblem("the download holds \(found.revision.prefix(7)), not \(release.revision.prefix(7))")
        }
        try Self.verifySignature(new)

        do {
            _ = try files.replaceItemAt(app, withItemAt: new, backupItemName: nil, options: [])
        } catch {
            throw InstallProblem("\(app.path) could not be replaced (\(error.localizedDescription))")
        }
    }

    @MainActor
    func relaunch(on page: String?) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = arguments(page)
        configuration.activates = NSApp.isActive
        do {
            _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        } catch {
            throw InstallProblem(error.localizedDescription)
        }
        NSApp.terminate(nil)
    }

    /// Valid, strictly, and meeting this running app's designated requirement.
    static func verifySignature(_ bundle: URL) throws {
        var running: SecCode?
        var own: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &own) == errSecSuccess, let own,
              SecCodeCopyDesignatedRequirement(own, [], &requirement) == errSecSuccess, let requirement
        else { throw InstallProblem("this app's own signature could not be read") }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else {
            throw InstallProblem("the download's signature could not be read")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else {
            let why = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            throw InstallProblem("the download is not signed as this app is (\(why))")
        }
    }

    static func sha256(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func run(_ tool: String, _ arguments: [String], doing what: String) throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw InstallProblem("\(what) failed (\(error.localizedDescription))")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallProblem("\(what) failed (\(URL(filePath: tool).lastPathComponent) exited \(process.terminationStatus))")
        }
    }
}
#endif

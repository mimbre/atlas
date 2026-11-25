#if os(macOS)
import ControlSession
import Foundation

/// Starts the steer agent as the TUI does (`AtlasTui.App.start_agent`): `atlas steer --env
/// <env>` as a child process, JSON lines on stdin and stdout, stderr appended to
/// `steer.log` beside the environment's other logs (`ATLAS_TEST_ROOT`), else in the
/// temporary folder. `atlas` is the checkout's `bin/atlas`: `ATLAS_ROOT`'s, else the one
/// above this app (a build in the checkout), else an `atlas` on the `PATH` or in
/// `~/.local/bin`.
@MainActor
struct ProcessSteerConnector: SteerConnector {
    func connection(env: String) throws(SteerUnavailable) -> any SteerConnection {
        guard let atlas = Self.atlas() else {
            throw SteerUnavailable("atlas was not found; start the app with ATLAS_ROOT set to the Atlas checkout")
        }
        return ProcessSteerConnection(atlas: atlas, env: env, log: Self.log)
    }

    static var log: URL {
        let folder = ProcessInfo.processInfo.environment["ATLAS_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        return folder.appendingPathComponent("steer.log")
    }

    static func atlas() -> URL? {
        let files = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        var candidates: [URL] = []
        if let root = environment["ATLAS_ROOT"], !root.isEmpty {
            candidates.append(URL(fileURLWithPath: root).appendingPathComponent("bin/atlas"))
        }
        var folder = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        while let current = folder, current.path != "/" {
            candidates.append(current.appendingPathComponent("bin/atlas"))
            folder = current.deletingLastPathComponent()
        }
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for entry in path + [files.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path] {
            candidates.append(URL(fileURLWithPath: entry).appendingPathComponent("atlas"))
        }
        return candidates.first { files.isExecutableFile(atPath: $0.path) }
    }
}

/// One `atlas steer` process.
@MainActor
final class ProcessSteerConnection: SteerConnection {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let log: URL
    private var framer = LineFramer()
    private var events: (@MainActor (SteerEvent) -> Void)?
    private var stopped = false

    init(atlas: URL, env: String, log: URL) {
        self.log = log
        process.executableURL = atlas
        process.arguments = ["steer", "--env", env]
        process.standardInput = input
        process.standardOutput = output
    }

    func start(_ events: @escaping @MainActor (SteerEvent) -> Void) {
        self.events = events
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        if let errors = try? FileHandle(forWritingTo: log) {
            errors.seekToEndOfFile()
            process.standardError = errors
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(bytes) }
            }
        }
        let log = log.path
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.ended("it exited with \(status); see \(log)") }
            }
        }
        do {
            try process.run()
        } catch {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.ended("it could not be started (\(error.localizedDescription))") }
            }
        }
    }

    func send(_ line: Data) {
        guard !stopped, process.isRunning else { return }
        try? input.fileHandleForWriting.write(contentsOf: line)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        events = nil
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    private func receive(_ bytes: Data) {
        guard !stopped, !bytes.isEmpty else { return }
        do {
            for line in try framer.append(bytes) { events?(.line(line)) }
        } catch {
            ended("it sent a line longer than 4 MB")
            stop()
        }
    }

    private func ended(_ why: String) {
        guard !stopped else { return }
        let events = self.events
        stop()
        events?(.exited(why))
    }
}
#endif

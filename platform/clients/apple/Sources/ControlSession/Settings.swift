import Foundation

/// Where and how the session reaches Control. The launcher (`bin/atlas mac`, §5) passes
/// these as launch arguments; tests and the integration test build them directly or from
/// an environment's settings file.
public struct SessionSettings: Sendable, Equatable {
    /// The environment the app is for (`test`, `prod`): said in hello, checked in welcome
    /// and boot.
    public var env: String
    public var host: String
    public var port: UInt16
    /// How often the session reconciles (`refresh`), in seconds; 5 as in the TUI.
    public var reconcileSeconds: Double
    /// The client name said in hello. Control takes `tui` for the person's console (its
    /// `tui_user`); any other name is an agent. The app is that console, so it says `tui`.
    public var client: String
    /// The page to open first instead of the shell's start (`--to`): the page the app
    /// showed before it updated itself.
    public var startPage: String?

    public static let defaultReconcileSeconds: Double = 5

    public init(env: String, host: String, port: UInt16, reconcileSeconds: Double = SessionSettings.defaultReconcileSeconds, client: String = "tui", startPage: String? = nil) {
        self.env = env
        self.host = host
        self.port = port
        self.reconcileSeconds = reconcileSeconds
        self.client = client
        self.startPage = startPage
    }

    /// The launch arguments that start an app with these settings (the updated app's).
    public var arguments: [String] {
        var arguments = ["--env", env, "--host", host, "--port", String(port), "--reconcile-seconds", String(reconcileSeconds)]
        if let startPage { arguments += ["--to", startPage] }
        return arguments
    }

    /// Why launch arguments or a settings file give no settings.
    public enum Problem: Error, Equatable {
        /// No `--env`, `--host` or `--port`: started without the launcher.
        case notLaunched
        case missing(String)
        case invalid(String)
    }

    /// The settings in launch arguments: `--env <env> --host <host> --port <port>`, and
    /// optionally `--reconcile-seconds <n>` and `--to <page>`. Other arguments (the
    /// system's) are ignored. Without the first three, a release's bundle gives them
    /// (`AtlasControl` in its `Info.plist`, `bundle`), when it has them.
    public static func launch(_ arguments: [String], bundle info: [String: Any]? = nil) throws(Problem) -> SessionSettings {
        var values: [String: String] = [:]
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            guard ["--env", "--host", "--port", "--reconcile-seconds", "--to"].contains(argument) else { continue }
            guard let value = rest.popFirst() else { throw .missing(argument) }
            values[argument] = value
        }
        let startPage = values.removeValue(forKey: "--to")
        if values["--env"] == nil, values["--host"] == nil, values["--port"] == nil,
           let control = info?["AtlasControl"] as? [String: Any] {
            if let env = control["env"] as? String { values["--env"] = env }
            if let host = control["host"] as? String { values["--host"] = host }
            if let port = control["port"] as? Int { values["--port"] = String(port) }
        }
        if values.isEmpty { throw .notLaunched }
        guard let env = values["--env"], !env.isEmpty else { throw .missing("--env") }
        guard let host = values["--host"], !host.isEmpty else { throw .missing("--host") }
        guard let text = values["--port"] else { throw .missing("--port") }
        guard let port = UInt16(text), port > 0 else { throw .invalid("--port") }
        var reconcile = defaultReconcileSeconds
        if let text = values["--reconcile-seconds"] {
            guard let seconds = Double(text), seconds > 0 else { throw .invalid("--reconcile-seconds") }
            reconcile = seconds
        }
        return SessionSettings(env: env, host: host, port: port, reconcileSeconds: reconcile, startPage: startPage)
    }

    /// The settings in an environment's settings file (`products/software_factory/environments/<env>.json`, or the file
    /// `ATLAS_ENV_FILE` names): `env`, `control.host`, `control.port`, `reconcile_seconds`.
    public static func file(_ data: Data) throws(Problem) -> SessionSettings {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw .invalid("file") }
        guard let env = object["env"] as? String, !env.isEmpty else { throw .missing("env") }
        guard let control = object["control"] as? [String: Any] else { throw .missing("control") }
        guard let host = control["host"] as? String, !host.isEmpty else { throw .missing("control.host") }
        guard let number = control["port"] as? Int, let port = UInt16(exactly: number), port > 0 else { throw .invalid("control.port") }
        let reconcile = (object["reconcile_seconds"] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? defaultReconcileSeconds
        return SessionSettings(env: env, host: host, port: port, reconcileSeconds: reconcile)
    }
}

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

    public static let defaultReconcileSeconds: Double = 5

    public init(env: String, host: String, port: UInt16, reconcileSeconds: Double = SessionSettings.defaultReconcileSeconds, client: String = "tui") {
        self.env = env
        self.host = host
        self.port = port
        self.reconcileSeconds = reconcileSeconds
        self.client = client
    }

    /// Why launch arguments or a settings file give no settings.
    public enum Problem: Error, Equatable {
        /// No `--env`, `--host` or `--port`: started without the launcher.
        case notLaunched
        case missing(String)
        case invalid(String)
    }

    /// The settings in launch arguments: `--env <env> --host <host> --port <port>`, and
    /// optionally `--reconcile-seconds <n>`. Other arguments (the system's) are ignored.
    public static func launch(_ arguments: [String]) throws(Problem) -> SessionSettings {
        var values: [String: String] = [:]
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            guard ["--env", "--host", "--port", "--reconcile-seconds"].contains(argument) else { continue }
            guard let value = rest.popFirst() else { throw .missing(argument) }
            values[argument] = value
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
        return SessionSettings(env: env, host: host, port: port, reconcileSeconds: reconcile)
    }

    /// The settings in an environment's settings file (`env/<env>.json`, or the file
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

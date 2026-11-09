#if os(macOS)
import ControlSession
import SwiftUI

/// Below the columns: connected or not, the position of the page on screen, how and when
/// it last changed, the last hint, the reconcile interval and the last notice.
struct StatusBar: View {
    let status: StatusViewModel
    let shell: ShellViewModel

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                Circle().fill(dot).frame(width: 8, height: 8)
                Text(connection)
            }
            if let position = status.position {
                Text("position \(position)")
            }
            if let update = status.lastUpdate {
                Text("\(update.reason.rawValue) \(update.at ?? "")")
            }
            if let hint = status.lastHint {
                Text("last hint \(hint.at ?? "")\(hint.position.map { " @\($0)" } ?? "")")
            }
            Text("refresh every \(status.reconcileSeconds.formatted()) s")
            if let failure = shell.bootFailure {
                Text(bootFailure(failure)).foregroundStyle(.orange)
            }
            if let failure = status.openFailure {
                Text("\(failure.path) could not be read (\(failure.reason))").foregroundStyle(.red)
            }
            Spacer(minLength: 8)
            if let notice = status.notice {
                Text(notice.text)
                    .foregroundStyle(tone(notice.tone))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private var connection: String {
        switch status.connection {
        case .idle, .connecting: "connecting…"
        case .handshake: "saying hello…"
        case .connected: "connected"
        case .retrying: "not connected; retrying every 2 s"
        case .ended: "disconnected"
        }
    }

    private var dot: Color {
        switch status.connection {
        case .connected: .green
        case .retrying, .ended: .red
        default: .yellow
        }
    }

    private func tone(_ tone: String) -> Color {
        switch tone {
        case "ok": .green
        case "error": .red
        case "pending": .orange
        default: .secondary
        }
    }

    private func bootFailure(_ failure: SessionState.BootFailure) -> String {
        switch failure {
        case .control(let text): text
        case .invalid: "shell not accepted; showing the last good tabs"
        case .unreadable(let reason): "shell could not be read (\(reason)); showing the last good tabs"
        case .timedOut: "boot timed out"
        }
    }
}
#endif

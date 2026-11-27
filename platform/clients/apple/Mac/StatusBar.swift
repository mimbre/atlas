#if os(macOS)
import AppUpdate
import BlockViews
import ControlSession
import Prism
import SwiftUI

/// Below the columns: connected or not (when not, why and what happens next, in plain
/// words: the window shows no message of its own), the position of the page on screen,
/// how and when it last changed, the last hint, the reconcile interval, what is being sent
/// and not answered yet, the app's update and the last notice.
struct StatusBar: View {
    let status: StatusViewModel
    let shell: ShellViewModel
    /// What the app's update says ("Updating to <revision>…"), when it says anything.
    let update: (text: String, tone: UpdateStatus.Tone)?

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                Circle().fill(dot).frame(width: 8, height: 8)
                let connection = status.text()
                Text(connection)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .help(connection)
            }
            .layoutPriority(1)
            // Control speaks another contract version: said, never blocking (D-0105).
            if let warning = status.versionWarning {
                Text(warning).foregroundStyle(.orange).lineLimit(1).truncationMode(.middle)
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
            // What is being sent (or opened, or asked), at once, until Control answers.
            if let pending = status.pending {
                HStack(spacing: 5) {
                    ProgressView().progressViewStyle(.prism(.accent, size: .size16))
                    Text(pending).foregroundStyle(.orange).lineLimit(1).truncationMode(.middle)
                }
            }
            if let update {
                Text(update.text)
                    .foregroundStyle(tone(update.tone.rawValue))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(update.text)
            }
            if let notice = status.notice, let text = notice.text {
                Text(text)
                    .foregroundStyle(tone(notice.tone ?? ""))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .prism(Prism.Typography.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private var dot: Color {
        switch status.mark {
        case .connected: .green
        case .notConnected: .red
        case .connecting: .yellow
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

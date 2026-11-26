import AtlasControlKit
import Prism
import SwiftUI

/// The steer agent's plan (the contract's `plan` block), over the window, as the TUI shows
/// it over the page: what was asked, the plan's title (which says how far it is), who made
/// it and why, and its steps with their state, values and what they did. Proposed, a step
/// can be kept or dropped, and Run (Return) runs the kept ones; while it is made or
/// proposed, Cancel (Esc) drops it; running, Stop stops it before its next step; once over,
/// Close (Esc, Return) closes it.
public struct PlanView: View {
    let plan: PlanBlock
    let dropped: Set<Int>
    let run: () -> Void
    let toggle: (Int) -> Void
    let stop: () -> Void
    let close: () -> Void

    public init(plan: PlanBlock, dropped: Set<Int>, run: @escaping () -> Void, toggle: @escaping (Int) -> Void,
                stop: @escaping () -> Void, close: @escaping () -> Void) {
        self.plan = plan
        self.dropped = dropped
        self.run = run
        self.toggle = toggle
        self.stop = stop
        self.close = close
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Prism.Spacing.px15) {
            HStack(spacing: Prism.Spacing.px10) {
                if plan.state == "planning" || plan.state == "running" {
                    ProgressView().progressViewStyle(.prism(.accent, size: .size20))
                }
                Text(plan.title ?? "").prism(Prism.Typography.title6).accessibilityAddTraits(.isHeader)
            }
            if let request = plan.request, !request.isEmpty {
                Text("Asked: \(request)").foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let before = plan.before, !before.isEmpty {
                Text(before).fixedSize(horizontal: false, vertical: true)
            }
            if let summary = plan.summary, !summary.isEmpty {
                Text(summary).fixedSize(horizontal: false, vertical: true)
            }
            if let by = plan.by, !by.isEmpty {
                Text("By \(by)").font(.caption).foregroundStyle(.secondary)
            }
            if let steps = plan.steps, !steps.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: Prism.Spacing.px10) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                            stepView(step)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 420)
            }
            HStack(spacing: Prism.Spacing.px10) {
                Spacer()
                buttons
            }
        }
        .padding(Prism.Spacing.px22)
        .frame(minWidth: 460, idealWidth: 560, maxWidth: WindowLayout.page, alignment: .leading)
    }

    @ViewBuilder private var buttons: some View {
        switch plan.state {
        case "planning":
            Button("Cancel", action: close).keyboardShortcut(.cancelAction)
        case "proposed":
            Button("Cancel", action: close).keyboardShortcut(.cancelAction)
            Button(runLabel, action: run)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(kept == 0)
        case "running":
            Button("Stop", action: stop).keyboardShortcut(.cancelAction)
        default:
            Button("Close", action: close)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
    }

    private var kept: Int { (plan.steps ?? []).filter { !isDropped($0) }.count }

    private func isDropped(_ step: StepModel) -> Bool {
        step.state == "dropped" || (step.n.map { dropped.contains($0) } ?? false)
    }

    private var runLabel: String { kept == 1 ? "Run 1 step" : "Run \(kept) steps" }

    private func stepView(_ step: StepModel) -> some View {
        let isDropped = isDropped(step)
        return HStack(alignment: .top, spacing: Prism.Spacing.px10) {
            if plan.state == "proposed", let n = step.n {
                Toggle("Keep step \(n)", isOn: Binding(get: { !isDropped }, set: { _ in toggle(n) }))
                    .labelsHidden()
                    #if os(macOS)
                    .toggleStyle(.checkbox)
                    #endif
            }
            if let n = step.n { Text("\(n).").monospaced().bold() }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(step.label ?? "").bold().strikethrough(isDropped)
                    Text(isDropped ? "dropped" : step.state ?? "").font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
                ForEach(Array((step.inputs ?? []).enumerated()), id: \.offset) { _, input in
                    Text([input.label, input.value].compactMap { $0 }.joined(separator: ": ")).foregroundStyle(.secondary)
                }
                if let why = step.why, !why.isEmpty {
                    Text(why).foregroundStyle(.secondary)
                }
                if let detail = step.detail, !detail.isEmpty {
                    Text(detail)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
        .opacity(isDropped ? 0.6 : 1)
    }
}

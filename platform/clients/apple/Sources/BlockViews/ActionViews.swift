import AtlasControlKit
import SwiftUI

/// The actions a page's blocks declare, as Control sends them: what a key or a button
/// takes. The app decides nothing about an action; its order, label and key are Control's.
public enum PageActions {
    /// Every action of the page's `item` and `list` blocks, in block order.
    public static func all(_ page: PageMessage) -> [ActionModel] {
        page.blocks.flatMap { block -> [ActionModel] in
            switch block.content {
            case .item(let item): item.actions ?? []
            case .list(let list): list.actions ?? []
            default: []
            }
        }
    }

    /// The page's first action with this key.
    public static func action(key: String, on page: PageMessage?) -> ActionModel? {
        guard let page else { return nil }
        return all(page).first { $0.key == key }
    }

    /// One button per thing to do: an action that does exactly what an earlier one does
    /// (the same page and call, under another label and key) has no button of its own;
    /// its key still works. An action that is neither a call nor a page (`agent:…`, the
    /// agent behind `:`, S7) has none either.
    public static func buttons(_ actions: [ActionModel]) -> [ActionModel] {
        actions.enumerated().filter { offset, action in
            (action.submitTo != nil || Page.match(action.to) != nil)
                && !actions[..<offset].contains { $0.to == action.to && $0.submitTo == action.submitTo }
        }.map(\.element)
    }
}

/// A button per action, in Control's order; the first, the next step, prominent. Each
/// shows its key.
struct ActionsView: View {
    let actions: [ActionModel]
    let act: (ActionModel) -> Void

    var body: some View {
        let shown = PageActions.buttons(actions)
        if !shown.isEmpty {
            FlowLayout(spacing: Prism.Spacing.s10) {
                ForEach(Array(shown.enumerated()), id: \.offset) { offset, action in
                    if offset == 0 {
                        button(action).buttonStyle(.borderedProminent)
                    } else {
                        button(action).buttonStyle(.bordered)
                    }
                }
            }
            .textSelection(.disabled)
        }
    }

    private func button(_ action: ActionModel) -> some View {
        Button { act(action) } label: {
            HStack(spacing: Prism.Spacing.s6) {
                Text(action.label)
                if action.key.count == 1 {
                    Text(action.key).font(.caption.monospaced()).opacity(0.7)
                }
            }
        }
        .help("\(action.label) (key \(action.key))")
    }
}

/// Lays its views out in rows, wrapping to the next row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !row.indices.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// The page of an action being taken, over the window: its confirm, its form, or the
/// more actions it offers, with what Control refused. `submit` sends a call the page
/// declares, `act` takes one of its actions (a click; the app maps their keys), `leave`
/// leaves it (Cancel, Esc).
public struct ActionPageView: View {
    let page: PageMessage
    let draft: [String: String]
    let submitting: Bool
    let act: (ActionModel) -> Void
    let submit: (CallModel, [String: String]) -> Void
    let edit: (String, String) -> Void
    let leave: () -> Void

    public init(page: PageMessage, draft: [String: String], submitting: Bool,
                act: @escaping (ActionModel) -> Void,
                submit: @escaping (CallModel, [String: String]) -> Void,
                edit: @escaping (String, String) -> Void, leave: @escaping () -> Void) {
        self.page = page
        self.draft = draft
        self.submitting = submitting
        self.act = act
        self.submit = submit
        self.edit = edit
        self.leave = leave
    }

    private var presentation: PagePresentation { PagePresentation(page) }

    /// The page asks something itself (a confirm or a form), with its own Cancel.
    private var asks: Bool {
        presentation.entries.contains {
            switch $0.item {
            case .confirm, .form: true
            default: false
            }
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Prism.Spacing.s15) {
            if !asks {
                Text(page.title).prism(Prism.Typography.title7)
            }
            ForEach(refused, id: \.self) { reason in
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Prism.Colors.error)
            }
            ForEach(presentation.entries) { entry in
                entryView(entry)
            }
            if !asks {
                HStack {
                    Spacer()
                    Button("Cancel", action: leave).keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(Prism.Spacing.s22)
        .frame(minWidth: 460, idealWidth: 560, maxWidth: 720, alignment: .leading)
    }

    /// What Control refused, in its words.
    private var refused: [String] {
        (page.refused ?? []).map { $0.string ?? String(describing: $0) }
    }

    @ViewBuilder private func entryView(_ entry: PagePresentation.Entry) -> some View {
        switch entry.item {
        case .confirm(let confirm):
            ConfirmView(block: confirm, submitting: submitting, submit: submit, leave: leave)
        case .form(let form):
            FormView(block: form, draft: draft, submitting: submitting, edit: edit, submit: submit, leave: leave)
                .id(page.path)
        case .item(let item):
            ItemBlockView(item: item, act: act)
        case .list(let list):
            ListBlockView(list: list, selectedPath: nil, open: { _ in }, act: act)
        case .singleChoice(let choice):
            SingleChoiceView(block: choice, submit: submit)
        case .notShown(let type): FallbackView(type: type, reason: nil)
        case .fallback(let fallback): FallbackView(type: fallback.type, reason: fallback.reason)
        }
    }
}

/// A confirm: its question and text; Confirm sends its call (Return), Cancel leaves it
/// (Esc). Without a call it only explains, and only Cancel is there.
struct ConfirmView: View {
    let block: ConfirmBlock
    let submitting: Bool
    let submit: (CallModel, [String: String]) -> Void
    let leave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Prism.Spacing.s15) {
            Text(block.title).prism(Prism.Typography.title6)
            Text(block.text).prism(Prism.Typography.caption)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: Prism.Spacing.s10) {
                if submitting {
                    ProgressView().controlSize(.small)
                    Text("Sending…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: leave).keyboardShortcut(.cancelAction)
                if let call = block.confirmTo {
                    Button(block.confirmLabel ?? "Confirm") { submit(call, [:]) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(submitting)
                }
            }
        }
    }
}

/// A form: its inputs by kind (text, multiline, choice, read-only; any other kind as
/// text), Control's errors, and Save (⌘S) or Cancel (Esc). Tab moves between fields.
/// What is typed goes to `edit` (the session's draft); Save sends every input's value.
struct FormView: View {
    let block: FormBlock
    let draft: [String: String]
    let submitting: Bool
    let edit: (String, String) -> Void
    let submit: (CallModel, [String: String]) -> Void
    let leave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Prism.Spacing.s15) {
            Text(block.title).prism(Prism.Typography.title6)
            ForEach(block.errors ?? [], id: \.self) { error in
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Prism.Colors.error)
            }
            Form {
                ForEach(block.inputs, id: \.name) { input in
                    field(input)
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 240, idealHeight: 420)
            HStack(spacing: Prism.Spacing.s10) {
                if submitting {
                    ProgressView().controlSize(.small)
                    Text("Sending…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: leave).keyboardShortcut(.cancelAction)
                Button(block.submitLabel) { submit(block.submitTo, Self.values(block, draft)) }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(submitting)
                    .help("\(block.submitLabel) (⌘S)")
            }
        }
    }

    /// Every input's value: what was typed, else the value Control sent.
    static func values(_ block: FormBlock, _ draft: [String: String]) -> [String: String] {
        Dictionary(block.inputs.map { ($0.name, draft[$0.name] ?? $0.value ?? "") }) { first, _ in first }
    }

    private func binding(_ input: InputModel) -> Binding<String> {
        Binding(get: { draft[input.name] ?? input.value ?? "" }, set: { edit(input.name, $0) })
    }

    private func label(_ input: InputModel) -> String {
        input.required == true ? input.label + " *" : input.label
    }

    @ViewBuilder private func field(_ input: InputModel) -> some View {
        switch input.kind {
        case "readonly":
            LabeledContent(input.label) { Text(input.value ?? "—").textSelection(.enabled) }
        case "choice", "boolean":
            Picker(label(input), selection: binding(input)) {
                ForEach(input.choices ?? [], id: \.value) { choice in
                    Text(choice.label).tag(choice.value)
                }
            }
            .help(input.hint ?? "")
        case "multiline":
            TextField(label(input), text: binding(input), prompt: input.hint.map(Text.init), axis: .vertical)
                .lineLimit(3...12)
        default:
            TextField(label(input), text: binding(input), prompt: input.hint.map(Text.init))
        }
    }
}

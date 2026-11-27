import AtlasControlKit
import ControlSession
import Prism
import SwiftUI

extension EnvironmentValues {
    /// What the user did that Control (or the agent) has not answered yet: its button and
    /// the sheet show it at once (`SessionState.Pending`).
    @Entry public var pendingAction: SessionState.Pending? = nil
    /// The panel on screen takes ↑, ↓ and Return through it (`PanelKeys`).
    @Entry public var panelKeys: PanelKeys? = nil
}

/// The actions a page's blocks declare, as Control sends them: what a key or a button
/// takes. The app decides nothing about an action; its order, label and key are Control's.
/// An action Control marks `page` is the page's (what is done with its subject) and shows
/// with the page's title; any other is its block's and shows under the block.
public enum PageActions {
    /// Every action of the page's `item`, `list` and `actions` blocks, of its panels (their answers
    /// as actions, then their own; `Panel.actions`), of its options (`Option.actions`) and
    /// of its `answers` blocks (each answer as the page's action of its key, `Panel.action`),
    /// in block order.
    public static func all(_ page: PageMessage) -> [ActionModel] {
        (page.blocks ?? []).flatMap { block -> [ActionModel] in
            switch block.content {
            case .item(let item): item.actions ?? []
            case .list(let list): list.actions ?? []
            case .panel(let panel): Panel.actions(panel)
            case .option(let option): Option.actions(option)
            case .answers(let answers): (answers.answers ?? []).map(Panel.action)
            case .actions(let actions): actions.actions ?? []
            default: []
            }
        }
    }

    /// The page's own actions (`page`), in block order; not those a panel, an option or an
    /// `answers` block of the page shows (by key, or doing what one does).
    public static func ofPage(_ page: PageMessage) -> [ActionModel] {
        let shown = (page.blocks ?? []).flatMap { block -> [ActionModel] in
            switch block.content {
            case .panel(let panel): Panel.actions(panel)
            case .option(let option): Option.actions(option)
            case .answers(let answers): (answers.answers ?? []).map(Panel.action)
            default: []
            }
        }
        return all(page).filter { action in
            action.page == true
                && !shown.contains { $0.key == action.key || ($0.to == action.to && $0.submitTo == action.submitTo) }
        }
    }

    /// The first link of the page's panels with this key that a client opens (http,
    /// https), unless an action has the key; nil when none has.
    public static func link(key: String, on pages: [PageMessage?]) -> URL? {
        for page in pages.compactMap({ $0 }) {
            if all(page).contains(where: { $0.key == key }) { return nil }
            for block in page.blocks ?? [] {
                guard case .panel(let panel) = block.content else { continue }
                if let link = Panel.links(panel).first(where: { $0.link.key == key }) { return link.url }
            }
        }
        return nil
    }

    /// A block's own actions: those that are not the page's.
    public static func ofBlock(_ actions: [ActionModel]?) -> [ActionModel] {
        (actions ?? []).filter { $0.page != true }
    }

    /// What else can be done with the page's subject: the actions of its `actions` blocks,
    /// in Control's order (Update, Hand to, Failures…, Delete). The opened item's go in the
    /// window's toolbar, its context menu and the Actions menu, not on the page.
    public static func others(_ page: PageMessage?) -> [ActionModel] {
        (page?.blocks ?? []).flatMap { block -> [ActionModel] in
            if case .actions(let actions) = block.content { return actions.actions ?? [] }
            return []
        }
    }

    /// The buttons of `actions` (`buttons`) in Control's order, but a Delete (icon
    /// `delete`), which goes last, apart, in the danger colour.
    public static func split(_ actions: [ActionModel]) -> (rest: [ActionModel], delete: ActionModel?) {
        let buttons = buttons(actions)
        let delete = buttons.last { $0.icon == "delete" }
        return (buttons.filter { $0.icon != "delete" }, delete)
    }

    /// Whether an answer of an `answers` block goes in the window's toolbar with the opened
    /// item's actions rather than at the page's bottom: one of weight `other` (Ask a
    /// question, Hand over, Leave it to the proposer, Pick up). The main answer and the
    /// decline (Accept, Decline, Decline all, Done, Won't do) stay on the page.
    public static func inToolbar(_ answer: PanelAnswerModel) -> Bool {
        answer.weight == "other"
    }

    /// Everything in the window's toolbar for the opened page (and its context menu): its
    /// item's actions (`others`, Update first), then its `answers` blocks' `other` answers
    /// in Control's order, each taken as its key's action is (its call, else its page: one
    /// asking a note opens the note form), with its icon and short label; Delete last. One
    /// button per thing to do (`buttons`). None when nothing is open.
    public static func toolbar(_ page: PageMessage?) -> [ActionModel] {
        let answers = (page?.blocks ?? []).flatMap { block -> [ActionModel] in
            guard case .answers(let answers) = block.content else { return [] }
            return (answers.answers ?? []).filter(inToolbar).map { answer in
                ActionModel(label: answer.label, key: answer.key, to: answer.to, submitTo: answer.submitTo,
                            icon: answer.icon, button: answer.button, help: answer.help)
            }
        }
        let (rest, delete) = split(others(page) + answers)
        return rest + [delete].compactMap { $0 }
    }

    /// The index page's own actions (`ofPage`: Create to-do, …) in the list column's
    /// toolbar, above the list, one per thing to do (`buttons`): quiet icons as the opened
    /// item's are, never a prominent button. None without an index page.
    public static func listToolbar(_ page: PageMessage?) -> [ActionModel] {
        page.map { buttons(ofPage($0)) } ?? []
    }


    /// An action's tooltip: what Control says it does in full (`help`), else its label.
    public static func tooltip(_ action: ActionModel) -> String {
        Tooltip.of(help: action.help, label: action.label)
    }

    /// The page's first action with this key.
    public static func action(key: String, on page: PageMessage?) -> ActionModel? {
        guard let page else { return nil }
        return all(page).first { $0.key == key }
    }

    /// The action a key takes on the pages shown: the first page's first, then the next's.
    public static func action(key: String, on pages: [PageMessage?]) -> ActionModel? {
        for page in pages {
            if let action = action(key: key, on: page) { return action }
        }
        return nil
    }

    /// Whether the action does something this app can do: submit a call, open a page of
    /// Control's, or ask the agent (`agent:<intent>`).
    public static func doable(_ action: ActionModel) -> Bool {
        action.submitTo != nil || action.to.flatMap(Page.match) != nil || SessionState.agentIntent(action.to) != nil
    }

    /// One button per thing to do: an action that does exactly what an earlier one does
    /// (the same page and call, under another label and key) has no button of its own;
    /// its key still works. An action that does nothing this app can do has none.
    public static func buttons(_ actions: [ActionModel]) -> [ActionModel] {
        actions.enumerated().filter { offset, action in
            doable(action)
                && !actions[..<offset].contains { $0.to == action.to && $0.submitTo == action.submitTo }
        }.map(\.element)
    }

    /// Whether `action`'s button is the one pending: the same page or call (a button
    /// stands for every action that does what it does).
    public static func isPending(_ action: ActionModel, _ pending: SessionState.Pending?) -> Bool {
        guard let taken = pending?.action else { return false }
        return taken.to == action.to && taken.submitTo == action.submitTo
    }

    /// What a submit of `call` on these pages is, in their words: the confirm's or form's
    /// button, or the action's label; nil when none declares it.
    public static func label(of call: CallModel, on pages: [PageMessage?]) -> String? {
        for page in pages.compactMap({ $0 }) {
            for block in page.blocks ?? [] {
                switch block.content {
                case .confirm(let confirm) where confirm.confirmTo == call:
                    return confirm.confirmLabel ?? "Confirm"
                case .form(let form) where form.submitTo == call:
                    return form.submitLabel
                default:
                    continue
                }
            }
            if let action = all(page).first(where: { $0.submitTo == call }) { return action.label }
        }
        return nil
    }
}

/// A button per action, in Control's order.
struct ActionsView: View {
    let actions: [ActionModel]
    let act: (ActionModel) -> Void

    var body: some View {
        if !PageActions.buttons(actions).isEmpty {
            FlowLayout(spacing: Prism.Spacing.px10) {
                ActionButtons(actions: actions, act: act)
            }
            .textSelection(.disabled)
        }
    }
}

/// The buttons of `actions` (`PageActions.buttons`), side by side on the page.
public struct ActionButtons: View {
    let actions: [ActionModel]
    let act: (ActionModel) -> Void
    @Environment(\.pendingAction) private var pending

    public init(actions: [ActionModel], act: @escaping (ActionModel) -> Void) {
        self.actions = actions
        self.act = act
    }

    public var body: some View {
        ForEach(Array(PageActions.buttons(actions).enumerated()), id: \.offset) { _, action in
            button(action).buttonStyle(.bordered)
        }
    }

    /// Its key is not shown (the menu bar lists it); its tooltip says what it does
    /// (`PageActions.tooltip`). Pending (clicked, or its key pressed, and not answered yet),
    /// the button shows a spinner before its label and takes no second click.
    private func button(_ action: ActionModel) -> some View {
        let pending = PageActions.isPending(action, pending)
        return Button { act(action) } label: {
            HStack(spacing: Prism.Spacing.px6) {
                if pending { ProgressView().progressViewStyle(.prism(.accent, size: .size16)) }
                Text(AnswerLook.label(action))
            }
        }
        .disabled(pending)
        .help(pending ? (self.pending?.text ?? PageActions.tooltip(action)) : PageActions.tooltip(action))
        .accessibilityValue(pending ? Text(self.pending?.text ?? "") : Text(""))
    }
}

/// A page's title with the page's actions (`PageActions.ofPage`) beside it, at the top of
/// the page, above its blocks; in a column too narrow for both on one line, the page's
/// actions go under the title, wrapping as they need. Without actions the title has the
/// full width. What else can be done with its subject is in the window's toolbar
/// (`ItemToolbar`), not here.
struct PageHeader: View {
    let title: String
    let actions: [ActionModel]
    let act: (ActionModel) -> Void

    var body: some View {
        Group {
            if PageActions.buttons(actions).isEmpty {
                heading.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: Prism.Spacing.px13) {
                        heading.fixedSize()
                        Spacer(minLength: 0)
                        HStack(spacing: Prism.Spacing.px10) {
                            ActionButtons(actions: actions, act: act)
                        }
                        .fixedSize()
                    }
                    VStack(alignment: .leading, spacing: Prism.Spacing.px10) {
                        heading.frame(maxWidth: .infinity, alignment: .leading)
                        FlowLayout(spacing: Prism.Spacing.px10) {
                            ActionButtons(actions: actions, act: act)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .textSelection(.disabled)
    }

    private var heading: some View {
        Text(title).prism(Prism.Typography.title3).accessibilityAddTraits(.isHeader)
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
/// leaves it (Cancel, Esc). While what was done on it is not answered, it says so;
/// `answer` is a notice that answered its submit without a page (why it was not stored).
public struct ActionPageView: View {
    let page: PageMessage
    let draft: [String: String]
    let submitting: Bool
    let answer: NoticeMessage?
    let act: (ActionModel) -> Void
    let submit: (CallModel, [String: String]) -> Void
    let edit: (String, String) -> Void
    let leave: () -> Void
    @Environment(\.pendingAction) private var pending

    public init(page: PageMessage, draft: [String: String], submitting: Bool, answer: NoticeMessage? = nil,
                act: @escaping (ActionModel) -> Void,
                submit: @escaping (CallModel, [String: String]) -> Void,
                edit: @escaping (String, String) -> Void, leave: @escaping () -> Void) {
        self.page = page
        self.draft = draft
        self.submitting = submitting
        self.answer = answer
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
        VStack(alignment: .leading, spacing: Prism.Spacing.px15) {
            if !asks {
                PageHeader(title: page.title ?? "", actions: PageActions.ofPage(page), act: act)
            }
            ForEach(refused, id: \.self) { reason in
                Label(reason, systemImage: "exclamationmark.triangle")
                    .prism(Prism.Typography.bodysmall)
                    .foregroundStyle(Prism.Colors.error)
            }
            if let text = answer?.text {
                Label(text, systemImage: "exclamationmark.triangle")
                    .prism(Prism.Typography.bodysmall)
                    .foregroundStyle(Prism.Colors.error)
            }
            ForEach(presentation.entries) { entry in
                entryView(entry)
            }
            if !asks {
                HStack(spacing: Prism.Spacing.px10) {
                    // The confirm and the form say "Sending…" themselves.
                    if let pending {
                        ProgressView().progressViewStyle(.prism(.accent, size: .size20))
                        Text(pending.text).prism(Prism.Typography.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel", action: leave).keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(Prism.Spacing.px22)
        .frame(minWidth: 460, idealWidth: 560, maxWidth: WindowLayout.page, alignment: .leading)
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
        case .option(let option):
            OptionView(block: option, act: act)
        case .panel(let panel):
            PanelView(block: panel, open: { _ in }, act: act)
        case .header(let header):
            HeaderBlockView(block: header, act: act)
        case .text(let text):
            TextBlockView(block: text)
        case .instruction(let instruction):
            InstructionView(block: instruction)
        case .answers(let answers):
            AnswersView(block: answers, act: act)
        case .actions(let actions):
            OtherActionsView(actions: actions.actions ?? [], act: act)
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
        VStack(alignment: .leading, spacing: Prism.Spacing.px15) {
            if let title = block.title { Text(title).prism(Prism.Typography.title6) }
            Text(block.text ?? "").prism(Prism.Typography.bodysmall)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: Prism.Spacing.px10) {
                if submitting {
                    ProgressView().progressViewStyle(.prism(.accent, size: .size20))
                    Text("Sending…").prism(Prism.Typography.caption).foregroundStyle(.secondary)
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
/// What is typed goes to `edit` (the session's draft); Save sends every shown input's
/// value. An input with `shown_when` is shown, required and sent only while the input it
/// names holds that value (`shown`). Save stays disabled until every shown required input
/// has a value (`complete`). A required choice without a value starts with none chosen,
/// as radio buttons; each choice's `help` is its tooltip.
struct FormView: View {
    let block: FormBlock
    let draft: [String: String]
    let submitting: Bool
    let edit: (String, String) -> Void
    let submit: (CallModel, [String: String]) -> Void
    let leave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Prism.Spacing.px15) {
            if let title = block.title { Text(title).prism(Prism.Typography.title6) }
            ForEach(block.errors ?? [], id: \.self) { error in
                Label(error, systemImage: "exclamationmark.triangle")
                    .prism(Prism.Typography.bodysmall)
                    .foregroundStyle(Prism.Colors.error)
            }
            Form {
                ForEach(Self.shown(block, draft), id: \.name) { input in
                    field(input)
                }
            }
            .formStyle(.grouped)
            .prism(Prism.Typography.bodysmall)
            .frame(minHeight: 240, idealHeight: 420)
            HStack(spacing: Prism.Spacing.px10) {
                if submitting {
                    ProgressView().progressViewStyle(.prism(.accent, size: .size20))
                    Text("Sending…").prism(Prism.Typography.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: leave).keyboardShortcut(.cancelAction)
                Button(block.submitLabel ?? "Save") { if let call = block.submitTo { submit(call, Self.values(block, draft)) } }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(submitting || block.submitTo == nil || !Self.complete(block, draft))
                    .help("\(block.submitLabel ?? "Save") (⌘S)")
            }
        }
    }

    /// The inputs that have a name: only those can be edited and sent.
    static func named(_ block: FormBlock) -> [InputModel] {
        (block.inputs ?? []).filter { $0.name != nil }
    }

    /// An input's value: what was typed, else the value Control sent, else none ("").
    static func value(_ input: InputModel, _ draft: [String: String]) -> String {
        draft[input.name ?? ""] ?? input.value ?? ""
    }

    /// The inputs shown: every named one, but one with `shown_when` only while the input it
    /// names holds its value.
    static func shown(_ block: FormBlock, _ draft: [String: String]) -> [InputModel] {
        let inputs = named(block)
        return inputs.filter { input in
            guard let condition = input.shownWhen else { return true }
            guard let other = inputs.first(where: { $0.name == condition.name }) else { return false }
            return value(other, draft) == condition.value
        }
    }

    /// Every shown input's value; one that is not shown is not sent.
    static func values(_ block: FormBlock, _ draft: [String: String]) -> [String: String] {
        Dictionary(shown(block, draft).map { ($0.name ?? "", value($0, draft)) }) { first, _ in first }
    }

    /// Whether every shown required input has a value, so the form may be saved.
    static func complete(_ block: FormBlock, _ draft: [String: String]) -> Bool {
        shown(block, draft).allSatisfy { input in
            input.required != true || input.kind == "readonly"
                || !value(input, draft).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Whether a choice starts with none chosen, as radio buttons: required, without a value.
    static func radio(_ input: InputModel) -> Bool {
        input.kind == "choice" && input.required == true && input.value == nil
    }

    private func binding(_ input: InputModel) -> Binding<String> {
        let name = input.name ?? ""
        return Binding(get: { Self.value(input, draft) }, set: { edit(name, $0) })
    }

    private func label(_ input: InputModel) -> String {
        let label = input.label ?? input.name ?? ""
        return input.required == true ? label + " *" : label
    }

    @ViewBuilder private func field(_ input: InputModel) -> some View {
        switch input.kind {
        case "readonly":
            LabeledContent(input.label ?? input.name ?? "") { Text(input.value ?? "—").textSelection(.enabled) }
        case "choice" where Self.radio(input):
            Picker(label(input), selection: binding(input)) { choices(input) }
                .radioGroup()
                .help(input.hint ?? "")
        case "choice", "boolean":
            Picker(label(input), selection: binding(input)) { choices(input) }
                .help(input.hint ?? "")
        case "multiline":
            TextField(label(input), text: binding(input), prompt: input.hint.map(Text.init), axis: .vertical)
                .lineLimit(3...12)
        default:
            TextField(label(input), text: binding(input), prompt: input.hint.map(Text.init))
        }
    }

    /// A choice's options, each its label, its `help` its tooltip.
    private func choices(_ input: InputModel) -> some View {
        ForEach(input.choices ?? [], id: \.value) { choice in
            Text(choice.label ?? choice.value ?? "").tag(choice.value ?? "")
                .help(choice.help ?? "")
        }
    }
}

private extension View {
    /// Radio buttons on macOS; iOS has none, and keeps its own picker.
    @ViewBuilder func radioGroup() -> some View {
        #if os(macOS)
        pickerStyle(.radioGroup)
        #else
        self
        #endif
    }
}

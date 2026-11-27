import ControlSession
import Prism
import SwiftUI

/// One row of the sidebar: a tab (with its icon, and its fold when it has groups) or a
/// group under it, in the order boot sent them.
public struct SidebarItem: Identifiable, Equatable, Sendable {
    /// A tab, by its id, or a group of a tab's page, by its `to`.
    public enum ID: Hashable, Sendable {
        case tab(String)
        case group(String)
    }

    public let id: ID
    public let label: String
    /// The semantic icon name Control sent (a tab's only).
    public let icon: String?
    public let count: Int?
    /// Whether the count is what waits for the user.
    public let forYou: Bool
    /// Whether its groups are shown (a tab with groups); nil for any other row.
    public let open: Bool?

    public var isGroup: Bool {
        if case .group = id { true } else { false }
    }

    /// The rows of one section ("work" or "browse"): each tab, and under a tab that is not
    /// folded (by id in `folded`) its groups.
    public static func rows(_ shell: ShellViewModel, section: String, folded: Set<String>) -> [SidebarItem] {
        shell.tabs.filter { $0.section == section }.flatMap { tab -> [SidebarItem] in
            let open = !folded.contains(tab.id)
            let row = SidebarItem(id: .tab(tab.id), label: tab.label, icon: tab.icon, count: tab.count,
                                  forYou: tab.forYou, open: tab.groups.isEmpty ? nil : open)
            guard open else { return [row] }
            return [row] + tab.groups.map {
                SidebarItem(id: .group($0.to), label: $0.label, icon: nil, count: $0.count, forYou: $0.forYou,
                            open: nil)
            }
        }
    }
}

/// The sidebar's look, after Eyra's Next side panel: bold labels, a grey icon per tab (the
/// selected tab's in primary), a soft grey pill for the selection, counts as round badges
/// (primary when the count waits for the user, grey for a plain count, none at 0), groups
/// indented under their tab, one size smaller.
public enum SidebarLook {
    public enum Badge: Equatable, Sendable {
        /// What waits for the user: primary.
        case forYou(Int)
        /// A plain count: grey.
        case plain(Int)
    }

    /// The badge of a count: none when there is none, or it is 0.
    public static func badge(count: Int?, forYou: Bool) -> Badge? {
        guard let count, count > 0 else { return nil }
        return forYou ? .forYou(count) : .plain(count)
    }

    /// The SF Symbol for a semantic icon name Control sends; nil (no icon) for a name this
    /// app does not know.
    public static func symbol(_ icon: String?) -> String? {
        switch icon {
        case "assigned": "tray"
        case "supervised": "eye"
        case "open": "hand.raised"
        case "scenes": "rectangle.stack"
        case "agents": "person.2"
        case "todos": "checklist"
        case "activity": "clock.arrow.circlepath"
        case "workers": "cpu"
        case "decisions": "arrow.triangle.branch"
        default: nil
        }
    }

    /// The fold's chevron column, the icon's, and the space after the icon.
    static let chevron: CGFloat = 12
    static let icon: CGFloat = 22
    static let iconSpace: CGFloat = 8

    /// How far a row's label starts in from the fold's chevron: past the icon for a tab, by
    /// as much again for a group, so it sits under its tab's label.
    public static func indent(group: Bool) -> CGFloat {
        group ? icon + iconSpace : 0
    }

    /// A tab's label in Prism's `label` (strong); a group's one size smaller, `labelsmall`.
    public static func typography(group: Bool) -> PrismTypography {
        group ? Prism.Typography.labelsmall : Prism.Typography.label
    }

    /// The connection in one word or two, for the sidebar's foot.
    public static func connection(_ mark: StatusViewModel.Mark) -> String {
        switch mark {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .notConnected: "Not connected"
        }
    }

    /// What the foot's state shows on click or hover, one per line: the connection in plain
    /// words (why, what happens next), `extra` (the last notice, the app's update, a boot
    /// failure), then the technical details: the page's position, its last change and hint,
    /// the refresh interval, a contract difference and an `open` that failed.
    public static func details(_ status: StatusViewModel, extra: [String] = []) -> String {
        let words = status.text()
        var lines = [words.prefix(1).uppercased() + words.dropFirst()] + extra
        if let position = status.position { lines.append("position \(position)") }
        if let update = status.lastUpdate { lines.append("\(update.reason.rawValue) \(update.at ?? "")") }
        if let hint = status.lastHint {
            lines.append("last hint \(hint.at ?? "")\(hint.position.map { " @\($0)" } ?? "")")
        }
        lines.append("refresh every \(status.reconcileSeconds.formatted()) s")
        if let warning = status.versionWarning { lines.append(warning) }
        if let failure = status.openFailure { lines.append("\(failure.path) could not be read (\(failure.reason))") }
        return lines.joined(separator: "\n")
    }
}

/// What the sidebar's foot says of the connection: its mark (the short state on the foot)
/// and its details (in the state's popover).
public struct SidebarConnection: Equatable {
    public var mark: StatusViewModel.Mark
    public var details: String

    public init(mark: StatusViewModel.Mark, details: String) {
        self.mark = mark
        self.details = details
    }
}

/// The sidebar: the "Work" and "Browse" sections with their small, muted headings, and,
/// separated at the bottom, the person's name, the environment and the connection. Up and
/// down move the selection through the rows; a tab's chevron folds its groups.
public struct SidebarView: View {
    let work: [SidebarItem]
    let browse: [SidebarItem]
    let selection: SidebarItem.ID?
    let stale: Bool
    let name: String?
    let env: String
    let production: Bool
    let connection: SidebarConnection
    let select: (SidebarItem.ID) -> Void
    let fold: (String, Bool) -> Void

    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: Bool

    public init(work: [SidebarItem], browse: [SidebarItem], selection: SidebarItem.ID?, stale: Bool, name: String?,
                env: String, production: Bool, connection: SidebarConnection,
                select: @escaping (SidebarItem.ID) -> Void, fold: @escaping (String, Bool) -> Void) {
        self.work = work
        self.browse = browse
        self.selection = selection
        self.stale = stale
        self.name = name
        self.env = env
        self.production = production
        self.connection = connection
        self.select = select
        self.fold = fold
    }

    public var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    section("Work", work)
                    section("Browse", browse)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .onChange(of: selection) { _, id in
                if let id { scroller.scrollTo(id) }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.upArrow) { step(-1) }
        .onKeyPress(.downArrow) { step(1) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarFoot(name: name, env: env, production: production, connection: connection)
        }
        .background(PrismDarkGap.sidebarGround(scheme))
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [SidebarItem]) -> some View {
        if !items.isEmpty {
            Text(title)
                .prism(Prism.Typography.caption)
                .foregroundStyle(PrismDarkGap.muted(scheme))
                .padding(.horizontal, 10)
                .padding(.top, 12)
                .padding(.bottom, 4)
            ForEach(items) { item in
                SidebarRow(item: item, selected: item.id == selection, stale: stale,
                           select: {
                               focused = true
                               select(item.id)
                           },
                           fold: { if case .tab(let id) = item.id { fold(id, item.open == false) } })
                    .id(item.id)
            }
        }
    }

    /// Up and down: the row before or after the selected one.
    private func step(_ by: Int) -> KeyPress.Result {
        let ids = (work + browse).map(\.id)
        let at = selection.flatMap { ids.firstIndex(of: $0) }
        let next = at.map { $0 + by } ?? (by < 0 ? ids.indices.last : ids.indices.first)
        if let next, ids.indices.contains(next) { select(ids[next]) }
        return .handled
    }
}

/// One row: a tab's fold chevron (a blank of the same width without groups), its icon and
/// bold label; a group's smaller label, under its tab's. Its badge on the right; the
/// selection is a soft grey pill.
struct SidebarRow: View {
    let item: SidebarItem
    let selected: Bool
    let stale: Bool
    let select: () -> Void
    let fold: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: fold) {
                Image(systemName: "chevron.right")
                    .prism(Prism.Typography.caption.emphasis(.strong))
                    .foregroundStyle(PrismDarkGap.sidebarIcon(scheme, selected: false))
                    .rotationEffect(.degrees(item.open == true ? 90 : 0))
                    .frame(width: SidebarLook.chevron)
            }
            .buttonStyle(.plain)
            .opacity(item.open == nil ? 0 : 1)
            .disabled(item.open == nil)
            .padding(.trailing, 4)
            if item.isGroup {
                Color.clear.frame(width: SidebarLook.indent(group: true), height: 1)
            } else {
                // Without a known icon the column stays (a blank), so the labels line up:
                // an empty Group takes no room at all, its frame with it.
                ZStack {
                    if let symbol = SidebarLook.symbol(item.icon) {
                        Image(systemName: symbol)
                            .prism(Prism.Typography.label)
                            .foregroundStyle(PrismDarkGap.sidebarIcon(scheme, selected: selected))
                    }
                    Color.clear.frame(width: SidebarLook.icon, height: 1)
                }
                .frame(width: SidebarLook.icon)
                .padding(.trailing, SidebarLook.iconSpace)
            }
            Text(item.label)
                .prism(SidebarLook.typography(group: item.isGroup))
                .foregroundStyle(PrismDarkGap.text(scheme))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if let badge = SidebarLook.badge(count: item.count, forYou: item.forYou) {
                SidebarBadge(badge: badge)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, item.isGroup ? 6 : 9)
        .background(PrismDarkGap.sidebarPill(scheme, selected: selected, hovering: hovering),
                    in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .opacity(stale ? 0.6 : 1)
    }
}

/// A count as a small round badge: primary under white when it waits for the user, grey
/// otherwise.
struct SidebarBadge: View {
    let badge: SidebarLook.Badge
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let (count, forYou) = switch badge {
        case .forYou(let count): (count, true)
        case .plain(let count): (count, false)
        }
        Text("\(count)")
            .prism(Prism.Typography.captionsmall.emphasis(.strong))
            .monospacedDigit()
            .foregroundStyle(forYou ? Prism.Colors.white : PrismDarkGap.text(scheme))
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 22)
            .background(forYou ? Prism.Colors.primary : PrismDarkGap.plainBadge(scheme), in: Capsule())
    }
}

/// The sidebar's foot, below a line, the shell's one place for its state, never wrapping:
/// the person's name; then on one line the environment (production as a small danger tag),
/// the connection's dot (not connected: a red warning sign) and its short state. The plain words (why, what happens next) and
/// the technical details are in a popover on the state (click; hover shows them too).
struct SidebarFoot: View {
    let name: String?
    let env: String
    let production: Bool
    let connection: SidebarConnection
    @State private var showsDetails = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let name {
                Text(name)
                    .prism(Prism.Typography.labelsmall)
                    .foregroundStyle(PrismDarkGap.text(scheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            HStack(alignment: .center, spacing: 6) {
                if production {
                    PrismDarkGap.smallTag(env, tone: .danger)
                } else {
                    Text(env)
                }
                Text("·")
                Button { showsDetails.toggle() } label: {
                    HStack(spacing: 5) {
                        // Not connected: a clearly visible warning, as Mail's; else a quiet dot.
                        if connection.mark == .notConnected {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Prism.Colors.error)
                        } else {
                            Circle().fill(dot).frame(width: 7, height: 7)
                        }
                        Text(SidebarLook.connection(connection.mark))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(connection.details)
                .popover(isPresented: $showsDetails, arrowEdge: .top) {
                    Text(connection.details)
                        .prism(Prism.Typography.caption)
                        .foregroundStyle(PrismDarkGap.text(scheme))
                        .textSelection(.enabled)
                        .lineLimit(nil)
                        .frame(width: 280, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(Prism.Spacing.px10)
                }
            }
            .prism(Prism.Typography.caption)
            .foregroundStyle(PrismDarkGap.muted(scheme))
            .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Divider() }
        .background(PrismDarkGap.sidebarGround(scheme))
    }

    private var dot: Color {
        switch connection.mark {
        case .connected: Prism.Colors.success
        case .connecting: Prism.Colors.warning
        case .notConnected: Prism.Colors.error
        }
    }
}

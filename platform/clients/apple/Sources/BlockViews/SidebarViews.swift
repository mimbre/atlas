import ControlSession
import Prism
import SwiftUI

/// One top-level tab of the sidebar, in the order boot sent it.
public struct SidebarItem: Identifiable, Equatable, Sendable {
    public enum ID: Hashable, Sendable {
        case tab(String)
    }

    public let id: ID
    public let label: String
    /// The semantic icon name Control sent.
    public let icon: String?
    public let count: Int?
    /// Whether the count is what waits for the user.
    public let forYou: Bool

    /// The tabs of one section ("work" or "browse").
    public static func rows(_ shell: ShellViewModel, section: String) -> [SidebarItem] {
        shell.tabs.filter { $0.section == section }.map { tab in
            SidebarItem(id: .tab(tab.id), label: tab.label, icon: tab.icon, count: tab.count,
                        forYou: tab.forYou)
        }
    }
}

/// The sidebar's look: bold labels, an icon per tab, a soft selection and count badges.
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

    /// The SF Symbol for a semantic icon name Control sends: a page's (assigned, supervised,
    /// open, workers) or a kind's, the one the model names for it, the same on its tab, its
    /// group, its rows and its page's header; nil (no icon) for a name this app does not know.
    public static func symbol(_ icon: String?) -> String? {
        switch icon {
        case "assigned": "tray"
        case "supervised": "eye"
        case "open": "hand.raised"
        case "workers": "cpu"
        case "scales": "checkmark.seal"
        case "checklist": "checklist"
        case "frame": "rectangle.stack"
        case "route": "list.bullet.rectangle"
        case "ticket": "smallcircle.filled.circle"
        case "sparkles": "sparkles"
        case "gears": "gearshape.2"
        case "figure": "person"
        case "hammer": "hammer"
        case "merge": "arrow.triangle.pull"
        case "magnifier": "text.magnifyingglass"
        case "flask": "testtube.2"
        case "upgrade": "arrow.up.circle"
        case "history": "clock.arrow.circlepath"
        default: nil
        }
    }

    static let icon: CGFloat = 22
    static let iconSpace: CGFloat = 8


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

/// The top-level tabs in Work and Browse, with the connection in the foot.
/// Up and down move the selection through the tabs.
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

    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: Bool

    public init(work: [SidebarItem], browse: [SidebarItem], selection: SidebarItem.ID?, stale: Bool, name: String?,
                env: String, production: Bool, connection: SidebarConnection,
                select: @escaping (SidebarItem.ID) -> Void) {
        self.work = work
        self.browse = browse
        self.selection = selection
        self.stale = stale
        self.name = name
        self.env = env
        self.production = production
        self.connection = connection
        self.select = select
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
            Text(title.uppercased()).tracking(0.6)
                .prism(Prism.Typography.labelsmall)
                .foregroundStyle(PrismDarkGap.muted(scheme))
                .padding(.horizontal, 10)
                .padding(.top, 18)
                .padding(.bottom, 4)
            ForEach(items) { item in
                SidebarRow(item: item, selected: item.id == selection, stale: stale, select: {
                    focused = true
                    select(item.id)
                })
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

/// One tab with its icon, label and count.
struct SidebarRow: View {
    let item: SidebarItem
    let selected: Bool
    let stale: Bool
    let select: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
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
            Text(item.label)
                .prism(Prism.Typography.label)
                .foregroundStyle(PrismDarkGap.text(scheme))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if let badge = SidebarLook.badge(count: item.count, forYou: item.forYou) {
                SidebarBadge(badge: badge)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 9)
        .background(PrismDarkGap.sidebarPill(scheme, selected: selected, hovering: hovering),
                    in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction { select() }
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

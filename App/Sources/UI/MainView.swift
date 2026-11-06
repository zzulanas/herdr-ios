import SwiftUI
import HerdrKit

enum Route: Hashable {
    case space(String)
    case terminal(String)
}

/// Per-window navigation state. iPhone pushes onto `path`; iPad/landscape
/// selects in the sidebar and shows a detail stack.
@MainActor @Observable
final class Navigator {
    var path: [Route] = []
    var selection: Route?
    var split = false
    var showNewAgent = false
    var newAgentSpace: String?
    var showSettings = false
    var modSheet: ModInfo?

    func open(_ r: Route) {
        if split {
            selection = r
            path = []
        } else {
            path.append(r)
        }
    }

    /// Open a freshly created terminal: under its space on phone so Back goes somewhere sensible.
    func openNew(terminal: String) {
        if split { selection = .terminal(terminal); path = [] } else { path = [.terminal(terminal)] }
    }
}

struct MainView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.horizontalSizeClass) private var hsc
    @State private var nav = Navigator()

    var body: some View {
        @Bindable var nav = nav
        Group {
            if hsc == .regular {
                SplitMain()
            } else {
                NavigationStack(path: $nav.path) {
                    HomeView()
                        .navigationDestination(for: Route.self) { RouteView(route: $0) }
                }
            }
        }
        .environment(nav)
        .onChange(of: hsc, initial: true) { _, v in
            nav.split = v == .regular
            // Carry the visible screen across a size-class change.
            if nav.split, let last = nav.path.last { nav.selection = last; nav.path = [] }
            else if !nav.split, let sel = nav.selection, nav.path.isEmpty { nav.path = [sel] }
        }
        .sheet(isPresented: $nav.showNewAgent) {
            NewAgentSheet(initialSpace: nav.newAgentSpace) { addr in
                nav.openNew(terminal: addr)
            }
        }
        .sheet(isPresented: $nav.showSettings) { SettingsView() }
        .sheet(item: $nav.modSheet) { mod in ModFullSheet(mod: mod) }
        .onChange(of: store.pendingOpen, initial: true) { _, a in
            guard let a else { return }
            store.pendingOpen = nil
            nav.showNewAgent = false; nav.showSettings = false; nav.modSheet = nil
            if nav.split ? nav.selection != .terminal(a) : nav.path.last != .terminal(a) { nav.open(.terminal(a)) }
        }
        #if DEBUG
        .task(id: store.spaces.isEmpty) { debugOpen() }
        #endif
    }

    #if DEBUG
    /// Launch-time navigation for verification without taps:
    /// HERDR_DEBUG_OPEN=t1 | <space id> | <space name> | settings | new
    /// HERDR_DEBUG_OPEN_MOD=<mod> (full sheet of a mod)
    @State private var debugOpened = false
    private func debugOpen() {
        guard !debugOpened, !store.spaces.isEmpty else { return }
        let env = ProcessInfo.processInfo.environment
        debugOpened = true
        if let target = env["HERDR_DEBUG_OPEN"], !target.isEmpty {
            if target == "settings" { nav.showSettings = true }
            else if target == "new" { nav.showNewAgent = true }
            else if store.terminals[target] != nil { nav.open(.terminal(target)) }
            else if let s = store.spaces.first(where: { $0.id == target || store.spaceName($0) == target }) { nav.open(.space(s.id)) }
        }
        if let m = env["HERDR_DEBUG_OPEN_MOD"], let mod = ModCatalog.all().first(where: { $0.name == m }) {
            nav.modSheet = mod
        }
    }
    #endif
}

struct RouteView: View {
    var route: Route
    var body: some View {
        switch route {
        case .space(let id): SpaceView(spaceID: id)
        case .terminal(let a): AgentScreen(address: a)
        }
    }
}

// MARK: iPad / landscape

private struct SplitMain: View {
    @Environment(Navigator.self) private var nav
    @State private var visibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var nav = nav
        NavigationSplitView(columnVisibility: $visibility) {
            HomeView(sidebar: true)
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
        } detail: {
            NavigationStack(path: $nav.path) {
                Group {
                    if let sel = nav.selection {
                        RouteView(route: sel).id(sel)
                    } else {
                        EmptyDetail()
                    }
                }
                .navigationDestination(for: Route.self) { RouteView(route: $0) }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

private struct EmptyDetail: View {
    @Environment(Navigator.self) private var nav
    var body: some View {
        VStack(spacing: 14) {
            Image("HerdrMark").resizable().frame(width: 52, height: 52).clipShape(.rect(cornerRadius: 12)).opacity(0.9)
            Text("Pick an agent or a space").font(HF.ui(17, .medium)).foregroundStyle(HC.muted)
            Button { nav.showNewAgent = true } label: { Label("New agent", systemImage: "plus") }
                .buttonStyle(.glass)
                .font(HF.ui(15, .medium))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HC.canvas)
    }
}

// MARK: Home

struct HomeView: View {
    @Environment(AppStore.self) private var store
    @Environment(Navigator.self) private var nav
    var sidebar = false

    var body: some View {
        // One pass over the store's precomputed rows; grouping is O(n).
        let model = HomeModel(store: store)
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ConnectionBanner()
                if model.isEmpty {
                    EmptyHome()
                }
                ForEach(model.sections) { section in
                    SectionLabel(title: section.title, count: section.rows.count, tint: section.tint)
                    CardList(items: section.rows, insetSeparator: 42) { item in
                        Button { nav.open(.terminal(item.row.address)) } label: {
                            AgentRowView(row: item.row, indent: item.isChild)
                        }
                        .buttonStyle(RowButtonStyle(selected: nav.selection == .terminal(item.row.address)))
                        .contextMenu { AgentMenu(address: item.row.address) }
                    }
                }
                if !model.spaces.isEmpty {
                    SectionLabel(title: "Spaces", count: model.spaces.count)
                    CardList(items: model.spaces, insetSeparator: 46) { s in
                        Button { nav.open(.space(s.id)) } label: { SpaceRowView(item: s) }
                            .buttonStyle(RowButtonStyle(selected: nav.selection == .space(s.id)))
                    }
                }
                if !model.others.isEmpty {
                    SectionLabel(title: "Other terminals", count: model.others.count)
                    CardList(items: model.others, insetSeparator: 42) { t in
                        Button { nav.open(.terminal(t.address)) } label: { TerminalRowView(record: t) }
                            .buttonStyle(RowButtonStyle(selected: nav.selection == .terminal(t.address)))
                    }
                }
                ModCardsSection().id("mods")
                Color.clear.frame(height: 90)
            }
            .padding(.horizontal, 16)
        }
        #if DEBUG
        .task(id: model.spaces.count) {
            // HERDR_DEBUG_SCROLL=mods scrolls home to the mod cards (screenshots).
            guard ProcessInfo.processInfo.environment["HERDR_DEBUG_SCROLL"] == "mods", !model.spaces.isEmpty else { return }
            try? await Task.sleep(for: .seconds(1))
            proxy.scrollTo("mods", anchor: .top)
        }
        #endif
        }
        .scrollIndicators(.hidden)
        .background(sidebar ? HC.chrome : HC.canvas)
        .refreshable { await store.refresh() }
        .navigationTitle(store.machineTitle)
        .toolbarTitleDisplayMode(sidebar ? .inline : .large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { nav.showSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
        }
        .safeAreaInset(edge: .bottom) { HomeBottomBar(model: model) }
    }
}

/// Precomputed, cheap view model for the home list. Built once per render
/// from the store's derived functions; rows are plain values.
struct HomeModel {
    struct Item: Identifiable { var id: String { row.address }; var row: AgentRow; var isChild: Bool }
    struct Section: Identifiable { var id: String { title }; var title: String; var tint: Color?; var rows: [Item] }
    struct SpaceItem: Identifiable, Hashable {
        var id: String; var name: String; var colorKey: String; var tabs: Int; var agents: Int
        var attention: Attention; var folder: String; var program: String?
    }

    var sections: [Section] = []
    var spaces: [SpaceItem] = []
    var others: [TerminalRecord] = []
    var blocked = 0
    var agents = 0
    var isEmpty: Bool { sections.isEmpty && spaces.isEmpty && others.isEmpty }

    @MainActor init(store: AppStore) {
        let rows = store.agentRows()
        agents = rows.count
        // Nest sub-agents under their parent (when the parent is listed).
        let present = Set(rows.map(\.address))
        var children: [String: [AgentRow]] = [:]
        for r in rows { if let p = r.parent, present.contains(p) { children[p, default: []].append(r) } }
        let groups: [(Attention, String, Color?)] = [(.blocked, "Needs you", HC.blocked), (.working, "Working", nil),
                                                     (.done, "Done", nil), (.idle, "Idle", nil)]
        for (att, title, tint) in groups {
            var items: [Item] = []
            for r in rows where (r.attention == att || (att == .idle && r.attention == .none)) {
                if let p = r.parent, present.contains(p) { continue }
                items.append(Item(row: r, isChild: false))
                for c in children[r.address] ?? [] { items.append(Item(row: c, isChild: true)) }
            }
            if att == .blocked { blocked = items.count }
            if !items.isEmpty { sections.append(Section(title: title, tint: tint, rows: items)) }
        }
        var agentsBySpace: [String: Int] = [:]
        for r in rows { if let s = r.spaceID { agentsBySpace[s, default: 0] += 1 } }
        spaces = store.spaces.map { s in
            let name = store.spaceName(s)
            let firstTerminal = s.tabs.lazy.flatMap(\.panes).compactMap(\.terminal).first
            return SpaceItem(id: s.id, name: name.isEmpty ? "~" : name, colorKey: SpaceBadge.colorKey(for: s.id),
                             tabs: s.tabs.count, agents: agentsBySpace[s.id] ?? 0,
                             attention: store.attention(ofSpace: s.id),
                             folder: store.tildePath(s.folder), program: firstTerminal.flatMap { store.programKey(of: $0) })
        }
        others = store.otherTerminals()
    }
}

struct RowButtonStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if selected || configuration.isPressed {
                    RoundedRectangle(cornerRadius: HM.rowRadius).fill(configuration.isPressed ? HC.hover : HC.selected)
                        .padding(.horizontal, -8).padding(.vertical, 2)
                }
            }
    }
}

struct SpaceRowView: View {
    var item: HomeModel.SpaceItem
    var body: some View {
        HStack(spacing: 12) {
            SpaceBadge(name: item.name, colorKey: item.colorKey)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(HF.ui(15.5, .medium)).foregroundStyle(HC.fg).lineLimit(1)
                Text(subtitle).font(HF.ui(12.5, relativeTo: .caption)).foregroundStyle(HC.dim).lineLimit(1)
            }
            Spacer(minLength: 6)
            StatusMark(attention: item.attention, compact: true)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(HC.dim)
        }
        .frame(minHeight: 52)
        .contentShape(.rect)
    }
    private var subtitle: String {
        var parts: [String] = []
        if !item.folder.isEmpty, item.folder != item.name { parts.append(item.folder) }
        if item.tabs > 0 { parts.append(item.tabs == 1 ? "1 tab" : "\(item.tabs) tabs") }
        if item.agents > 0 { parts.append(item.agents == 1 ? "1 agent" : "\(item.agents) agents") }
        if item.tabs == 0 { parts.append("No tabs") }
        return parts.joined(separator: " · ")
    }
}

struct TerminalRowView: View {
    @Environment(AppStore.self) private var store
    var record: TerminalRecord
    var body: some View {
        HStack(spacing: 10) {
            ProgramIcon(program: store.programKey(of: record.address), size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.displayName(of: record.address)).font(HF.ui(15.5, .medium)).foregroundStyle(HC.fg).lineLimit(1)
                Text(store.tildePath(record.cwd)).font(HF.ui(12.5, relativeTo: .caption)).foregroundStyle(HC.dim).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(record.address).font(HF.mono(11)).foregroundStyle(HC.dim)
        }
        .frame(minHeight: 50)
        .contentShape(.rect)
    }
}

struct AgentMenu: View {
    @Environment(AppStore.self) private var store
    var address: String
    var body: some View {
        Button("Interrupt", systemImage: "stop.circle", role: .destructive) { Task { try? await store.interrupt(address) } }
        Button("Copy address", systemImage: "doc.on.doc") { UIPasteboard.general.string = address }
    }
}

private struct EmptyHome: View {
    @Environment(AppStore.self) private var store
    @Environment(Navigator.self) private var nav
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack").font(.system(size: 34, weight: .light)).foregroundStyle(HC.dim)
            Text(store.phase == .connected ? "No agents running" : "Waiting for \(store.machineTitle)")
                .font(HF.ui(16, .medium)).foregroundStyle(HC.muted)
            if store.phase == .connected {
                Button { nav.showNewAgent = true } label: { Label("Start an agent", systemImage: "plus") }
                    .buttonStyle(.glass).font(HF.ui(15, .medium))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

/// Shown above the lists while the connection isn't live.
struct ConnectionBanner: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        switch store.phase {
        case .connected:
            EmptyView()
        case .connecting(let step):
            HStack(spacing: 10) {
                Spinner(color: HC.working, size: 13)
                Text(step.isEmpty ? "Reconnecting…" : "\(step)…").font(HF.ui(14, .medium)).foregroundStyle(HC.fg)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .herdrCard()
            .padding(.top, 8)
        case .failed(let msg):
            failed(msg)
        case .idle:
            failed("Disconnected")
        }
    }

    private func failed(_ msg: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.horizontal.circle").foregroundStyle(HC.blocked)
            Text(msg).font(HF.ui(14, .medium)).foregroundStyle(HC.fg).lineLimit(2)
            Spacer()
            Button("Retry") { store.reconnect() }.buttonStyle(.glass).font(HF.ui(14, .semibold))
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
        .herdrCard()
        .padding(.top, 8)
    }
}

/// Floating glass bar: machine status on the left, New agent on the right.
private struct HomeBottomBar: View {
    @Environment(AppStore.self) private var store
    @Environment(Navigator.self) private var nav
    var model: HomeModel
    @Namespace private var ns

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Button { nav.showSettings = true } label: {
                    // Large text: drop the icon, then the name, then the agent count;
                    // "needs you" is the part worth keeping.
                    ViewThatFits(in: .horizontal) {
                        status(icon: true, name: true, count: true)
                        status(icon: false, name: true, count: true)
                        status(icon: false, name: false, count: true)
                        status(icon: false, name: false, count: model.blocked == 0)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                }
                .accessibilityLabel("\(store.machineTitle), \(summary)\(model.blocked > 0 ? ", \(model.blocked) need\(model.blocked == 1 ? "s" : "") you" : "")")
                .buttonStyle(.plain)
                .contentShape(.capsule)
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEffectID("status", in: ns)

                Spacer(minLength: 0)

                Button { nav.newAgentSpace = nil; nav.showNewAgent = true } label: {
                    Image(systemName: "plus").font(.system(size: 20, weight: .semibold)).frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
                .foregroundStyle(HC.accentFg)
                .contentShape(.circle)
                .glassEffect(.regular.tint(HC.accent).interactive(), in: .circle)
                .glassEffectID("new", in: ns)
                .accessibilityLabel("New agent")
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private var summary: String {
        model.agents == 1 ? "1 agent" : "\(model.agents) agents"
    }

    private func status(icon: Bool, name: Bool, count: Bool) -> some View {
        HStack(spacing: 8) {
            ConnectionDot(phase: store.phase)
            if icon { Image(systemName: "server.rack").font(.system(size: 12, weight: .medium)).foregroundStyle(HC.muted) }
            if name { Text(store.machineTitle).font(HF.ui(14.5, .semibold)).foregroundStyle(HC.fg).lineLimit(1) }
            if count { Text(summary).font(HF.ui(13)).foregroundStyle(HC.muted).lineLimit(1) }
            if model.blocked > 0 {
                Text("\(count || name ? "· " : "")\(model.blocked) need\(model.blocked == 1 ? "s" : "") you")
                    .font(HF.ui(13, .medium)).foregroundStyle(HC.blocked).lineLimit(1)
            }
        }
        .fixedSize()
    }
}

// MARK: Mods

struct ModCardsSection: View {
    @Environment(Navigator.self) private var nav
    // Demo mode (screenshots) shows no mods: they'd read the builder's real data.
    private let mods = AppStore.isDemoMode ? [] : ModCatalog.all()

    var body: some View {
        if !mods.isEmpty {
            SectionLabel(title: "Mods", count: mods.count)
            VStack(spacing: 12) {
                ForEach(mods) { mod in
                    // The mod draws its own header (title, fold, expand ⤢); long-press
                    // the card for the full view too.
                    ModPanelView(mod: mod.name)
                        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 300, alignment: .top)
                        .clipShape(.rect(cornerRadius: HM.cardRadius))
                        .contextMenu {
                            Button("Open \(mod.title)", systemImage: "arrow.up.left.and.arrow.down.right") { nav.modSheet = mod }
                        }
                    .herdrCard()
                }
            }
        }
    }
}

struct ModFullSheet: View {
    var mod: ModInfo
    var body: some View { ModSheetView(mod: mod.name) }
}

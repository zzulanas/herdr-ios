import SwiftUI
import HerdrKit

/// One space: a glass chip bar of tabs, then the selected tab's panes.
/// Phone: one pane at a time, paged. iPad: a grid of pane cards.
struct SpaceView: View {
    @Environment(AppStore.self) private var store
    @Environment(Navigator.self) private var nav
    @Environment(\.horizontalSizeClass) private var hsc
    var spaceID: String
    @State private var paneIndex = 0

    private var space: SpaceRef? { store.spaces.first { $0.id == spaceID } }

    var body: some View {
        Group {
            if let space {
                content(space)
            } else {
                ContentUnavailableView("Space closed", systemImage: "square.dashed",
                                       description: Text("This space is no longer in the layout."))
            }
        }
        .background(HC.canvas)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func selectedTab(_ space: SpaceRef) -> TabRef? {
        let id = store.selectedTabBySpace[space.id]
        return space.tabs.first { $0.id == id } ?? space.tabs.first
    }

    @ViewBuilder private func content(_ space: SpaceRef) -> some View {
        let name = store.spaceName(space)
        let tab = selectedTab(space)
        VStack(spacing: 0) {
            TabChipBar(space: space, selected: tab?.id) { id in
                withAnimation(.smooth(duration: 0.25)) {
                    store.selectedTabBySpace[space.id] = id
                    paneIndex = 0
                }
            }
            if let tab {
                if tab.panes.isEmpty {
                    ContentUnavailableView("Empty tab", systemImage: "rectangle.dashed")
                } else if hsc == .regular {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 14)], spacing: 14) {
                            ForEach(tab.panes) { pane in
                                PaneCard(pane: pane, spaceName: name).frame(height: 360)
                            }
                        }
                        .padding(16)
                    }
                } else {
                    TabView(selection: $paneIndex) {
                        ForEach(Array(tab.panes.enumerated()), id: \.element.id) { i, pane in
                            PaneCard(pane: pane, spaceName: name)
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                                .padding(.bottom, tab.panes.count > 1 ? 44 : 16)
                                .tag(i)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: tab.panes.count > 1 ? .always : .never))
                    .indexViewStyle(.page(backgroundDisplayMode: .interactive))
                    .id(tab.id)
                }
            } else {
                ContentUnavailableView {
                    Label("No tabs", systemImage: "rectangle.stack")
                } description: {
                    Text("Start an agent or a shell here.")
                } actions: {
                    Button("New agent") { nav.newAgentSpace = space.id; nav.showNewAgent = true }
                        .buttonStyle(.glassProminent)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    SpaceBadge(name: name.isEmpty ? "~" : name, colorKey: SpaceBadge.colorKey(for: space.id), size: 20)
                    Text(name.isEmpty ? "~" : name).font(HF.ui(16, .semibold)).foregroundStyle(HC.fg).lineLimit(1)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { nav.newAgentSpace = space.id; nav.showNewAgent = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New agent in this space")
            }
        }
        .onAppear { store.selectedSpaceID = space.id }
    }
}

/// Horizontally scrolling glass chips, one per tab, tinted by status.
struct TabChipBar: View {
    @Environment(AppStore.self) private var store
    var space: SpaceRef
    var selected: String?
    var onSelect: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(Array(space.tabs.enumerated()), id: \.element.id) { i, tab in
                            chip(tab, index: i).id(tab.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
            .scrollIndicators(.hidden)
            .onAppear { if let selected { proxy.scrollTo(selected, anchor: .center) } }
            .onChange(of: selected) { _, s in withAnimation { proxy.scrollTo(s, anchor: .center) } }
        }
    }

    private func chip(_ tab: TabRef, index: Int) -> some View {
        let att = store.attention(ofTab: tab.id)
        let isSel = tab.id == selected
        let firstTerminal = tab.panes.lazy.compactMap(\.terminal).first
        return Button { onSelect(tab.id) } label: {
            HStack(spacing: 7) {
                ProgramIcon(program: firstTerminal.flatMap { store.programKey(of: $0) }, size: 14)
                Text(store.tabName(tab, index: index))
                    .font(HF.ui(14, isSel ? .semibold : .medium))
                    .foregroundStyle(isSel ? HC.fg : HC.muted)
                    .lineLimit(1)
                    .frame(maxWidth: 170)
                StatusMark(attention: att, compact: true)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
        }
        .buttonStyle(.plain)
        .contentShape(.rect(cornerRadius: HM.chipRadius))
        .glassEffect(glass(att, selected: isSel), in: .rect(cornerRadius: HM.chipRadius))
    }

    private func glass(_ a: Attention, selected: Bool) -> Glass {
        let base: Glass = .regular.interactive()
        switch a {
        case .blocked: return base.tint(HC.blocked.opacity(selected ? 0.35 : 0.2))
        case .working: return base.tint(HC.working.opacity(selected ? 0.28 : 0.14))
        case .done: return base.tint(HC.done.opacity(selected ? 0.3 : 0.16))
        default: return selected ? base.tint(HC.selected) : base
        }
    }
}

/// One pane as a crisp card: header + a text preview of the screen. Tap opens the terminal.
struct PaneCard: View {
    @Environment(AppStore.self) private var store
    @Environment(Navigator.self) private var nav
    var pane: PaneRef
    var spaceName: String

    var body: some View {
        VStack(spacing: 0) {
            if let addr = pane.terminal {
                Button { nav.open(.terminal(addr)) } label: {
                    VStack(spacing: 0) {
                        header(addr)
                        Rectangle().fill(HC.border).frame(height: HM.hairline)
                        TerminalPreview(address: addr)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            } else if let mod = pane.mod {
                HStack {
                    Image(systemName: "puzzlepiece.extension").foregroundStyle(HC.muted)
                    Text(mod).font(HF.ui(13.5, .medium)).foregroundStyle(HC.fg)
                    Spacer()
                }
                .padding(.horizontal, 12).frame(height: 38)
                Rectangle().fill(HC.border).frame(height: HM.hairline)
                ModPanelView(mod: mod, props: pane.modProps.object?.mapValues(\.any))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                Spacer()
            }
        }
        .clipShape(.rect(cornerRadius: HM.cardRadius))
        .herdrCard()
    }

    private func header(_ addr: String) -> some View {
        let rec = store.terminals[addr]
        return HStack(spacing: 8) {
            ProgramIcon(program: store.programKey(of: addr), size: 16)
            Text(store.displayName(of: addr)).font(HF.ui(14, .medium)).foregroundStyle(HC.fg).lineLimit(1)
            Text(store.tildePath(rec?.cwd ?? "")).font(HF.ui(12.5)).foregroundStyle(HC.dim).lineLimit(1)
            Spacer(minLength: 4)
            StatusMark(attention: store.attention(of: addr))
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(HC.dim)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }
}

/// Plain-text tail of a terminal (terminal.read), refreshed when its turn/status changes.
struct TerminalPreview: View {
    @Environment(AppStore.self) private var store
    var address: String
    @State private var text: String = ""
    @State private var loaded = false

    var body: some View {
        let rec = store.terminals[address]
        let key = "\(address)|\(rec?.turn ?? 0)|\(rec?.statusWord ?? "")|\(rec?.title ?? "")"
        ZStack(alignment: .bottomLeading) {
            HC.background
            if text.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "terminal").font(.system(size: 22, weight: .light)).foregroundStyle(HC.dim)
                    Text(loaded ? "Tap to open" : "Loading…").font(HF.ui(13)).foregroundStyle(HC.dim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // A cropped screen: one Text per line, never soft-wrapped. In an overlay
                // so lines wider than the card pin to the left edge instead of centring.
                Color.clear
                    .overlay(alignment: .bottomLeading) {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                                Text(line.isEmpty ? " " : String(line)).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                            }
                        }
                        .font(HF.mono(10.5))
                        .foregroundStyle(Color(uiColor: .herdr("terminal_foreground")))
                        .padding(10)
                    }
                    .clipped()
            }
        }
        .task(id: key) {
            let t = (try? await store.read(address, lines: 60)) ?? ""
            text = Self.trim(t)
            loaded = true
        }
    }

    /// Drop trailing blank lines so the preview hugs the bottom.
    private static func trim(_ s: String) -> String {
        var lines = s.split(separator: "\n", omittingEmptySubsequences: false).map { $0.replacingOccurrences(of: "\r", with: "") }
        while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.suffix(60).joined(separator: "\n")
    }
}

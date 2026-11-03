import SwiftUI
import HerdrKit

/// An agent's conversation as native messages, read from its transcript.
/// Holds no terminal attach: nothing here types into or resizes the program
/// except Send, Stop and the blocked card's choices.
struct ChatView: View {
    let address: String
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: ChatModel
    @State private var shownTurns = ChatView.turnPage
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var pinned = true

    /// What changes the bottom of the chat.
    private struct BottomKey: Equatable { var revision: Int; var working: Bool; var blocked: Bool }
    static let turnPage = 30

    init(address: String) {
        self.address = address
        _model = State(initialValue: ChatModel(address: address))
    }

    var body: some View {
        let att = store.attention(of: address)
        let rec = store.terminals[address]
        ScrollView {
            // Not Lazy: a LazyVStack bottom-anchored with tall rows loses its rendered
            // rows when a send changes the composer and the last turn at once (the
            // chat went blank until scrolled). Eager rows can't; `shown` caps the cost.
            VStack(alignment: .leading, spacing: 18) {
                content(working: att == .working)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        // Follow the conversation while you're at the bottom; leave you be when you've scrolled up.
        .scrollPosition($position)
        .onScrollGeometryChange(for: Bool.self) { g in
            g.visibleRect.maxY >= g.contentSize.height - 80
        } action: { _, atBottom in
            pinned = atBottom
        }
        .onChange(of: BottomKey(revision: model.revision, working: att == .working, blocked: att == .blocked)) { _, _ in
            if pinned { position.scrollTo(edge: .bottom) }
        }
        .scrollEdgeEffectStyle(.hard, for: .top)
        .scrollDismissesKeyboard(.interactively)
        .background(HC.canvas)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                if att == .blocked { BlockedCard(address: address) }
                ChatComposer(address: address, working: att == .working)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
        .onAppear { model.start(store: store) }
        .onDisappear { model.stop() }
        .onChange(of: rec?.statusWord) { _, _ in model.nudge() }
        .onChange(of: rec?.turn) { _, _ in model.nudge() }
        .onChange(of: rec?.title) { _, _ in model.nudge() }
        .onChange(of: store.phase) { _, p in if p == .connected { model.nudge() } }
        .onChange(of: scenePhase) { _, p in if p == .active { model.nudge() } }
    }

    @ViewBuilder private func content(working: Bool) -> some View {
        switch model.phase {
        case .loading where model.turns.isEmpty:
            HStack(spacing: 10) { ProgressView(); Text("Reading the conversation…").foregroundStyle(HC.muted) }
                .font(HF.ui(14)).frame(maxWidth: .infinity).padding(.top, 60)
        case .unavailable(let why):
            emptyState("text.bubble", why, hint: "Switch to Terminal to see the screen.")
        case .failed(let why) where model.turns.isEmpty:
            emptyState("exclamationmark.triangle", "Couldn't read the conversation", hint: why)
        default:
            if model.hasEarlier, shownTurns >= model.turns.count {
                Label("Earlier messages are in the terminal's history", systemImage: "clock.arrow.circlepath")
                    .font(HF.ui(12.5)).foregroundStyle(HC.dim).frame(maxWidth: .infinity)
            }
            let shown = model.turns.suffix(shownTurns)
            if shown.count < model.turns.count {
                Button { shownTurns += Self.turnPage } label: {
                    Label("Show \(min(Self.turnPage, model.turns.count - shown.count)) earlier", systemImage: "chevron.up")
                        .font(HF.ui(13, .medium)).foregroundStyle(HC.dim)
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
            ForEach(shown) { turn in
                TurnView(turn: turn, isLast: turn.id == model.turns.last?.id, working: working)
            }
            if working { WorkingRow(since: model.turns.last?.startedAt) }
        }
    }

    private func emptyState(_ symbol: String, _ title: String, hint: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(HC.dim)
            Text(title).font(HF.ui(15, .medium)).foregroundStyle(HC.fg).multilineTextAlignment(.center)
            Text(hint).font(HF.ui(13)).foregroundStyle(HC.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 80).padding(.horizontal, 24)
    }
}

// MARK: Turn

private struct TurnView: View {
    let turn: ChatTurn
    let isLast: Bool
    let working: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if turn.compacted {
                divider("Conversation compacted")
            }
            switch turn.prompt {
            case .user(let s): UserBubble(text: s)
            case .note(let s): chip("bell", s)
            case .command(let s): chip("command", s, mono: true)
            case nil: EmptyView()
            }
            let running = isLast && turn.durationMs == nil && working
            let (folded, final) = split(running: running)
            if !folded.isEmpty {
                if running {
                    steps(folded, running: true)
                } else {
                    FoldRow(expanded: $expanded, durationMs: turn.durationMs,
                            count: folded.reduce(0) { $0 + max($1.toolCount, 1) })
                    if expanded { steps(folded, running: false) }
                }
            }
            if let final { ChatMarkdown(text: final).padding(.top, 2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Finished turns show only their last answer; the work folds above it.
    private func split(running: Bool) -> ([ChatStep], String?) {
        if running { return (turn.steps, nil) }
        if case .text(_, let s)? = turn.steps.last { return (Array(turn.steps.dropLast()), s) }
        return (turn.steps, nil)
    }

    private func steps(_ s: [ChatStep], running: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(s) { step in
                switch step {
                case .text(_, let t): ChatMarkdown(text: t, size: 14.5, color: HC.muted)
                case .tools(_, let calls): ToolGroup(calls: calls, running: running)
                }
            }
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) { HC.border.frame(width: 1.5) }
    }

    private func chip(_ symbol: String, _ text: String, mono: Bool = false) -> some View {
        Label(text, systemImage: symbol)
            .font(mono ? HF.mono(12.5) : HF.ui(12.5))
            .foregroundStyle(HC.muted)
            .lineLimit(2)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(HC.raised, in: .capsule)
            .frame(maxWidth: .infinity)
    }

    private func divider(_ text: String) -> some View {
        HStack(spacing: 10) {
            HC.border.frame(height: 1)
            Text(text).font(HF.ui(11.5, .medium)).foregroundStyle(HC.dim).fixedSize()
            HC.border.frame(height: 1)
        }
    }
}

private struct UserBubble: View {
    let text: String
    var body: some View {
        HStack {
            Spacer(minLength: 48)
            ChatMarkdown.styled(text, size: 15.5)
                .foregroundStyle(HC.fg)
                .textSelection(.enabled)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(HC.accent.opacity(0.16), in: .rect(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(HC.accent.opacity(0.25), lineWidth: 1))
        }
    }
}

private struct FoldRow: View {
    @Binding var expanded: Bool
    let durationMs: Int?
    let count: Int
    var body: some View {
        Button { withAnimation(.smooth(duration: 0.25)) { expanded.toggle() } } label: {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10.5, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text(durationMs.map { "Worked for \(ToolStyle.duration(ms: $0))" } ?? "Worked")
                    .font(HF.ui(13, .medium))
                Text("· \(count) step\(count == 1 ? "" : "s")").font(HF.ui(13))
                Spacer(minLength: 0)
            }
            .foregroundStyle(HC.dim)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(expanded ? "Hides the steps" : "Shows the steps")
    }
}

private struct WorkingRow: View {
    let since: Date?
    var body: some View {
        HStack(spacing: 8) {
            StatusMark(attention: .working, compact: true)
            if let since {
                Text(timerInterval: since...Date.distantFuture, countsDown: false)
                    .font(HF.mono(12.5)).foregroundStyle(HC.working)
                    .monospacedDigit()
                    .fixedSize()
                Text("working").font(HF.ui(13)).foregroundStyle(HC.working)
            } else {
                Text("Working…").font(HF.ui(13)).foregroundStyle(HC.working)
            }
        }
    }
}

// MARK: Tools

private struct ToolGroup: View {
    let calls: [ToolCall]
    let running: Bool
    @State private var showAll = false
    private let visible = 4

    var body: some View {
        let shown = showAll || calls.count <= visible + 1 ? calls[...] : calls.suffix(visible)
        VStack(alignment: .leading, spacing: 2) {
            if shown.count < calls.count {
                Button { withAnimation(.smooth(duration: 0.2)) { showAll = true } } label: {
                    Text("\(calls.count - shown.count) earlier step\(calls.count - shown.count == 1 ? "" : "s")")
                        .font(HF.ui(12.5)).foregroundStyle(HC.dim)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            ForEach(shown) { ToolRow(call: $0, running: running) }
        }
    }
}

private struct ToolRow: View {
    let call: ToolCall
    let running: Bool
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.smooth(duration: 0.2)) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: ToolStyle.symbol(call.name))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(HC.muted)
                        .frame(width: 18)
                    Text(ToolStyle.title(call.name))
                        .font(HF.ui(13.5, .semibold)).foregroundStyle(HC.fg)
                        .lineLimit(1).layoutPriority(1)
                    Text(call.summary)
                        .font(HF.ui(13)).foregroundStyle(HC.muted)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    status
                }
                .frame(minHeight: 28)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(ToolStyle.title(call.name)), \(call.summary)\(call.isError ? ", failed" : "")")
            if open {
                if !call.detail.isEmpty { code(call.detail) }
                if let out = call.output, !out.isEmpty { code(out, error: call.isError) }
            }
        }
    }

    @ViewBuilder private var status: some View {
        if call.output == nil {
            if running { ProgressView().controlSize(.mini) }
        } else if call.isError {
            Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(HC.blocked)
        }
    }

    private func code(_ s: String, error: Bool = false) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Text(s)
                .font(HF.mono(11.5))
                .foregroundStyle(error ? HC.blocked : HC.muted)
                .textSelection(.enabled)
                .padding(10)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: 220, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(HC.background, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(HC.border, lineWidth: 1))
        .padding(.leading, 26)
    }
}

// MARK: Markdown (ModMarkdown + tables)

struct ChatMarkdown: View {
    let text: String
    var size: Double = 15.5
    var color: Color = HC.fg

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.chunks(text).enumerated()), id: \.offset) { _, c in
                switch c {
                case .table(let rows): table(rows)
                case .markdown(let md):
                    ForEach(Array(ModMarkdown.blocks(md).enumerated()), id: \.offset) { _, b in block(b) }
                }
            }
        }
        .font(HF.ui(size))
        .foregroundStyle(color)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func block(_ b: ModMarkdown.Block) -> some View {
        switch b {
        case .heading(let level, let s):
            Self.styled(s, size: size + max(0, 4 - Double(level)) * 1.5, weight: .semibold)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        case .item(let marker, let indent, let s):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(marker).foregroundStyle(HC.dim)
                Self.styled(s, size: size).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .code(let s):
            ScrollView(.horizontal) {
                Text(s).font(HF.mono(size - 3)).padding(10)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HC.background, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(HC.border, lineWidth: 1))
        case .quote(let s):
            Self.styled(s, size: size)
                .foregroundStyle(HC.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { HC.border.frame(width: 2) }
        case .rule:
            HC.border.frame(height: 1).padding(.vertical, 4)
        case .paragraph(let s):
            Self.styled(s, size: size).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func table(_ rows: [[String]]) -> some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Self.styled(cell, size: size - 2, weight: i == 0 ? .semibold : .regular)
                                .foregroundStyle(i == 0 ? HC.fg : HC.muted)
                                .frame(maxWidth: 260, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if i == 0 { HC.border.frame(height: 1).gridCellUnsizedAxes(.horizontal) }
                }
            }
            .padding(12)
        }
        .scrollIndicators(.hidden)
        .background(HC.background, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(HC.border, lineWidth: 1))
    }

    enum Chunk { case markdown(String), table([[String]]) }

    private static var styledCache: [String: Text] = [:]

    /// Inline markdown as Text segments with explicit fonts: the UI face is a
    /// custom variable font, and SwiftUI doesn't map markdown's bold/italic
    /// intents onto it, so each run gets its weight, face and color directly.
    static func styled(_ s: String, size: Double, weight: Font.Weight = .regular) -> Text {
        let key = "\(size)|\(weight)|\(s)"
        if let t = styledCache[key] { return t }
        let a = ModMarkdown.inline(s)
        var out = Text("")
        for run in a.runs {
            let piece = AttributedString(a[run.range])
            let intent = run.inlinePresentationIntent ?? []
            var t: Text
            if intent.contains(.code) {
                t = Text(piece).font(HF.mono(size - 1.5)).foregroundColor(HC.fg)
            } else {
                let f = HF.ui(size, intent.contains(.stronglyEmphasized) ? .semibold : weight, italic: intent.contains(.emphasized))
                t = Text(piece).font(f)
                if run.link != nil { t = t.foregroundColor(HC.accent) }
            }
            out = Text("\(out)\(t)")
        }
        if styledCache.count > 1024 { styledCache.removeAll() }
        styledCache[key] = out
        return out
    }

    /// Pipe tables ("| a | b |" with a "|---|" rule) come out; the rest is markdown.
    static func chunks(_ text: String) -> [Chunk] {
        var out: [Chunk] = []
        var md: [String] = [], tbl: [String] = []
        var inFence = false
        func flushMD() { if !md.isEmpty { out.append(.markdown(md.joined(separator: "\n"))); md = [] } }
        func flushTable() {
            guard !tbl.isEmpty else { return }
            let rows = tbl.filter { !$0.replacingOccurrences(of: " ", with: "").allSatisfy { "|-:".contains($0) } }
                .map { line in
                    line.trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                        .components(separatedBy: "|")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                }
            if tbl.count >= 2 { flushMD(); out.append(.table(rows)) } else { md += tbl }
            tbl = []
        }
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") { inFence.toggle() }
            if !inFence, t.hasPrefix("|"), t.count > 1 { tbl.append(line); continue }
            flushTable()
            md.append(line)
        }
        flushTable(); flushMD()
        return out
    }
}

// MARK: Blocked card

/// The agent's own dialog (permission or question), read from its screen,
/// as buttons. Sends the option's number key; never resends.
private struct BlockedCard: View {
    let address: String
    @Environment(AppStore.self) private var store
    @State private var dialog: Dialog?
    @State private var sent: String?

    struct Dialog: Equatable { var question: String; var options: [(key: String, label: String)]
        static func == (a: Dialog, b: Dialog) -> Bool { a.question == b.question && a.options.map(\.label) == b.options.map(\.label) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(dialog?.question ?? "\(store.displayName(of: address)) needs you", systemImage: "hand.raised.fill")
                .font(HF.ui(14.5, .semibold))
                .foregroundStyle(HC.fg)
                .lineLimit(4)
            if let dialog, !dialog.options.isEmpty {
                ForEach(dialog.options, id: \.key) { o in
                    Button { choose(o.key) } label: {
                        HStack(spacing: 10) {
                            Text(o.key).font(HF.mono(13, .semibold)).foregroundStyle(HC.dim).frame(width: 16)
                            Text(o.label).font(HF.ui(14.5)).foregroundStyle(HC.fg).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            if sent == o.key { ProgressView().controlSize(.small) }
                        }
                        .padding(.horizontal, 12).frame(minHeight: 44)
                        .contentShape(.rect(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .background(HC.raised, in: .rect(cornerRadius: 12))
                    .disabled(sent != nil)
                }
            } else {
                Text("Open Terminal to answer it, or send a reply below.")
                    .font(HF.ui(13)).foregroundStyle(HC.muted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(HC.blocked.opacity(0.12)), in: .rect(cornerRadius: 22))
        .task(id: address) { await watch() }
    }

    private func watch() async {
        while !Task.isCancelled {
            if let text = try? await store.read(address, lines: 0) {
                let d = Self.parse(text)
                if d != dialog { dialog = d; sent = nil }
            }
            try? await Task.sleep(for: .seconds(1.5))
        }
    }

    private func choose(_ key: String) {
        sent = key
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task {
            do { try await store.keys(address, [key]) }
            catch {
                sent = nil
                store.toast("Not sent", body: error.localizedDescription, level: "error")
            }
        }
    }

    /// The bottom-most run of "❯ 1. Yes" / "  2. No" lines, and the text above it.
    static func parse(_ screen: String) -> Dialog? {
        let lines = screen.components(separatedBy: "\n").map { l in
            l.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "│┃|"))
                .trimmingCharacters(in: .whitespaces)
        }
        let rx = /^(?:[❯›>]\s*)?(\d)[.)]\s+(.+)$/
        var options: [(String, String)] = []
        var firstOption = -1
        for i in stride(from: lines.count - 1, through: 0, by: -1) {
            if let m = lines[i].wholeMatch(of: rx) {
                options.insert((String(m.1), String(m.2)), at: 0); firstOption = i
            } else if !options.isEmpty, !lines[i].isEmpty {
                break
            }
        }
        guard !options.isEmpty, firstOption > 0 else { return nil }
        var question: [String] = []
        var i = firstOption - 1
        while i >= 0, question.count < 3 {
            let l = lines[i]
            if l.isEmpty || l.allSatisfy({ "─━═-╭╮╰╯".contains($0) }) { if !question.isEmpty { break } } else { question.insert(l, at: 0) }
            i -= 1
        }
        return Dialog(question: question.joined(separator: " "), options: options)
    }
}

// MARK: Composer

private struct ChatComposer: View {
    let address: String
    let working: Bool
    @Environment(AppStore.self) private var store
    @State private var draft = ""
    @State private var sending = false
    @FocusState private var focused: Bool

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message \(store.displayName(of: address))", text: $draft, axis: .vertical)
                    .font(HF.ui(15.5))
                    .lineLimit(1...6)
                    .focused($focused)
                    .accessibilityIdentifier("composer")
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
                if working && draft.isEmpty {
                    Button(action: stop) {
                        Image(systemName: "stop.fill").font(.system(size: 15, weight: .bold)).frame(width: 46, height: 46)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(HC.blocked)
                    .contentShape(.circle)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityLabel("Stop")
                } else {
                    Button(action: send) {
                        Group {
                            if sending { ProgressView().tint(HC.accentFg) }
                            else { Image(systemName: "arrow.up").font(.system(size: 17, weight: .bold)) }
                        }
                        .frame(width: 46, height: 46)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(HC.accentFg)
                    .contentShape(.circle)
                    .glassEffect(.regular.tint(HC.accent).interactive(), in: .circle)
                    .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send")
                }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .onAppear {
            #if DEBUG
            // UI tests: a ready draft, so Send can be tapped with no keyboard up.
            if let d = ProcessInfo.processInfo.environment["HERDR_DEBUG_DRAFT"], draft.isEmpty { draft = d }
            #endif
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        Task {
            do {
                try await store.send(address, text: text)
                if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                store.toast("Not sent", body: "\(error.localizedDescription). Your text is still in the box.", level: "error")
            }
            sending = false
        }
    }

    /// Claude Code stops its turn on Esc.
    private func stop() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task {
            do { try await store.keys(address, ["esc"]) }
            catch { store.toast("Couldn't stop", body: error.localizedDescription, level: "error") }
        }
    }
}

import SwiftUI
import HerdrKit

// ChatEntry, ChatTurn and the fold live in HerdrKit (Chat.swift), unit-tested there.

/// Reads an agent's Claude Code transcript from the box and folds it into
/// turns. Polls quickly while the agent works, slowly otherwise; never
/// attaches to (or resizes) the terminal.
@MainActor @Observable
final class ChatModel {
    enum Phase: Equatable { case loading, ready, unavailable(String), failed(String) }

    let address: String
    private(set) var phase: Phase = .loading
    private(set) var turns: [ChatTurn] = []
    /// The transcript continues above what was loaded (we only read its tail).
    private(set) var hasEarlier = false
    private(set) var revision = 0
    /// The last read failed after turns were shown: they may be out of date.
    private(set) var stale = false

    private var entries: [ChatEntry] = []
    private var session = ""
    private var offset: Int64 = -1
    private var loop: Task<Void, Never>?
    private var wake: CheckedContinuation<Void, Never>?
    /// Identifies the current pause, so a stale timer can't end a later one.
    private var wakeToken = 0
    /// A nudge arrived while no pause was waiting (mid-load): skip the next pause.
    private var nudged = false
    private weak var store: AppStore?
    #if DEBUG
    @ObservationIgnored fileprivate var demoObserver: NSObjectProtocol?
    #endif

    init(address: String) { self.address = address }

    func start(store: AppStore) {
        self.store = store
        #if DEBUG
        if AppStore.isDemo { if demoObserver == nil { loadDemo() }; return }
        #endif
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.load()
                guard !Task.isCancelled else { return }
                await self.pause()
            }
        }
    }

    func stop() {
        loop?.cancel(); loop = nil
        wake?.resume(); wake = nil
        nudged = false
    }

    /// Something changed (status, turn, title): read now instead of waiting.
    func nudge() {
        if let w = wake { w.resume(); wake = nil } else if loop != nil { nudged = true }
    }

    private func pause() async {
        let busy = store.map { [.working, .blocked].contains($0.attention(of: address)) } ?? false
        let delay: Duration = busy ? .milliseconds(1500) : .seconds(6)
        if nudged { nudged = false; return }
        wakeToken += 1
        let token = wakeToken
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            wake = c
            Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard let self, self.wakeToken == token else { return }
                self.wake?.resume(); self.wake = nil
            }
        }
    }

    private func load() async {
        guard let store, store.phase == .connected, let rec = store.terminals[address] else { return }
        let pid = rec.raw["pid"].int.map(String.init) ?? "0"
        let argv = String(decoding: rec.raw["argv"].encoded(), as: UTF8.self)
        for _ in 0..<4 {   // follow "more" a few times on a big backlog
            do {
                let r = try await store.exec(argv: ["python3", "-c", TranscriptScript.source, pid, argv, session, String(offset)],
                                             cwd: nil, on: nil, timeout: 20, input: nil)
                guard r.code == 0 else {
                    let err = String(decoding: r.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    let why = err.isEmpty ? "Couldn't read the conversation." : String(err.suffix(300))
                    if turns.isEmpty { phase = .failed(why) } else { stale = true }
                    return
                }
                if !apply(r.stdout) { return }
            } catch {
                // Leaving the chat cancels the read: not a failure to show.
                if Task.isCancelled || error is CancellationError { return }
                if turns.isEmpty { phase = .failed(error.localizedDescription) } else { stale = true }
                return
            }
        }
    }

    /// Returns true when the box has more to send right away.
    private func apply(_ data: Data) -> Bool {
        var lines = data.split(separator: UInt8(ascii: "\n"))
        guard !lines.isEmpty, let head = try? JSONValue.parse(Data(lines.removeFirst())) else { return false }
        if let why = head["why"].string {
            phase = .unavailable(why == "no-session"
                ? "No Claude Code conversation found for this terminal yet."
                : "Claude Code's transcript for this session isn't on disk yet.")
            return false
        }
        let fresh = head["fresh"].bool ?? false
        if fresh {
            entries = []
            session = head["session"].string ?? ""
            hasEarlier = (head["start"].int ?? 0) > 0
        }
        offset = Int64(head["next"].double ?? Double(offset))
        var added = false
        for line in lines {
            guard let e = try? JSONValue.parse(Data(line)), let entry = Self.entry(e) else { continue }
            entries.append(entry); added = true
        }
        if fresh || added { rebuild() }
        phase = .ready
        stale = false
        return head["more"].bool ?? false
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    private static func entry(_ e: JSONValue) -> ChatEntry? {
        let t = e["t"].string ?? ""
        let ts = e["ts"].string.flatMap { iso.date(from: $0) }
        switch e["k"].string {
        case "user": return .user(t, ts)
        case "note": return .note(t)
        case "cmd": return .command(t)
        case "compact": return .compact
        case "text": return .text(t)
        case "tool": return .tool(id: e["id"].string ?? "", name: e["name"].string ?? "Tool",
                                  summary: e["sum"].string ?? "", detail: e["detail"].string ?? "", at: ts)
        case "result": return .result(id: e["id"].string ?? "", isError: e["err"].bool ?? false, output: e["out"].string ?? "")
        case "dur": return .duration(ms: e["ms"].int ?? 0)
        default: return nil
        }
    }

    private func rebuild() {
        turns = ChatFold.turns(entries)
        revision += 1
    }
}

// MARK: Display helpers

enum ToolStyle {
    static func symbol(_ name: String) -> String {
        switch name {
        case "Bash", "BashOutput", "KillShell": "terminal"
        case "Read": "doc.text"
        case "Edit", "MultiEdit": "pencil"
        case "Write", "NotebookEdit": "square.and.pencil"
        case "Grep", "Glob", "ToolSearch": "magnifyingglass"
        case "WebSearch", "WebFetch": "globe"
        case "Agent", "Task", "SendMessage": "person.2"
        case "TodoWrite": "checklist"
        case "Skill": "sparkles"
        case "Workflow": "point.3.connected.trianglepath.dotted"
        default: name.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }

    /// "mcp__claude-artifacts__get_artifact" -> "claude-artifacts · get_artifact"
    static func title(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        let parts = name.dropFirst(5).components(separatedBy: "__")
        return parts.count >= 2 ? "\(parts[0]) · \(parts.dropFirst().joined(separator: "__"))" : String(name.dropFirst(5))
    }

    static func duration(ms: Int) -> String {
        let s = ms / 1000
        if s < 60 { return "\(max(s, 1))s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}

#if DEBUG
// A canned conversation for screenshots (HERDR_DEMO=1).
extension ChatModel {
    fileprivate func loadDemo() {
        let now = Date()
        // Older turns first, so the chat is several screens tall like a real one.
        let older: [ChatEntry] = (1...12).flatMap { i -> [ChatEntry] in [
            .user("Earlier request \(i): tidy up module \(i)", now.addingTimeInterval(Double(-4000 + i * 200))),
            .tool(id: "o\(i)", name: "Read", summary: "src/module\(i).ts", detail: "", at: nil),
            .result(id: "o\(i)", isError: false, output: "120 lines"),
            .text("Module \(i) is tidy now.\n\n" + (1...(i % 3 == 0 ? 40 : 6)).map { "- Change \($0): removed dead code and renamed a helper so call sites read better" }.joined(separator: "\n")),
            .duration(ms: 20_000 + i * 1000),
        ] }
        entries = older + [
            .user("Add a global time slider to the analytics dashboard so every chart shares one range", now.addingTimeInterval(-900)),
            .text("I'll start by looking at how the dashboard wires its charts together."),
            .tool(id: "a", name: "Read", summary: "~/projects/webapp/src/dashboard/Dashboard.tsx", detail: "", at: nil),
            .result(id: "a", isError: false, output: "214 lines"),
            .tool(id: "b", name: "Grep", summary: "useTimeRange", detail: "", at: nil),
            .result(id: "b", isError: false, output: "Found 7 files"),
            .tool(id: "c", name: "Edit", summary: "~/projects/webapp/src/dashboard/TimeSlider.tsx", detail: "+ export function TimeSlider({ range, onChange }: TimeSliderProps) {\n+   const [draft, setDraft] = useState(range);", at: nil),
            .result(id: "c", isError: false, output: "Updated with 48 additions and 3 removals"),
            .tool(id: "d", name: "Bash", summary: "Run the dashboard tests", detail: "npm test -- dashboard", at: nil),
            .result(id: "d", isError: false, output: "Tests: 42 passed, 42 total"),
            .text("""
            Every chart on the dashboard now follows **one shared time range**.

            **What changed**
            - A new `TimeSlider` sits in the dashboard header; dragging it updates every chart after a short debounce.
            - Charts read the range from `useTimeRange()` instead of keeping their own.

            | Chart | Before | After |
            |---|---|---|
            | Net flow | own range | shared |
            | Volume | own range | shared |
            | Latency | fixed 24h | shared |

            Tests pass (42/42). Want me to persist the range in the URL so links keep it?
            """),
            .duration(ms: 318_000),
            .user("Yes, put it in the URL", now.addingTimeInterval(-95)),
            .text("Adding a `range` query parameter and reading it on load."),
            .tool(id: "e", name: "Edit", summary: "~/projects/webapp/src/dashboard/useTimeRange.ts", detail: "", at: nil),
            .result(id: "e", isError: false, output: "Updated"),
            .tool(id: "f", name: "Bash", summary: "Type-check the project", detail: "npx tsc --noEmit", at: nil),
        ]
        rebuild()
        phase = .ready
        demoObserver = NotificationCenter.default.addObserver(forName: Self.demoNote, object: nil, queue: .main) { [weak self] n in
            guard let add = n.userInfo?["entries"] as? [ChatEntry], n.userInfo?["address"] as? String == self?.address else { return }
            MainActor.assumeIsolated {
                self?.entries += add
                self?.rebuild()
            }
        }
    }

    static let demoNote = Notification.Name("herdr.demoChat")
    /// Demo mode: append entries to an open Chat, as if the transcript grew.
    static func demoPost(_ address: String, _ entries: [ChatEntry]) {
        NotificationCenter.default.post(name: demoNote, object: nil, userInfo: ["address": address, "entries": entries])
    }
}
#endif

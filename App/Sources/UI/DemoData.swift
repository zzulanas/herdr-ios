import Foundation
import HerdrKit

extension AppStore {
    /// HERDR_DEMO=1 (DEBUG builds only): fake data for screenshots.
    static var isDemoMode: Bool {
        #if DEBUG
        isDemo
        #else
        false
        #endif
    }
}

#if DEBUG

// Demo content for screenshots before the real store lands.
// Launch with HERDR_DEMO=1 (e.g. SIMCTL_CHILD_HERDR_DEMO=1 xcrun simctl launch ...).

extension AppStore {
    static var isDemo: Bool { ProcessInfo.processInfo.environment["HERDR_DEMO"] == "1" }

    func loadDemo() {
        let now = Date().timeIntervalSince1970 * 1000
        func rec(_ addr: String, title: String, cwd: String, space: String?, tab: String?, status: String?,
                 app: String? = "claude-code", argv: [String] = ["claude"], parent: String? = nil,
                 cols: Int = 133, rows: Int = 33, turn: Int = 3, agoMin: Double = 2, name: String? = nil) -> TerminalRecord {
            var labels: [String: JSONValue] = [:]
            if let space { labels["herdr.space"] = .string(space) }
            if let tab { labels["herdr.tab"] = .string(tab) }
            var o: [String: JSONValue] = [
                "address": .string(addr), "state": "live", "title": .string(title), "cwd": .string(cwd),
                "argv": .array(argv.map(JSONValue.string)), "labels": .object(labels),
                "foreground": .object(["cwd": .string(cwd), "argv": .array(argv.map(JSONValue.string))]),
                "cols": .number(Double(cols)), "rows": .number(Double(rows)), "turn": .number(Double(turn)),
                "status_ms": .number(now - agoMin * 60_000), "created_ms": .number(now - 3_600_000), "keep": true,
                "pid": .number(Double(2_400_000 + (Int(addr.dropFirst()) ?? 0))),
            ]
            if let status { o["status"] = .object(["state": .string(status), "app": app.map(JSONValue.string) ?? .null]) }
            if let parent { o["parent"] = .string(parent) }
            if let name { o["name"] = .string(name) }
            return TerminalRecord(raw: .object(o))
        }
        let h = "/home/dev/projects"
        let qd = "sp0e8740efde1fda7f685c0830eccaf96", hi = "sp949e2b1c0f3a4d7e8b6c5a4f3e2d1c0b", df = "sp3c1d9a7e5b2f4c6d8e0a1b3c5d7e9f1a", hm = "sp7a5b3c1d9e8f7a6b5c4d3e2f1a0b9c8d"
        let records = [
            rec("t14", title: "✻ Global time slider for analytics dashboard", cwd: "\(h)/webapp", space: qd, tab: "tbe1c617622ecfb9c2bc24abdb3c5c02e3", status: "working", agoMin: 1),
            rec("t21", title: "Explore chart components", cwd: "\(h)/webapp", space: qd, tab: "tbe1c617622ecfb9c2bc24abdb3c5c02e3", status: "working", parent: "t14", agoMin: 0.5, name: "Explore"),
            rec("t15", title: "Migrate auth to OAuth device flow", cwd: "\(h)/herdr-ios", space: hi, tab: "tb11aa22bb33cc44dd55ee66ff77889900", status: "blocked", agoMin: 4),
            rec("t16", title: "Fix flaky e2e tests in CI", cwd: "\(h)/webapp", space: qd, tab: "tb2b3c4d5e6f708192a3b4c5d6e7f80910", status: "done", app: "codex", argv: ["codex"], agoMin: 12),
            rec("t18", title: "Tidy nvim config", cwd: "/home/dev/dotfiles", space: df, tab: "tb3c4d5e6f708192a3b4c5d6e7f8091021", status: "idle", turn: 9, agoMin: 180),
            rec("t17", title: "dev@my-box: ~/projects/herdr-ios", cwd: "\(h)/herdr-ios", space: hi, tab: "tb4d5e6f708192a3b4c5d6e7f809102132", status: nil, app: nil, argv: ["bash"], cols: 120, rows: 30),
            rec("t20", title: "htop", cwd: "/home/dev", space: nil, tab: nil, status: nil, app: nil, argv: ["htop"], cols: 120, rows: 40),
            rec("t22", title: "docker compose logs -f", cwd: "\(h)/webapp", space: nil, tab: nil, status: nil, app: nil, argv: ["docker", "compose", "logs", "-f"]),
        ]
        terminals = Dictionary(uniqueKeysWithValues: records.map { ($0.address, $0) })

        func pane(_ t: String) -> PaneRef { PaneRef(id: "p" + t, terminal: t, mod: nil, modProps: .null) }
        spaces = [
            SpaceRef(id: qd, name: "", folder: "\(h)/webapp", tabs: [
                TabRef(id: "tbe1c617622ecfb9c2bc24abdb3c5c02e3", name: "Global time slider", panes: [pane("t14"), pane("t21")]),
                TabRef(id: "tb2b3c4d5e6f708192a3b4c5d6e7f80910", name: "Flaky e2e", panes: [pane("t16")]),
            ]),
            SpaceRef(id: hi, name: "herdr-ios", folder: "\(h)/herdr-ios", tabs: [
                TabRef(id: "tb11aa22bb33cc44dd55ee66ff77889900", name: "OAuth", panes: [pane("t15")]),
                TabRef(id: "tb4d5e6f708192a3b4c5d6e7f809102132", name: "", panes: [pane("t17")]),
            ]),
            SpaceRef(id: df, name: "dotfiles", folder: "/home/dev/dotfiles", tabs: [
                TabRef(id: "tb3c4d5e6f708192a3b4c5d6e7f8091021", name: "nvim", panes: [pane("t18")]),
            ]),
            SpaceRef(id: hm, name: "", folder: "", tabs: []),
        ]
        hello = HelloInfo(coreID: "c0ffee42deadbeef", coreName: "my-box", version: "0.1.14", methods: [])
        home = "/home/dev"
        if machines.isEmpty { machines = [MachineConfig(label: "my-box", host: "my-box.local", user: "dev")] }
        activeMachineID = machines.first?.id
        phase = .connected
    }
}

extension AppStore {
    /// Demo send: Chat shows the prompt, the agent works for a few seconds, then answers.
    /// Lets the composer → turns → reply path run in the simulator without a box.
    func demoSend(_ address: String, text: String) async throws {
        try await Task.sleep(for: .milliseconds(300))
        if text.contains("fail-send") { throw DemoError() }
        let now = Date()
        ChatModel.demoPost(address, [.user(text, now)])
        setDemoStatus(address, "working")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            ChatModel.demoPost(address, [.text("Looking into it."),
                                         .tool(id: "demo\(now.timeIntervalSince1970)", name: "Bash", summary: "Run the tests", detail: "", at: now)])
            try? await Task.sleep(for: .seconds(2))
            ChatModel.demoPost(address, [.text("Done. **All 42 tests pass.**\n\nSecond paragraph that should not be spoken."), .duration(ms: 3800)])
            self.setDemoStatus(address, "done")
        }
    }

    struct DemoError: LocalizedError { var errorDescription: String? { "Demo send failed" } }

    func setDemoStatus(_ address: String, _ word: String) {
        guard let r = terminals[address], var o = r.raw.object else { return }
        var st = o["status"]?.object ?? [:]
        st["state"] = .string(word)
        o["status"] = .object(st)
        terminals[address] = TerminalRecord(raw: .object(o))
    }
}

enum DemoData {
    /// A plausible first paint for the terminal screen (VT bytes).
    static func screen(for address: String, record: TerminalRecord?) -> [UInt8] {
        let cols = record?.cols ?? 133
        let e = "\u{1b}["
        let dim = "\(e)38;5;8m", reset = "\(e)0m", orange = "\(e)38;2;217;119;87m", bold = "\(e)1m"
        let green = "\(e)32m", yellow = "\(e)33m", blue = "\(e)34m", cyan = "\(e)36m", red = "\(e)31m"
        var s = "\(e)H\(e)2J"
        func line(_ t: String = "") { s += t + "\r\n" }
        func box(_ title: String, _ body: [String]) {
            let w = min(cols - 2, 120)
            line("\(dim)╭\(String(repeating: "─", count: w))╮\(reset)")
            line("\(dim)│\(reset) \(title)")
            for b in body { line("\(dim)│\(reset) \(b)") }
            line("\(dim)╰\(String(repeating: "─", count: w))╯\(reset)")
        }
        if record?.statusWord == nil {
            let cwd = record?.cwd.replacingOccurrences(of: "/home/dev", with: "~") ?? "~"
            line("\(green)dev@my-box\(reset):\(blue)\(cwd)\(reset)$ git status")
            line("On branch \(bold)main\(reset)")
            line("Your branch is up to date with 'origin/main'.")
            line()
            line("Changes not staged for commit:")
            line("  \(red)modified:   App/Sources/UI/TerminalScreen.swift\(reset)")
            line("  \(red)modified:   App/Sources/UI/Theme.swift\(reset)")
            line()
            line("\(green)dev@my-box\(reset):\(blue)\(cwd)\(reset)$ ls")
            line("\(blue)App\(reset)  \(blue)Packages\(reset)  \(blue)docs\(reset)  project.yml  \(blue)scripts\(reset)  README.md")
            s += "\(green)dev@my-box\(reset):\(blue)\(cwd)\(reset)$ "
            return Array(s.utf8)
        }
        box("\(orange)✻\(reset) \(bold)Welcome to Claude Code\(reset)", ["", "  \(dim)/help for help, /status for your current setup\(reset)", "", "  \(dim)cwd: \(record?.cwd ?? "~")\(reset)"])
        line()
        line("\(dim)>\(reset) Add a global time slider to the analytics dashboard so every chart shares one range")
        line()
        line("\(orange)⏺\(reset) I'll start by looking at how the dashboard wires its charts together.")
        line()
        line("\(orange)⏺\(reset) \(bold)Read\(reset)(src/dashboard/Dashboard.tsx)")
        line("  ⎿  Read \(bold)214\(reset) lines")
        line()
        line("\(orange)⏺\(reset) \(bold)Search\(reset)(pattern: \"useTimeRange\", path: \"src\")")
        line("  ⎿  Found \(bold)7\(reset) files")
        line()
        line("\(orange)⏺\(reset) \(bold)Update\(reset)(src/dashboard/TimeSlider.tsx)")
        line("  ⎿  Updated src/dashboard/TimeSlider.tsx with \(green)48 additions\(reset) and \(red)3 removals\(reset)")
        line("     \(dim)12\(reset) \(green)+ export function TimeSlider({ range, onChange }: TimeSliderProps) {\(reset)")
        line("     \(dim)13\(reset) \(green)+   const [draft, setDraft] = useState(range);\(reset)")
        line("     \(dim)14\(reset) \(green)+   const commit = useDebouncedCallback(onChange, 120);\(reset)")
        line()
        if record?.statusWord == "blocked" {
            box("\(bold)Bash command\(reset)", ["", "  \(cyan)npm run test -- --runInBand\(reset)", "  Run the test suite", "",
                                                "Do you want to proceed?", "\(cyan)❯ 1. Yes\(reset)", "  2. Yes, and don't ask again for npm run test commands", "  3. No, and tell Claude what to do differently \(dim)(esc)\(reset)"])
        } else {
            line("\(yellow)✶\(reset) \(yellow)Wiring the slider into chart queries…\(reset) \(dim)(42s · ↓ 1.9k tokens · esc to interrupt)\(reset)")
            line()
            box("\(dim)>\(reset) ", [])
            line("  \(dim)⏵⏵ accept edits on (shift+tab to cycle)\(reset)")
        }
        return Array(s.utf8)
    }
}
#endif

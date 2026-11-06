import SwiftUI
import UIKit
import HerdrKit

// CONTRACT FILE (owned by the core/store builder). UI and Mods are written
// against these signatures in parallel: implement the bodies, add API freely,
// but do not rename or remove anything here.

/// Where to connect. Persisted in UserDefaults (the key lives in the Keychain).
struct MachineConfig: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var label: String = ""
    var host: String = ""
    var port: Int = 22
    var user: String = ""
    /// Optional password; nil = use the app's Ed25519 key.
    var usePassword: Bool = false
}

enum ConnectionPhase: Equatable {
    case idle
    case connecting(String)            // human step: "Opening SSH", "Saying hello"...
    case connected
    case failed(String)                // message shown to the user, with retry
}

/// One agent row in the agents list.
struct AgentRow: Identifiable, Hashable {
    var id: String { address }
    var address: String
    var label: String                  // SPEC §5 Names: agent row label
    var program: String?               // "claude", "codex", "shell", ...
    var attention: Attention
    var spaceID: String?
    var tabID: String?
    var parent: String?                // sub-agents are nested under parent
    var since: Date?
}

@MainActor
@Observable
final class AppStore {
    // MARK: Connection
    var machines: [MachineConfig] = [] { didSet { persistMachines() } }
    var activeMachineID: UUID? { didSet { persistMachines() } }
    var phase: ConnectionPhase = .idle
    var hello: HelloInfo?
    /// Last stderr from the remote, for the failure screen.
    var diagnostics: String = ""

    // MARK: Live state
    var terminals: [String: TerminalRecord] = [:]
    var doc: LayoutDoc = LayoutDoc(value: .null, version: 0)
    var spaces: [SpaceRef] = []
    /// Remote $HOME, learned at connect (for names).
    var home: String = "~"

    // MARK: Per-device view state
    var selectedSpaceID: String? { didSet { persistView() } }
    var selectedTabBySpace: [String: String] = [:] { didSet { persistView() } }
    /// Terminal screen currently on screen (marks it seen).
    var visibleTerminal: String? { didSet { if let v = visibleTerminal { markSeen(v) } } }

    /// Toasts (in-app notifications; mods' notify() lands here too).
    struct Toast: Identifiable, Equatable {
        var id = UUID(); var title: String; var body: String?; var level: String = "info"
        /// Terminal the toast is about: tapping it opens that terminal.
        var address: String? = nil
            /// Seconds on screen; nil = the level's default.
        var duration: Double? = nil
    }
    var toasts: [Toast] = []
    /// A terminal the UI should open (tapped alert); the navigator clears it.
    var pendingOpen: String?

    /// Attention words and seen state (SPEC §5), persisted per machine.
    private(set) var attentionState = AttentionTracker()

    // MARK: Private connection state
    @ObservationIgnored private var client: HerdrClient?
    @ObservationIgnored private var subscription: EventSubscription?
    /// Bumped per connection attempt; callbacks from older ones are dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask: Task<Void, Never>?
    @ObservationIgnored private var attempt = 0
    /// The person wants to be connected (false after an explicit disconnect).
    @ObservationIgnored private var wantConnected = false
    @ObservationIgnored private var sceneActive = true
    /// Skip alerts until the first snapshot after a connect has been absorbed.
    @ObservationIgnored private var alertsArmed = false
    @ObservationIgnored private var docRefresh: Task<Void, Never>?
    @ObservationIgnored private var docRefreshAgain = false
    @ObservationIgnored private var docGeneration = -1
    @ObservationIgnored private var saveAttentionTask: Task<Void, Never>?
    @ObservationIgnored private var restoringView = false
    @ObservationIgnored private var cachedPublicKey: String?
    private let defaults = UserDefaults.standard

    init() {
        loadMachines()
        loadMachineState()
        #if DEBUG
        if ProcessInfo.processInfo.environment["HERDR_DEBUG_AUTOCONNECT"] == "1", let m = currentMachine() {
            connect(to: m)
        }
        #endif
    }

    // MARK: Lifecycle

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            sceneActive = true
            backgroundTask?.cancel(); backgroundTask = nil
            markSeenVisible()
            guard wantConnected, let m = currentMachine() else { return }
            if client == nil || self.phase != .connected {
                attempt = 0
                startConnect(m, reconnecting: hello != nil)
            } else {
                // The socket may have died while suspended: probe it now rather than waiting for liveness.
                let gen = generation
                Task { [weak self] in
                    do { _ = try await self?.client?.call("server.status", timeout: 4) } catch {
                        guard let self, gen == self.generation, self.wantConnected else { return }
                        self.connectionLost(HerdrError(code: -1, kind: "lost", message: "Lost the core", hint: "no answer after resuming"), gen: gen)
                    }
                }
            }
        case .background:
            sceneActive = false
            saveAttentionNow()
            guard client != nil, backgroundTask == nil else { return }
            // iOS kills sockets in the background: close cleanly after a short grace.
            let bgID = UIApplication.shared.beginBackgroundTask(withName: "herdr.disconnect")
            backgroundTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled, let self, !self.sceneActive { self.dropConnection(phase: .idle) }
                UIApplication.shared.endBackgroundTask(bgID)
            }
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    func connect(to machine: MachineConfig) {
        if !machines.contains(where: { $0.id == machine.id }) { machines.append(machine) }
        if activeMachineID != machine.id {
            dropConnection(phase: .idle)
            flushAttentionSave()
            activeMachineID = machine.id
            clearLiveState()
            loadMachineState()
        }
        wantConnected = true
        attempt = 0
        startConnect(machine, reconnecting: false)
    }

    func reconnect() {
        guard let m = currentMachine() else { return }
        wantConnected = true
        attempt = 0
        startConnect(m, reconnecting: hello != nil)
    }

    func disconnect() {
        wantConnected = false
        dropConnection(phase: .idle)
    }

    func saveMachine(_ m: MachineConfig, password: String?) {
        let old = machines.first { $0.id == m.id }
        if let i = machines.firstIndex(where: { $0.id == m.id }) { machines[i] = m } else { machines.append(m) }
        if let password { KeyStore.setPassword(password, for: m.id) }
        if activeMachineID == nil { activeMachineID = m.id }
        // Changed where/how we connect: reconnect with the new settings.
        guard m.id == activeMachineID, let old, old != m, wantConnected else { return }
        if (old.host, old.port, old.user) != (m.host, m.port, m.user) {
            // Possibly another box: nothing from the old session (terminals, seen
            // state, `hello`, which keeps failed connects retrying) applies to it.
            dropConnection(phase: .idle)
            saveAttentionTask?.cancel(); saveAttentionTask = nil
            defaults.removeObject(forKey: "attention." + m.id.uuidString)
            clearLiveState()
        }
        connect(to: m)
    }

    func removeMachine(_ id: UUID) {
        guard let m = machines.first(where: { $0.id == id }) else { return }
        if id == activeMachineID {
            disconnect()
            saveAttentionTask?.cancel(); saveAttentionTask = nil
            clearLiveState()
            activeMachineID = machines.first { $0.id != id }?.id
            loadMachineState()
        }
        machines.removeAll { $0.id == id }
        KeyStore.setPassword(nil, for: id)
        HostKeys.forget(host: m.host, port: m.port)
        for k in ["attention.", "view.", "home."] { defaults.removeObject(forKey: k + id.uuidString) }
    }

    /// The app's own SSH public key, OpenSSH one-line form ("ssh-ed25519 AAAA... herdr-ios").
    func publicKeyLine() -> String {
        if let k = cachedPublicKey { return k }
        let k = KeyStore.publicKeyLine()
        if !k.isEmpty { cachedPublicKey = k }
        return k
    }

    /// Replace the app key with a pasted OpenSSH ed25519 private key.
    func importPrivateKey(_ text: String) throws {
        try KeyStore.importPrivateKey(text)
        cachedPublicKey = nil
    }

    /// Forget a machine's pinned host key (after a legitimate reinstall).
    func forgetHostKey(_ machine: MachineConfig) { HostKeys.forget(host: machine.host, port: machine.port) }

    /// The pinned host key fingerprint (SHA256:…), nil before the first connect.
    func hostKeyFingerprint(_ machine: MachineConfig) -> String? { HostKeys.pinnedFingerprint(host: machine.host, port: machine.port) }

    /// The last connect failed because the host key changed.
    private(set) var hostKeyMismatch = false

    /// Pull-to-refresh / screens that want a step index rather than text.
    /// 0 SSH, 1 starting core, 2 hello, 3 events + layout; -1 when not connecting.
    private(set) var connectStep = -1

    // MARK: Derived views

    func spaceName(_ s: SpaceRef) -> String {
        let first = s.tabs.lazy.flatMap(\.panes).compactMap(\.terminal).first
        return Names.spaceName(s, firstTerminalCwd: first.flatMap { terminals[$0]?.cwd }.flatMap { $0.isEmpty ? nil : $0 }, home: home)
    }
    func tabName(_ t: TabRef, index: Int) -> String { Names.tabName(t, index: index) }

    func attention(of address: String) -> Attention {
        let a = attentionState.display(address)
        if a != .none || attentionState.agents[address] != nil { return a }
        // Not tracked yet (e.g. records set directly): first sighting counts as seen.
        switch terminals[address]?.statusWord {
        case nil: return .none
        case "working": return .working
        case "blocked", "error": return .blocked
        default: return .idle
        }
    }
    func attention(ofSpace id: String) -> Attention {
        guard let s = spaces.first(where: { $0.id == id }) else { return .none }
        return Attention.rollup(s.tabs.lazy.flatMap(\.panes).compactMap(\.terminal).map { self.attention(of: $0) })
    }
    func attention(ofTab id: String) -> Attention {
        guard let t = spaces.lazy.flatMap(\.tabs).first(where: { $0.id == id }) else { return .none }
        return Attention.rollup(t.panes.compactMap(\.terminal).map { attention(of: $0) })
    }

    /// All agents (status-reporting terminals), sorted blocked > done > working > idle, then recency.
    func agentRows() -> [AgentRow] {
        let places = paneIndex()
        let rows: [AgentRow] = terminals.values.compactMap { t in
            guard t.isLive, t.statusWord != nil else { return nil }
            let place = places[t.address]
            let since = attentionState.agents[t.address].flatMap { $0.since > 0 ? Date(timeIntervalSince1970: Double($0.since) / 1000) : nil }
                ?? t.raw["status_ms"].double.map { Date(timeIntervalSince1970: $0 / 1000) }
            return AgentRow(address: t.address, label: displayName(of: t.address), program: Programs.identify(t).key,
                            attention: attention(of: t.address), spaceID: place?.space ?? t.spaceID, tabID: place?.tab ?? t.tabID,
                            parent: t.parent, since: since)
        }
        return rows.sorted { a, b in
            if a.attention != b.attention { return a.attention > b.attention }
            if a.since != b.since { return (a.since ?? .distantPast) > (b.since ?? .distantPast) }
            return Self.addressOrder(a.address, b.address)
        }
    }

    /// Live terminals in no tab and with no parent.
    func otherTerminals() -> [TerminalRecord] {
        let inTabs = Set(spaces.lazy.flatMap(\.tabs).flatMap(\.panes).compactMap(\.terminal))
        return terminals.values.filter { $0.isLive && $0.parent == nil && !inTabs.contains($0.address) }
            .sorted { Self.addressOrder($0.address, $1.address) }
    }

    func displayName(of address: String) -> String {
        guard let t = terminals[address] else { return address }
        let program = Programs.identify(t)
        if t.parent != nil { return Names.subAgentName(t) }
        if let place = paneIndex()[address], let s = spaces.first(where: { $0.id == place.space }),
           let ti = s.tabs.firstIndex(where: { $0.id == place.tab }) {
            return Names.agentLabel(title: t.title, program: program, tab: s.tabs[ti], tabIndex: ti)
        }
        if let n = t.name, !n.isEmpty { return n }
        return Names.agentLabel(title: t.title, program: program, tab: nil, tabIndex: 0)
    }

    func programName(of address: String) -> String? {
        terminals[address].map { Programs.identify($0).key }
    }

    // MARK: Terminal streams

    /// Attach for the terminal screen. Size policy SPEC §3: mirror the record's size by default.
    func attach(_ address: String, cols: Int?, rows: Int?, observe: Bool) async throws -> TerminalStream {
        let c = try connectedClient()
        let rec = terminals[address]
        var observe = observe
        #if DEBUG
        // Verification against a live machine: watch only, never type or resize.
        if ProcessInfo.processInfo.environment["HERDR_DEBUG_OBSERVE"] == "1" { observe = true }
        #endif
        let dark = UITraitCollection.current.userInterfaceStyle != .light
        let tok = HerdrTheme.tokens(dark: dark)
        var display: JSONValue = [:]
        if let fg = tok["terminal_foreground"] { display["fg"] = .string(fg) }
        if let bg = tok["background"] { display["bg"] = .string(bg) }
        if let cur = tok["cursor"] { display["cursor"] = .string(cur) }
        let stream = try await c.attach(terminal: address, cols: cols ?? rec?.cols ?? 80, rows: rows ?? rec?.rows ?? 24,
                                        history: 2000, display: display.object?.isEmpty == false ? display : nil, observe: observe)
        if !observe { markSeen(address) }
        return stream
    }

    func read(_ address: String, lines: Int) async throws -> String {
        try await connectedClient().read(terminal: address, lines: lines)
    }

    func markSeen(_ address: String) {
        guard sceneActive else { return }
        if attentionState.markSeen([address]) { scheduleAttentionSave() }
    }

    // MARK: Actions (doc writes per SPEC §5 recipes; CAS with one retry)

    /// Starts a terminal (an agent if `argv` is given) in a new tab after the
    /// space's selected one. Returns the terminal address.
    func newTab(inSpace spaceID: String, argv: [String]?, task: String?, name: String?) async throws -> String {
        try await newTab(inSpace: spaceID, argv: argv, task: task, name: name, folder: nil)
    }

    /// As above, starting in `folder` when given (mods' run("tab.new", {folder})).
    func newTab(inSpace spaceID: String, argv: [String]?, task: String?, name: String?, folder: String?) async throws -> String {
        let c = try connectedClient()
        guard let space = spaces.first(where: { $0.id == spaceID }) else { throw HerdrKit.Layout.EditError.notFound("That space") }
        let tabID = HerdrKit.Layout.newID("tb"), paneID = HerdrKit.Layout.newID("p")
        let after = selectedTabBySpace[spaceID].flatMap { id in space.tabs.contains { $0.id == id } ? id : nil } ?? space.tabs.last?.id
        let folder = folder?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let addr = try await run(c, argv: argv, task: task, cwd: folder.isEmpty ? startFolder(for: space) : folder, space: spaceID, tab: tabID)
        try await placeOrKill(addr, c) {
            try await self.writeDoc { v in
                try HerdrKit.Layout.addTab(v, space: spaceID, after: after,
                                  tab: HerdrKit.Layout.tabJSON(id: tabID, name: name ?? "", paneID: paneID, terminal: addr))
            }
        }
        selectedSpaceID = spaceID
        selectedTabBySpace[spaceID] = tabID
        return addr
    }

    /// Starts a terminal in a new space for `folder`. Returns the terminal address.
    func newSpace(folder: String, argv: [String]?, task: String?) async throws -> String {
        try await newSpace(folder: folder, argv: argv, task: task, name: nil, tabName: nil)
    }

    /// As above, naming the space and its first tab (mods' run("space.new", {name, tab})).
    func newSpace(folder: String, argv: [String]?, task: String?, name: String?, tabName: String?) async throws -> String {
        let c = try connectedClient()
        let spaceID = HerdrKit.Layout.newID("sp"), tabID = HerdrKit.Layout.newID("tb"), paneID = HerdrKit.Layout.newID("p")
        let folder = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        let addr = try await run(c, argv: argv, task: task, cwd: folder.isEmpty ? home : folder, space: spaceID, tab: tabID)
        let after = selectedSpaceID
        try await placeOrKill(addr, c) {
            try await self.writeDoc { v in
                HerdrKit.Layout.addSpace(v, id: spaceID, name: name ?? "", folder: folder == self.home ? "" : folder,
                                tab: HerdrKit.Layout.tabJSON(id: tabID, name: tabName ?? "", paneID: paneID, terminal: addr), after: after)
            }
        }
        selectedSpaceID = spaceID
        selectedTabBySpace[spaceID] = tabID
        return addr
    }

    /// Removes a pane (collapsing the tree, closing an emptied tab/space).
    /// killTerminal: kill its program afterwards; else park it (unlabeled, not kept).
    func closePane(_ paneID: String, killTerminal: Bool) async throws {
        let c = try connectedClient()
        let terminal = HerdrKit.Layout.locate(pane: paneID, in: doc.value).flatMap { loc in
            spaces.first { $0.id == loc.space }?.tabs.first { $0.id == loc.tab }?.panes.first { $0.id == paneID }?.terminal
        }
        if !killTerminal, let terminal {
            _ = try await c.call("terminal.label", ["terminal": .string(terminal), "labels": ["herdr.space": "", "herdr.tab": ""]])
            _ = try await c.call("terminal.keep", ["terminal": .string(terminal), "keep": false])
        }
        try await writeDoc { v in try HerdrKit.Layout.removePane(v, pane: paneID).value }
        if killTerminal, let terminal {
            _ = try? await c.call("terminal.kill", ["terminal": .string(terminal)], timeout: 15)
        }
        fixSelection()
    }

    func renameTab(_ tabID: String, to name: String) async throws {
        _ = try connectedClient()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try await writeDoc { v in try HerdrKit.Layout.renameTab(v, tab: tabID, to: name) }
    }

    func renameSpace(_ spaceID: String, to name: String) async throws {
        _ = try connectedClient()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try await writeDoc { v in try HerdrKit.Layout.renameSpace(v, space: spaceID, to: name) }
    }

    func send(_ address: String, text: String) async throws {
        _ = try await connectedClient().call("terminal.send", ["terminal": .string(address), "text": .string(text)], timeout: 15)
    }
    func keys(_ address: String, _ keys: [String]) async throws {
        _ = try await connectedClient().call("terminal.keys", ["terminal": .string(address), "keys": .array(keys.map { .string($0) })])
    }
    func interrupt(_ address: String) async throws {
        _ = try await connectedClient().call("terminal.interrupt", ["terminal": .string(address), "timeout": 10], timeout: 20)
    }
    func kill(_ address: String) async throws {
        _ = try await connectedClient().call("terminal.kill", ["terminal": .string(address)], timeout: 20)
    }

    // MARK: For mods
    func exec(argv: [String], cwd: String?, on: String?, timeout: Int, input: Data?) async throws -> ExecResult {
        try await connectedClient().exec(argv: argv, cwd: cwd, on: on, timeout: timeout, input: input)
    }
    func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        try await connectedClient().call(method, params)
    }
    func toast(_ title: String, body: String? = nil, level: String = "info") {
        toast(title, body: body, level: level, address: nil, duration: nil)
    }
    func toast(_ title: String, body: String?, level: String, address: String?, duration: Double?) {
        toasts.append(Toast(title: title, body: body, level: level, address: address, duration: duration))
        if toasts.count > 8 { toasts.removeFirst(toasts.count - 8) }
    }

    /// Pull-to-refresh: re-read the layout and terminal table on a healthy
    /// connection; reconnect only when there isn't one.
    func refresh() async {
        guard phase == .connected, let c = client else { reconnect(); return }
        let gen = generation
        // Terminals stay current through the event stream; the doc is the one worth re-reading.
        guard let d = try? await c.docGet(HerdrKit.Layout.docName), gen == generation else { return }
        applyDoc(d)
    }

    // MARK: - Connect pipeline

    private func currentMachine() -> MachineConfig? {
        machines.first { $0.id == activeMachineID } ?? machines.first
    }

    private func connectedClient() throws -> HerdrClient {
        guard let client, phase == .connected || client.isConnected else {
            throw HerdrError(code: -1, kind: "lost", message: "Not connected", hint: "reconnecting to the machine")
        }
        return client
    }

    private func startConnect(_ m: MachineConfig, reconnecting: Bool) {
        reconnectTask?.cancel(); reconnectTask = nil
        connectTask?.cancel()
        teardownClient()
        generation += 1
        let gen = generation
        // Synchronously, so no frame shows the idle/failure screen before the task runs.
        connectStep = 0
        phase = .connecting(reconnecting ? "Reconnecting to \(m.host)" : "Opening SSH to \(m.host)")
        connectTask = Task { [weak self] in await self?.runConnect(m, gen: gen, reconnecting: reconnecting) }
    }

    private func step(_ s: String, _ index: Int, _ gen: Int) -> Bool {
        guard gen == generation, !Task.isCancelled else { return false }
        connectStep = index
        phase = .connecting(s)
        return true
    }

    private func runConnect(_ m: MachineConfig, gen: Int, reconnecting: Bool) async {
        let verb = reconnecting ? "Reconnecting" : "Opening SSH"
        guard step("\(verb) to \(m.host)", 0, gen) else { return }
        let auth: CitadelTransport.Auth
        do {
            if m.usePassword, let pw = KeyStore.password(for: m.id) { auth = .password(pw) } else { auth = .key(try KeyStore.signingKey()) }
        } catch {
            fail(error, gen: gen, retry: false); return
        }
        let transport = CitadelTransport(host: m.host, port: m.port, user: m.user, auth: auth)
        let c = HerdrClient(transport: transport)
        c.onDisconnect = { [weak self] err in self?.connectionLost(err, gen: gen) }
        client = c
        do {
            _ = step("Starting herdr-core", 1, gen)
            let info = try await c.connect()
            guard gen == generation else { c.close(); return }
            hello = info
            diagnostics = ""

            guard step("Subscribing to events", 2, gen) else { return }
            let sub = try await c.subscribe()
            guard gen == generation else { return }
            wire(sub, gen: gen)
            absorbSnapshot(sub.snapshot)

            guard step("Reading the layout", 3, gen) else { return }
            let d = try await c.docGet(HerdrKit.Layout.docName)
            guard gen == generation else { return }
            applyDoc(d)

            phase = .connected
            connectStep = -1
            hostKeyMismatch = false
            attempt = 0
            Task { [weak self] in await self?.learnHome(gen: gen) }
        } catch {
            guard gen == generation else { return }
            diagnostics = c.stderrText
            fail(error, gen: gen, retry: Self.isRetryable(error))
        }
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if error is HostKeys.Mismatch || error is KeyStore.KeyError { return false }
        if let e = error as? HerdrError, ["auth", "needs_update", "not_installed"].contains(e.kind ?? "") { return false }
        return true
    }

    private func fail(_ error: Error, gen: Int, retry: Bool) {
        guard gen == generation else { return }
        teardownClient()
        if !retry { reconnectTask?.cancel(); reconnectTask = nil }
        hostKeyMismatch = error is HostKeys.Mismatch
        connectStep = -1
        phase = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
        // Only keep trying on our own when there's a session to get back to.
        if retry, wantConnected, hello != nil { scheduleReconnect() }
    }

    private func connectionLost(_ error: HerdrError, gen: Int) {
        // Only a live session is "lost": while connecting, runConnect's catch owns the error
        // (otherwise a non-retryable failure would be replaced by an endless "Reconnecting").
        guard gen == generation, phase == .connected else { return }
        teardownClient()
        alertsArmed = false
        guard wantConnected else { phase = .idle; return }
        connectStep = 0
        phase = .connecting("Reconnecting")
        if sceneActive { scheduleReconnect(immediate: attempt == 0) }
    }

    private func scheduleReconnect(immediate: Bool = false) {
        guard wantConnected, sceneActive, let m = currentMachine() else { return }
        reconnectTask?.cancel()
        let delay = immediate ? 0.3 : min(15, pow(2, Double(min(attempt, 4))))   // 1, 2, 4, 8, 15 s
        attempt += 1
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.wantConnected, self.sceneActive else { return }
            self.startConnect(m, reconnecting: true)
        }
    }

    /// Closes the connection quietly (no reconnect from its callbacks).
    private func dropConnection(phase newPhase: ConnectionPhase) {
        generation += 1
        connectTask?.cancel(); connectTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        teardownClient()
        alertsArmed = false
        connectStep = -1
        phase = newPhase
    }

    private func teardownClient() {
        subscription?.onUpdate = nil; subscription?.onClose = nil; subscription?.onLost = nil
        subscription = nil
        if let c = client { c.onDisconnect = nil; c.close() }
        client = nil
    }

    private func clearLiveState() {
        terminals = [:]; doc = LayoutDoc(value: .null, version: 0); spaces = []; hello = nil
        attentionState = AttentionTracker()
    }

    private func learnHome(gen: Int) async {
        guard let c = client,
              let r = try? await c.exec(argv: ["sh", "-c", "printf %s \"$HOME\""], timeout: 10),
              r.code == 0, gen == generation else { return }
        let h = String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard h.hasPrefix("/"), h != home else { return }
        home = h
        if let id = activeMachineID { defaults.set(h, forKey: "home." + id.uuidString) }
    }

    // MARK: Events

    private func wire(_ sub: EventSubscription, gen: Int) {
        subscription = sub
        sub.onUpdate = { [weak self] u in
            guard let self, gen == self.generation else { return }
            self.apply(u)
        }
        sub.onClose = { [weak self] in
            // The core closed the events channel: subscribe again, then re-read the doc.
            guard let self, gen == self.generation, let c = self.client else { return }
            Task { [weak self] in
                guard let self else { return }
                do {
                    let s = try await c.subscribe()
                    guard gen == self.generation else { s.cancel(); return }
                    self.wire(s, gen: gen)
                    self.absorb(records: s.snapshot, alerts: true)
                    self.refreshDoc()
                } catch {
                    self.connectionLost(HerdrError(code: -1, kind: "lost", message: "Lost the event stream"), gen: gen)
                }
            }
        }
    }

    /// The first snapshot after connecting: restore saved attention, no alerts.
    private func absorbSnapshot(_ records: [TerminalRecord]) {
        alertsArmed = false
        // In-memory state is newer than what's saved (reconnects); saved state covers launches.
        let saved = attentionState.agents.isEmpty ? loadAttention() : attentionState
        var fresh = AttentionTracker()
        fresh.restore(saved, current: records)
        attentionState = fresh
        absorb(records: records, alerts: false)
        alertsArmed = true
        scheduleAttentionSave()
    }

    private func apply(_ u: EventUpdate) {
        if u.pushed.terminals { absorb(records: u.terminals, alerts: alertsArmed && !u.pushed.missed) }
        if u.pushed.missed || u.pushed.docs.contains(where: { $0.name == HerdrKit.Layout.docName && $0.machine == nil && $0.version != doc.version }) {
            refreshDoc()
        }
    }

    /// Replaces the terminal table (one observable write) and runs the seen
    /// state machine plus alerts for changed words.
    private func absorb(records: [TerminalRecord], alerts: Bool) {
        var next: [String: TerminalRecord] = [:]
        next.reserveCapacity(records.count)
        for r in records where !r.address.isEmpty { next[r.address] = r }
        if next != terminals { terminals = next }

        var tracker = attentionState
        let places = alerts ? paneIndex() : [:]
        for t in records where t.isLive {
            let prev = tracker.agents[t.address]?.word
            let looking = isLooking(t.address)
            guard tracker.setWord(t.address, t.statusWord, looking: looking, turn: t.turn) else { continue }
            guard alerts, t.parent == nil, places[t.address] != nil,
                  let alert = AttentionTracker.alert(prev: prev, new: t.statusWord, looking: looking) else { continue }
            raise(alert, for: t.address, place: places[t.address])
        }
        if sceneActive, let v = visibleTerminal { tracker.markSeen([v]) }
        tracker.prune(keeping: Set(records.lazy.filter(\.isLive).map(\.address)))
        if tracker != attentionState {
            attentionState = tracker
            scheduleAttentionSave()
        }
    }

    private func isLooking(_ address: String) -> Bool { sceneActive && visibleTerminal == address }

    private func markSeenVisible() {
        if let v = visibleTerminal { markSeen(v) }
    }

    private func raise(_ alert: AttentionTracker.Alert, for address: String, place: HerdrKit.Layout.PaneLocation?) {
        let name = displayName(of: address)
        var body: String?
        if let place, let s = spaces.first(where: { $0.id == place.space }),
           let ti = s.tabs.firstIndex(where: { $0.id == place.tab }) {
            body = "\(spaceName(s)) / \(tabName(s.tabs[ti], index: ti))"
        }
        switch alert {
        case .blocked:
            toast("\(name) needs you", body: body, level: "blocked", address: address, duration: 12)
            Sounds.play("request")
            // RootView plays the warning haptic when the blocked count rises.
        case .done:
            toast("\(name) finished", body: body, level: "done", address: address, duration: nil)
            Sounds.play("done")
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    // MARK: Doc

    private func applyDoc(_ d: LayoutDoc) {
        guard d != doc else { return }
        // Channel-0 replies can arrive out of order: never roll back within a connection.
        if docGeneration == generation, d.version < doc.version { return }
        docGeneration = generation
        doc = d
        let next = d.spaces
        if next != spaces { spaces = next }
        fixSelection()
    }

    /// Re-reads the doc; overlapping requests coalesce into one follow-up read.
    private func refreshDoc() {
        if docRefresh != nil { docRefreshAgain = true; return }
        let gen = generation
        docRefresh = Task { [weak self] in
            defer { self?.docRefresh = nil }
            repeat {
                guard let self, let c = self.client else { return }
                self.docRefreshAgain = false
                let d = try? await c.docGet(HerdrKit.Layout.docName)
                guard gen == self.generation else { return }
                // A failed read still honours a doc event that arrived meanwhile.
                if let d { self.applyDoc(d) }
            } while self?.docRefreshAgain == true
        }
    }

    /// CAS write of the layout doc: mutate the latest raw JSON, `doc.set` with
    /// its version; on conflict re-read, re-apply once, else give up with a toast.
    private func writeDoc(_ mutate: (JSONValue) throws -> JSONValue) async throws {
        let c = try connectedClient()
        var base = doc
        for attempt in 0..<2 {
            let value = try mutate(base.value)
            do {
                let v = try await c.docSet(HerdrKit.Layout.docName, value: value, version: base.version)
                applyDoc(LayoutDoc(value: value, version: v))
                return
            } catch let e as HerdrError where e.kind == "conflict" {
                base = try await c.docGet(HerdrKit.Layout.docName)
                applyDoc(base)
                if attempt == 1 {
                    toast("Layout changed elsewhere", body: "The other screen's layout is shown.", level: "warning")
                    throw e
                }
            }
        }
    }

    /// Runs the layout write that puts a just-started terminal on screen. If it
    /// fails (conflict twice, space deleted elsewhere, connection dropped), the
    /// terminal would keep running in no tab, where nobody can see or close it:
    /// kill it before passing the error on. Best effort: on a dead connection the
    /// kill can't be sent, and the terminal shows up under Other terminals.
    private func placeOrKill(_ addr: String, _ c: HerdrClient, _ place: () async throws -> Void) async throws {
        do {
            try await place()
        } catch {
            _ = try? await c.call("terminal.kill", ["terminal": .string(addr)], timeout: 15)
            throw error
        }
    }

    /// `terminal.run` with the herdr labels (SPEC §2): agents run inside the
    /// person's shell wrapper so the shell takes over when they exit.
    private func run(_ c: HerdrClient, argv: [String]?, task: String?, cwd: String, space: String, tab: String) async throws -> String {
        var argvOut: [String] = []
        if let argv, !argv.isEmpty {
            argvOut = ["sh", "-c", "\"$@\"; exec \"${SHELL:-sh}\" -i", "sh"] + argv
            if let task, !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { argvOut.append(task) }
        }
        let r = try await c.call("terminal.run", [
            "argv": .array(argvOut.map { .string($0) }),
            "cwd": .string(cwd.isEmpty ? home : cwd),
            "env": ["TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "herdr"],
            "labels": ["herdr.space": .string(space), "herdr.tab": .string(tab)],
            "keep": true,
        ], timeout: 20)
        guard let addr = r["address"].string, !addr.isEmpty else {
            throw HerdrError(code: -32603, kind: "internal", message: "terminal.run returned no address")
        }
        return addr
    }

    /// The selected tab's first terminal's live folder, else the space folder, else home.
    private func startFolder(for space: SpaceRef) -> String {
        let tab = selectedTabBySpace[space.id].flatMap { id in space.tabs.first { $0.id == id } } ?? space.tabs.first
        if let addr = tab?.panes.compactMap(\.terminal).first, let cwd = terminals[addr]?.cwd, !cwd.isEmpty { return cwd }
        return space.folder.isEmpty ? home : space.folder
    }

    /// Keeps the selection pointing at things that exist.
    private func fixSelection() {
        guard !spaces.isEmpty else { return }
        if selectedSpaceID == nil || !spaces.contains(where: { $0.id == selectedSpaceID }) {
            selectedSpaceID = spaces.first?.id
        }
        var fixed = selectedTabBySpace
        for s in spaces {
            if let t = fixed[s.id], s.tabs.contains(where: { $0.id == t }) { continue }
            fixed[s.id] = s.tabs.first?.id
        }
        fixed = fixed.filter { k, _ in spaces.contains { $0.id == k } }
        if fixed != selectedTabBySpace { selectedTabBySpace = fixed }
    }

    /// address -> where its first pane is.
    private func paneIndex() -> [String: HerdrKit.Layout.PaneLocation] {
        var out: [String: HerdrKit.Layout.PaneLocation] = [:]
        for (si, s) in spaces.enumerated() {
            for (ti, t) in s.tabs.enumerated() {
                for p in t.panes {
                    if let addr = p.terminal, out[addr] == nil {
                        out[addr] = HerdrKit.Layout.PaneLocation(space: s.id, tab: t.id, pane: p.id, spaceIndex: si, tabIndex: ti)
                    }
                }
            }
        }
        return out
    }

    /// t2 < t10; machine-qualified addresses after local ones.
    static func addressOrder(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }

    // MARK: Persistence

    private func persistMachines() {
        if let d = try? JSONEncoder().encode(machines) { defaults.set(d, forKey: "machines") }
        defaults.set(activeMachineID?.uuidString, forKey: "activeMachine")
    }

    private func loadMachines() {
        if let d = defaults.data(forKey: "machines"), let ms = try? JSONDecoder().decode([MachineConfig].self, from: d) {
            machines = ms
        } else {
            machines = []    // first launch: onboarding asks for a machine
        }
        activeMachineID = defaults.string(forKey: "activeMachine").flatMap(UUID.init(uuidString:)).flatMap { id in
            machines.contains { $0.id == id } ? id : nil
        } ?? machines.first?.id
    }

    private struct ViewState: Codable {
        var space: String?
        var tabs: [String: String]
    }

    private func loadMachineState() {
        guard let id = activeMachineID else { return }
        home = defaults.string(forKey: "home." + id.uuidString) ?? "~"
        restoringView = true
        defer { restoringView = false }
        if let d = defaults.data(forKey: "view." + id.uuidString), let v = try? JSONDecoder().decode(ViewState.self, from: d) {
            selectedSpaceID = v.space
            selectedTabBySpace = v.tabs
        } else {
            selectedSpaceID = nil
            selectedTabBySpace = [:]
        }
    }

    private func persistView() {
        guard !restoringView, let id = activeMachineID,
              let d = try? JSONEncoder().encode(ViewState(space: selectedSpaceID, tabs: selectedTabBySpace)) else { return }
        defaults.set(d, forKey: "view." + id.uuidString)
    }

    private func loadAttention() -> AttentionTracker {
        guard let id = activeMachineID, let d = defaults.data(forKey: "attention." + id.uuidString),
              let t = try? JSONDecoder().decode(AttentionTracker.self, from: d) else { return AttentionTracker() }
        return t
    }

    private func scheduleAttentionSave() {
        guard saveAttentionTask == nil else { return }
        let machine = activeMachineID
        saveAttentionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            // Cancelled, or the machine changed: this state isn't the current machine's to save.
            guard let self, !Task.isCancelled else { return }
            self.saveAttentionTask = nil
            if self.activeMachineID == machine { self.saveAttentionNow() }
        }
    }

    /// Saves now and drops the pending save (before switching machines).
    private func flushAttentionSave() {
        saveAttentionTask?.cancel(); saveAttentionTask = nil
        saveAttentionNow()
    }

    private func saveAttentionNow() {
        guard let id = activeMachineID, let d = try? JSONEncoder().encode(attentionState) else { return }
        defaults.set(d, forKey: "attention." + id.uuidString)
    }
}

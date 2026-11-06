import SwiftUI
import UIKit
import SwiftTerm
import HerdrKit

// MARK: Stream filter

/// Strips herdr's private sequences from the byte stream before SwiftTerm sees
/// them: OSC 7501 (status records) and CSI ?9001 h/l. Works across chunk
/// boundaries by holding back an incomplete trailing escape sequence.
/// Fast path: chunks without ESC are passed through untouched.
struct VTFilter {
    private var carry: [UInt8] = []
    private static let osc: [UInt8] = Array("\u{1b}]7501;".utf8)
    private static let csi: [UInt8] = Array("\u{1b}[?9001".utf8)
    private static let maxCarry = 64 * 1024

    mutating func reset() { carry.removeAll(keepingCapacity: true) }

    mutating func process(_ data: Data) -> [UInt8] {
        var buf: [UInt8]
        if carry.isEmpty {
            if !data.contains(0x1b) { return [UInt8](data) }
            buf = [UInt8](data)
        } else {
            buf = carry; buf.append(contentsOf: data); carry.removeAll(keepingCapacity: true)
        }
        var out: [UInt8] = []
        out.reserveCapacity(buf.count)
        let n = buf.count
        var i = 0
        while i < n {
            guard let esc = buf[i...].firstIndex(of: 0x1b) else { out.append(contentsOf: buf[i...]); break }
            out.append(contentsOf: buf[i..<esc])
            switch match(buf, at: esc) {
            case .osc:
                if let end = oscEnd(buf, from: esc + Self.osc.count) { i = end; continue }
                hold(buf, from: esc, into: &out); return out
            case .csi(let len):
                i = esc + len; continue
            case .partial:
                hold(buf, from: esc, into: &out); return out
            case .none:
                out.append(0x1b); i = esc + 1
            }
        }
        return out
    }

    private enum Match { case osc, csi(Int), partial, none }

    private func match(_ b: [UInt8], at s: Int) -> Match {
        let avail = b.count - s
        if prefix(b, s, Self.osc) { return avail >= Self.osc.count ? .osc : .partial }
        if prefix(b, s, Self.csi) {
            if avail < Self.csi.count + 1 { return .partial }
            let t = b[s + Self.csi.count]
            return t == UInt8(ascii: "h") || t == UInt8(ascii: "l") ? .csi(Self.csi.count + 1) : .none
        }
        return .none
    }

    /// True if b[s...] agrees with `p` for as many bytes as are available.
    private func prefix(_ b: [UInt8], _ s: Int, _ p: [UInt8]) -> Bool {
        let m = min(p.count, b.count - s)
        for k in 0..<m where b[s + k] != p[k] { return false }
        return true
    }

    /// Index just past the ST (ESC \) or BEL terminator.
    private func oscEnd(_ b: [UInt8], from: Int) -> Int? {
        var k = from
        while k < b.count {
            if b[k] == 0x07 { return k + 1 }
            if b[k] == 0x1b, k + 1 < b.count, b[k + 1] == 0x5c { return k + 2 }
            k += 1
        }
        return nil
    }

    private mutating func hold(_ b: [UInt8], from s: Int, into out: inout [UInt8]) {
        if b.count - s > Self.maxCarry { out.append(contentsOf: b[s...]); return }   // runaway: give up filtering
        carry = Array(b[s...])
    }
}

// MARK: Controller

/// Owns one terminal screen's stream and SwiftTerm view. Lives outside SwiftUI's
/// render path: store changes never touch the TerminalView.
@MainActor @Observable
final class TerminalController: NSObject, TerminalViewDelegate {
    enum Phase: Equatable {
        case attaching
        case live
        case ended(String)
        case restarting
        case lost
        case failed(String)
    }

    let address: String
    private(set) var phase: Phase = .attaching
    private(set) var fitToPhone = false
    private(set) var keyboardVisible = false
    var ctrlLatched = false { didSet { if viewportIfLoaded?.term.controlModifier != ctrlLatched { viewportIfLoaded?.term.controlModifier = ctrlLatched } } }
    var altLatched = false { didSet { if viewportIfLoaded?.term.metaModifier != altLatched { viewportIfLoaded?.term.metaModifier = altLatched } } }
    private(set) var gridSize: (cols: Int, rows: Int) = (0, 0)

    @ObservationIgnored private weak var store: AppStore?
    @ObservationIgnored private var stream: TerminalStream?
    @ObservationIgnored private var filter = VTFilter()
    @ObservationIgnored private var pending = Data()
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private var followCaretUntil: Date = .distantPast
    @ObservationIgnored private var restoreSize: (cols: Int, rows: Int)?
    @ObservationIgnored private var active = false
    @ObservationIgnored private var attachTask: Task<Void, Never>?
    @ObservationIgnored private let observers = ObserverBag()
    @ObservationIgnored private var fontSize: CGFloat
    @ObservationIgnored private var viewportIfLoaded: TerminalViewport?
    @ObservationIgnored private var lastDark: Bool?

    init(address: String, fontSize: CGFloat) {
        self.address = address
        self.fontSize = fontSize
        super.init()
    }

    /// Created on first use (cheap init; SwiftUI may re-create the struct holding us).
    var viewport: TerminalViewport {
        if let v = viewportIfLoaded { return v }
        let v = TerminalViewport(fontSize: fontSize)
        v.term.terminalDelegate = self
        viewportIfLoaded = v
        installObservers()
        return v
    }

    // MARK: Lifecycle

    func appear(store: AppStore) {
        self.store = store
        active = true
        if stream == nil, attachTask == nil, phase != .restarting { start() }
        else if phase == .restarting {
            // The restart may have finished while another screen was on top
            // (storeChanged is ignored while inactive): check again now.
            storeChanged(connected: store.phase == .connected, record: store.terminals[address])
        }
        else { stream?.focus(true) }
    }

    func disappear() {
        active = false
        attachTask?.cancel(); attachTask = nil
        if let s = stream {
            if fitToPhone, let r = restoreSize { s.resize(cols: r.cols, rows: r.rows) }
            s.focus(false)
            s.detach()
        }
        stream = nil
        fitToPhone = false
        restoreSize = nil
        if case .live = phase { phase = .attaching }
    }

    /// Leaving the app gives the desktop its size back (the app may never return
    /// to run `disappear()`); coming back re-applies the phone grid.
    func setSceneActive(_ on: Bool) {
        stream?.focus(on && active)
        guard fitToPhone, let s = stream else { return }
        if on {
            let g = phoneGrid()
            setGrid(cols: g.cols, rows: g.rows)
            s.resize(cols: g.cols, rows: g.rows)
        } else if let r = restoreSize {
            s.resize(cols: r.cols, rows: r.rows)
        }
    }

    /// (Re)attach: reset the emulator, size the grid, attach.
    func start() {
        guard let store else { return }
        attachTask?.cancel()
        stream?.detach(); stream = nil
        let rec = store.terminals[address]
        // A reattach (after loss or backgrounding) starts at the desktop's size again.
        if fitToPhone { fitToPhone = false; restoreSize = nil }
        let cols = rec?.cols ?? 80
        let rows = rec?.rows ?? 24
        phase = .attaching
        resetEmulator()
        setGrid(cols: cols, rows: rows)

        #if DEBUG
        if AppStore.isDemo {
            feed(Data(DemoData.screen(for: address, record: rec)))
            phase = .live
            return
        }
        #endif

        if let rec, !rec.isLive {
            phase = .ended(Self.reasonText(rec.raw))
            loadHistory()
            return
        }

        attachTask = Task { [weak self] in
            do {
                let s = try await store.attach(self?.address ?? "", cols: cols, rows: rows, observe: false)
                guard let self, !Task.isCancelled, self.active else { s.detach(); return }
                self.wire(s)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.attachTask = nil
                // The client fails pending calls before its disconnect callback
                // updates store.phase, so trust the error's kind too.
                let kind = (error as? HerdrError)?.kind
                if store.phase != .connected || kind == "lost" || kind == "closed" { self.phase = .lost }
                else if (error as? HerdrError)?.kind == "unavailable" {
                    // Lost keep:true program: the core restarts it; reattach after `restarted` (SPEC §2).
                    self.phase = .restarting
                } else { self.phase = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)") }
            }
        }
    }

    private func wire(_ s: TerminalStream) {
        attachTask = nil
        stream = s
        s.onData = { [weak self] d in self?.enqueue(d) }
        s.onClose = { [weak self] reason in self?.closed(reason) }
        s.onLost = { [weak self] in
            guard let self else { return }
            self.stream = nil
            self.phase = .lost
        }
        // The attach reply carries the authoritative size.
        let rc = s.record.cols, rr = s.record.rows
        if !fitToPhone, s.record.raw["cols"].int != nil, (rc, rr) != gridSize { setGrid(cols: rc, rows: rr) }
        s.focus(UIApplication.shared.applicationState == .active)
        phase = .live
    }

    private func closed(_ reason: JSONValue) {
        stream = nil
        flush()
        // Decide from the CLOSE reason: the record lags (CLOSE outruns the `finished`
        // event, and store updates are coalesced), so its state can't be trusted here.
        let why = reason["reason"].string
        let keep = store?.terminals[address]?.raw["keep"].bool ?? false
        if why == "lost" || (why == "signaled" && keep) {
            phase = .restarting      // keep:true program restarting; reattach after `restarted`
        } else {
            phase = .ended(Self.reasonText(reason))
        }
    }

    /// Called when the store reconnects or this terminal's record changes.
    func storeChanged(connected: Bool, record: TerminalRecord?) {
        guard active else { return }
        switch phase {
        case .lost where connected:
            start()
        case .restarting:
            guard let record else { break }
            if !record.isLive {
                phase = .ended(Self.reasonText(record.raw))
            } else if !record.raw["pid"].isNull {
                // `lost` clears the pid; `restarted` sets a new one: only then is attach possible.
                start()
            }
        case .failed where connected && stream == nil && attachTask == nil:
            break   // user retries explicitly
        default:
            break
        }
    }

    /// Desktop resized the program: follow it so our next keystroke doesn't snap it back (SPEC §3).
    func recordSizeChanged(cols: Int, rows: Int) {
        guard !fitToPhone, cols > 0, rows > 0, (cols, rows) != gridSize else { return }
        setGrid(cols: cols, rows: rows)
        stream?.resize(cols: cols, rows: rows)
    }

    func retry() { start() }

    // MARK: Fit to phone

    func setFitToPhone(_ on: Bool) {
        guard on != fitToPhone else { return }
        fitToPhone = on
        if on {
            restoreSize = gridSize
            let g = phoneGrid()
            setGrid(cols: g.cols, rows: g.rows)
            stream?.resize(cols: g.cols, rows: g.rows)
        } else {
            let r = restoreSize ?? (store?.terminals[address]).map { ($0.cols, $0.rows) } ?? gridSize
            restoreSize = nil
            setGrid(cols: r.cols, rows: r.rows)
            stream?.resize(cols: r.cols, rows: r.rows)
        }
    }

    private func phoneGrid() -> (cols: Int, rows: Int) {
        let v = viewport
        let w = max(v.bounds.width, 200) - 4
        let h = max(v.fullHeight, 200) - 4
        return (max(20, Int(w / v.cell.width)), max(8, Int(h / v.cell.height)))
    }

    private func setGrid(cols: Int, rows: Int) {
        gridSize = (cols, rows)
        viewport.setGrid(cols: cols, rows: rows, fitMode: fitToPhone)
    }

    // MARK: Output

    private func enqueue(_ d: Data) {
        pending.append(d)
        guard !flushScheduled else { return }
        flushScheduled = true
        // One feed per runloop turn, however many chunks arrived.
        DispatchQueue.main.async { [weak self] in self?.flush() }
    }

    private func flush() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        let d = pending
        pending = Data()
        feed(d)
    }

    private func feed(_ d: Data) {
        let bytes = filter.process(d)
        guard !bytes.isEmpty else { return }
        viewport.term.feed(byteArray: bytes[...])
        if Date.now < followCaretUntil { viewport.scrollCaretIntoView() }
    }

    private func resetEmulator() {
        pending.removeAll()
        filter.reset()
        let t = viewport.term.getTerminal()
        t.resetToInitialState()
        viewport.term.feed(text: "\u{1b}[H\u{1b}[2J\u{1b}[3J")
    }

    private func loadHistory() {
        guard let store else { return }
        Task { [weak self] in
            guard let text = try? await store.read(self?.address ?? "", lines: 2000), let self else { return }
            let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
            self.viewport.term.feed(text: normalized)
        }
    }

    func showHistory() {
        resetEmulator()
        loadHistory()
    }

    static func reasonText(_ j: JSONValue) -> String {
        let reason = j["reason"].string ?? "ended"
        if let sig = j["signal"].string ?? j["signal"].int.map(String.init) { return "\(reason), signal \(sig)" }
        if let code = j["exit_code"].int { return "\(reason) \(code)" }
        return reason
    }

    // MARK: Input

    func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        followCaretUntil = .now + 1.5
        stream?.write(Data(bytes))
    }

    func send(_ text: String) { send(Array(text.utf8)) }

    func arrow(_ dir: Character) {
        let app = viewport.term.getTerminal().applicationCursor
        send([0x1b, app ? 0x4f : 0x5b, UInt8(ascii: dir.unicodeScalars.first ?? "A")])
    }

    func paste() { viewport.term.paste(nil) }

    func showKeyboard() { _ = viewport.term.becomeFirstResponder() }
    func hideKeyboard() { _ = viewport.term.resignFirstResponder() }

    // MARK: Appearance

    func applyTheme(dark: Bool) {
        guard lastDark != dark else { return }
        lastDark = dark
        viewport.applyTheme(dark: dark)
    }

    // MARK: TerminalViewDelegate

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    nonisolated func clipboardRead(source: TerminalView) -> Data? { nil }

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        MainActor.assumeIsolated {
            self.send(bytes)
            if self.ctrlLatched { self.ctrlLatched = false }
            if self.altLatched { self.altLatched = false }
        }
    }

    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), let scheme = url.scheme, ["http", "https", "mailto"].contains(scheme) else { return }
        MainActor.assumeIsolated { UIApplication.shared.open(url) }
    }

    nonisolated func bell(source: TerminalView) {
        MainActor.assumeIsolated { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    }

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        guard let s = String(data: content, encoding: .utf8) else { return }
        MainActor.assumeIsolated { UIPasteboard.general.string = s }
    }

    // MARK: Keyboard tracking

    private func installObservers() {
        let nc = NotificationCenter.default
        observers.tokens.append(nc.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.viewportIfLoaded?.term.isFirstResponder == true else { return }
                self.keyboardVisible = true
                self.followCaretUntil = .now + 1
            }
        })
        observers.tokens.append(nc.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyboardVisible = false }
        })
        observers.tokens.append(nc.addObserver(forName: .terminalViewControlModifierReset, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.ctrlLatched == true { self?.ctrlLatched = false } }
        })
        observers.tokens.append(nc.addObserver(forName: .terminalViewMetaModifierReset, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.altLatched == true { self?.altLatched = false } }
        })
    }

}

/// Removes NotificationCenter observers when the controller goes away.
final class ObserverBag {
    var tokens: [NSObjectProtocol] = []
    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}

// MARK: Viewport

/// A zooming/panning scroll view around a fixed-grid TerminalView.
/// The TerminalView is laid out at exactly cols x rows cells of the render
/// font, so SwiftTerm's own size math lands on the program's real size;
/// zoom scales it to fit the phone (min ~7pt effective), pinch zooms, and
/// the scroll view pans when it doesn't fit.
final class TerminalViewport: UIScrollView, UIScrollViewDelegate {
    let term: TerminalView
    private(set) var cell = CGSize(width: 8, height: 17)
    private let fontSize: CGFloat
    private var cols = 0, rows = 0
    private var userZoomed = false
    private var fitMode = false
    private var lastBounds: CGSize = .zero
    /// Viewport height without the keyboard (for "fit to phone").
    private(set) var fullHeight: CGFloat = 0
    static let minReadablePoints: CGFloat = 7

    init(fontSize: CGFloat) {
        self.fontSize = fontSize
        term = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        super.init(frame: .zero)
        delegate = self
        bouncesZoom = true
        alwaysBounceVertical = false
        showsHorizontalScrollIndicator = true
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .herdr("background")
        clipsToBounds = true

        let f = HF.terminalFonts(size: fontSize)
        term.setFonts(normal: f.normal, bold: f.bold, italic: f.italic, boldItalic: f.boldItalic)
        term.inputAccessoryView = nil
        term.optionAsMetaKey = true
        term.allowMouseReporting = true
        term.keyboardAppearance = .default
        term.showsVerticalScrollIndicator = true
        term.changeScrollback(5000)
        // Measure the cell from SwiftTerm itself (it snaps to the pixel grid).
        let t = term.getTerminal()
        let opt = term.getOptimalFrameSize()
        if t.cols > 0, t.rows > 0, opt.width > 0 {
            cell = CGSize(width: opt.width / CGFloat(t.cols), height: opt.height / CGFloat(t.rows))
        }
        addSubview(term)
        applyTheme(dark: traitCollection.userInterfaceStyle != .light)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func applyTheme(dark: Bool) {
        let tokens = HerdrTheme.tokens(dark: dark)
        func ui(_ k: String) -> UIColor { UIColor(hex: tokens[k] ?? "#888888") }
        let palette: [SwiftTerm.Color] = (0..<16).map { i in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            ui("ansi\(i)").getRed(&r, green: &g, blue: &b, alpha: &a)
            return SwiftTerm.Color(red: UInt16(r * 65535), green: UInt16(g * 65535), blue: UInt16(b * 65535))
        }
        term.installColors(palette)
        term.nativeForegroundColor = ui("terminal_foreground")
        term.nativeBackgroundColor = ui("background")
        term.caretColor = ui("cursor")
        term.selectedTextBackgroundColor = ui("selection")
        term.keyboardAppearance = dark ? .dark : .light
        backgroundColor = ui("background")
        term.setNeedsDisplay(term.bounds)
    }

    func setGrid(cols: Int, rows: Int, fitMode: Bool) {
        guard cols > 0, rows > 0 else { return }
        let changed = cols != self.cols || rows != self.rows || fitMode != self.fitMode
        self.cols = cols; self.rows = rows
        if fitMode != self.fitMode { userZoomed = false }
        self.fitMode = fitMode
        guard changed else { return }
        let z = zoomScale
        zoomScale = 1
        // +0.5pt slack so floor(size / cell) lands exactly on cols x rows.
        term.frame = CGRect(x: 0, y: 0, width: CGFloat(cols) * cell.width + 0.5, height: CGFloat(rows) * cell.height + 0.5)
        contentSize = term.frame.size
        updateZoomLimits()
        zoomScale = userZoomed ? min(max(z, minimumZoomScale), maximumZoomScale) : defaultZoom
        updateRenderScale()
        centerContent()
    }

    private var fitWidthZoom: CGFloat {
        guard term.bounds.width > 0, bounds.width > 0 else { return 1 }
        return bounds.width / term.bounds.width
    }

    private var defaultZoom: CGFloat {
        if fitMode { return 1 }
        let readable = Self.minReadablePoints / fontSize
        return min(1, max(fitWidthZoom, readable))
    }

    private func updateZoomLimits() {
        minimumZoomScale = min(fitWidthZoom, defaultZoom, 1)
        maximumZoomScale = max(2.5, defaultZoom)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastBounds else { return }
        let widthChanged = bounds.width != lastBounds.width
        lastBounds = bounds.size
        if !term.isFirstResponder || fullHeight == 0 { fullHeight = bounds.height }
        updateZoomLimits()
        if widthChanged && !userZoomed { zoomScale = defaultZoom; updateRenderScale() }
        centerContent()
        scrollCaretIntoView()
    }

    /// Keep the cursor row visible (keyboard up, typing while zoomed).
    func scrollCaretIntoView() {
        guard contentSize.height > bounds.height || contentSize.width > bounds.width else { return }
        let buf = term.getTerminal().buffer
        let x = CGFloat(buf.x) * cell.width * zoomScale
        let y = CGFloat(buf.y) * cell.height * zoomScale
        let r = CGRect(x: x - 40, y: y - cell.height * 2, width: 80, height: cell.height * 4 * zoomScale)
        scrollRectToVisible(r.intersection(CGRect(origin: .zero, size: contentSize)), animated: false)
    }

    private func centerContent() {
        let dx = max(0, (bounds.width - contentSize.width) / 2)
        contentInset = UIEdgeInsets(top: 0, left: dx, bottom: 0, right: 0)
    }

    /// Re-rasterize at the zoomed resolution so text stays crisp.
    private func updateRenderScale() {
        let s = (window?.screen.scale ?? UIScreen.main.scale) * min(max(zoomScale, 0.5), 3)
        if abs(term.contentScaleFactor - s) > 0.01 {
            term.contentScaleFactor = s
            term.setNeedsDisplay(term.bounds)
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { term }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerContent() }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        userZoomed = abs(scale - defaultZoom) > 0.02
        updateRenderScale()
    }

    func resetZoom() {
        userZoomed = false
        setZoomScale(defaultZoom, animated: true)
        updateRenderScale()
    }
}

// MARK: SwiftUI bridge

struct TerminalHost: UIViewRepresentable {
    let controller: TerminalController
    @Environment(\.colorScheme) private var scheme

    func makeUIView(context: Context) -> TerminalViewport {
        let v = controller.viewport
        controller.applyTheme(dark: scheme == .dark)
        return v
    }

    func updateUIView(_ v: TerminalViewport, context: Context) {
        controller.applyTheme(dark: scheme == .dark)   // no-op unless the scheme flipped
    }
}

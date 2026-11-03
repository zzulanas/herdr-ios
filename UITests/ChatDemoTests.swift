import XCTest

/// Chat against demo data (HERDR_DEMO=1): no box needed. Demo sends append
/// the prompt to the transcript, flip the agent to working, then answer.
final class ChatDemoTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launchChat(_ address: String = "t18", draft: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        if let draft { app.launchEnvironment["HERDR_DEBUG_DRAFT"] = draft }
        app.launchEnvironment["HERDR_DEMO"] = "1"
        app.launchEnvironment["HERDR_DEBUG_OPEN"] = address
        app.launch()
        return app
    }

    private func composer(_ app: XCUIApplication) -> XCUIElement {
        // A vertical-axis TextField shows up as a text field or a text view depending on the OS.
        app.descendants(matching: .any).matching(identifier: "composer").firstMatch
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// The composer's text, from a snapshot (re-resolving the field by label stalls once its value changes).
    private func composerValue(_ app: XCUIApplication) -> String? {
        guard let root = try? app.snapshot() else { return nil }
        func find(_ e: XCUIElementSnapshot) -> XCUIElementSnapshot? {
            if e.identifier == "composer" { return e }
            for c in e.children { if let f = find(c) { return f } }
            return nil
        }
        return find(root)?.value as? String
    }

    /// Chat text actually on screen (between the nav bar and the composer), from one snapshot.
    private func visibleChatTexts(_ app: XCUIApplication) -> [String] {
        guard let root = try? app.snapshot() else { return [] }
        var all: [XCUIElementSnapshot] = []
        func walk(_ e: XCUIElementSnapshot) { all.append(e); e.children.forEach(walk) }
        walk(root)
        let top = all.first { $0.elementType == .navigationBar }?.frame.maxY ?? 0
        let bottom = all.first { $0.identifier == "composer" }?.frame.minY ?? root.frame.maxY
        let band = CGRect(x: root.frame.minX, y: top, width: root.frame.width, height: max(0, bottom - top))
        // Only the chat's own scroll view (the biggest), so a toast can't pass for chat text.
        guard let chat = all.filter({ $0.elementType == .scrollView }).max(by: { $0.frame.height * $0.frame.width < $1.frame.height * $1.frame.width })
        else { return [] }
        var texts: [XCUIElementSnapshot] = []
        func collect(_ e: XCUIElementSnapshot) { if e.elementType == .staticText { texts.append(e) }; e.children.forEach(collect) }
        collect(chat)
        return texts.filter { !$0.label.isEmpty && band.intersects($0.frame) }.map(\.label)
    }

    /// The bug: after tapping ↑ the chat went blank until scrolled. Sample the
    /// screen right after sending and through the reply; it must never be empty
    /// and the new prompt and reply must be on screen.
    func testSendKeepsChatVisible() throws {
        let prompt = "Please run the whole test suite again"
        let app = launchChat()
        let field = composer(app)
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no composer")
        field.tap()
        field.typeText(prompt)
        try sendAndWatch(app, prompt)
    }

    /// Same with no keyboard up (Send tapped with the field unfocused).
    func testSendWithoutKeyboardKeepsChatVisible() throws {
        let prompt = "Ship it when the tests are green"
        let app = launchChat(draft: prompt)
        XCTAssertTrue(composer(app).waitForExistence(timeout: 20), "no composer")
        try sendAndWatch(app, prompt)
    }

    private func sendAndWatch(_ app: XCUIApplication, _ prompt: String) throws {
        sleep(1)
        XCTAssertFalse(chatLooksBlank(app.screenshot()), "chat blank before sending")
        // Chat opens at the latest turn, not the top of the history.
        let opened = visibleChatTexts(app)
        XCTAssertTrue(opened.contains("Yes, put it in the URL"), "chat didn't open at the bottom: \(opened)")
        shot(app, "before-send")
        app.buttons["Send"].tap()
        // Screenshots are cheap, so sample densely through prompt → working → reply (~6 s).
        let end = Date().addingTimeInterval(6)
        var i = 0
        while Date() < end {
            let s = XCUIScreen.main.screenshot()
            if chatLooksBlank(s) {
                let a = XCTAttachment(screenshot: s); a.name = "blank-\(i)"; a.lifetime = .keepAlways; add(a)
                XCTFail("chat went blank after send (sample \(i))")
                return
            }
            i += 1
            usleep(150_000)
        }
        XCTAssertGreaterThan(i, 10, "too few samples to trust")
        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'All 42 tests pass'")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "reply not shown")
        shot(app, "after-reply")
        let texts = visibleChatTexts(app)
        XCTAssertTrue(texts.contains(prompt), "sent prompt not on screen: \(texts)")
        XCTAssertTrue(texts.contains { $0.contains("All 42 tests pass") }, "reply not on screen (not scrolled to bottom): \(texts)")
    }

    /// True when the chat area (below the nav bar, above the composer/keyboard)
    /// is one flat color: rows not drawn.
    private func chatLooksBlank(_ shot: XCUIScreenshot) -> Bool {
        guard let cg = shot.image.cgImage else { return false }
        let w = cg.width, h = cg.height
        // 16%..50% of the height is chat in both layouts (keyboard up or down).
        let y0 = h * 16 / 100, y1 = h * 50 / 100
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = { ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h)); return ctx.data }() else { return false }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var lo = 255, hi = 0
        for y in stride(from: y0, to: y1, by: 3) {
            for x in stride(from: 0, to: w, by: 3) {
                // CGContext rows run bottom-up.
                let o = ((h - 1 - y) * w + x) * 4
                let l = (Int(px[o]) + Int(px[o + 1]) + Int(px[o + 2])) / 3
                lo = min(lo, l); hi = max(hi, l)
            }
        }
        return hi - lo < 24   // text anywhere gives a big spread
    }
}

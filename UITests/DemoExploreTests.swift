import XCTest

/// Walks the main screens on demo data (no box needed) and saves a screenshot
/// of each to $SHOTS_DIR (pass TEST_RUNNER_SHOTS_DIR to xcodebuild).
final class DemoExploreTests: XCTestCase {
    private var app: XCUIApplication!
    private var prefix = ""

    private func launch(_ extra: [String: String] = [:], args: [String] = []) {
        app = XCUIApplication()
        app.launchEnvironment["HERDR_DEMO"] = "1"
        for (k, v) in extra { app.launchEnvironment[k] = v }
        app.launchArguments += args
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        sleep(2)
    }

    private func shot(_ name: String) {
        let s = app.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = prefix + name; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["SHOTS_DIR"] {
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(prefix + name + ".png"))
        }
    }

    private func back() { app.navigationBars.buttons.element(boundBy: 0).tap(); sleep(1) }

    private func tour() {
        shot("01-home")
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'OAuth'")).firstMatch.tap(); sleep(3)
        shot("02-agent-blocked")
        back()
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Global time slider'")).firstMatch.tap(); sleep(3)
        shot("03-agent-chat")
        // Pushed from Home, the chat opens on the latest turn, not the top of the history.
        let latest = app.staticTexts["Yes, put it in the URL"]
        XCTAssertTrue(latest.exists && app.frame.contains(latest.frame), "chat didn't open at the latest turn")
        back()
        app.swipeUp(); sleep(1)
        shot("04-home-scrolled")
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'webapp'")).firstMatch.tap(); sleep(2)
        shot("05-space")
        back()
        let empty = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '~'")).firstMatch
        if empty.exists { empty.tap(); sleep(2); shot("06-empty-space"); back() }
        let htop = app.buttons.matching(NSPredicate(format: "label CONTAINS 'htop'")).firstMatch
        if htop.exists { htop.tap(); sleep(3); shot("07-terminal"); back() }
        app.swipeDown(); sleep(1)
        app.buttons["New agent"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); sleep(2)
        shot("08-new-agent")
        app.swipeDown(velocity: .fast); sleep(1)
        app.buttons["Settings"].firstMatch.tap(); sleep(2)
        shot("09-settings")
        app.swipeUp(); sleep(1)
        shot("10-settings-scrolled")
    }

    func testTourLight() { prefix = "light-"; launch(args: ["-AppleInterfaceStyle", "Light"]); tour() }
    func testTourLargeText() {
        prefix = "xl-"
        launch(args: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        tour()
    }
}

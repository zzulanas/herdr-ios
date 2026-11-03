import Foundation
import Testing
@testable import HerdrKit

@Suite struct ChatFoldTests {
    @Test func foldsPromptsToolsAndResults() {
        let t = ChatFold.turns([
            .user("hi", nil), .text("looking"),
            .tool(id: "a", name: "Read", summary: "f", detail: "", at: nil),
            .tool(id: "b", name: "Bash", summary: "ls", detail: "", at: nil),
            .result(id: "b", isError: true, output: "nope"),
            .text("done"), .duration(ms: 1200),
            .user("again", nil),
        ])
        #expect(t.count == 2)
        #expect(t[0].prompt == .user("hi"))
        #expect(t[0].steps.count == 3)
        guard case .tools(_, let calls) = t[0].steps[1] else { Issue.record("no tools step"); return }
        #expect(calls.map(\.id) == ["a", "b"])
        #expect(calls[1].isError && calls[1].output == "nope" && calls[0].output == nil)
        #expect(t[0].durationMs == 1200 && t[0].lastText == "done")
        #expect(t[1].durationMs == nil && t[1].lastText == nil)
    }

    @Test func compactBoundaryIsOneMarker() {
        let t = ChatFold.turns([.user("a", nil), .compact, .compact, .text("x")])
        #expect(t.count == 2 && t[1].compacted)
    }
}

@Suite struct VoiceReplyWatchTests {
    let sentAt = Date(timeIntervalSince1970: 1_000_000)

    func turn(_ id: Int, _ prompt: String, _ texts: [String], done: Bool, at: Date? = nil) -> ChatTurn {
        ChatTurn(id: id, prompt: .user(prompt), steps: texts.enumerated().map { .text(id * 100 + $0.offset, $0.element) },
                 durationMs: done ? 1000 : nil, startedAt: at)
    }

    @Test func neverSpeaksThePreviousTurnWhileTranscriptLags() {
        var w = VoiceReplyWatch(sent: "run the tests", at: sentAt)
        let old = [turn(1, "earlier", ["Old answer."], done: true, at: sentAt.addingTimeInterval(-20))]
        // Status hasn't flipped yet and the transcript doesn't have our prompt.
        #expect(w.update(attention: .idle, turns: old) == .none)
        #expect(w.update(attention: .done, turns: old) == .none)
        // Now working, still on the old transcript: still nothing.
        #expect(w.update(attention: .working, turns: old) == .none)
        // Agent stops but our turn hasn't landed in the transcript yet.
        #expect(w.update(attention: .done, turns: old) == .none)
        let mine = old + [turn(2, "run  the tests\n", ["Running.", "All **42** pass."], done: true, at: sentAt)]
        #expect(w.update(attention: .done, turns: mine) == .speak("All 42 pass."))
        // Exactly once.
        #expect(w.update(attention: .done, turns: mine) == .none)
        #expect(w.update(attention: .idle, turns: mine) == .none)
    }

    @Test func waitsWhileWorkingAndForTheFinalText() {
        var w = VoiceReplyWatch(sent: "go", at: sentAt)
        let running = [turn(1, "go", ["Starting."], done: false, at: sentAt)]
        #expect(w.update(attention: .working, turns: running) == .none)
        // Transcript says the turn is over even if the status lags.
        let over = [turn(1, "go", ["Starting.", "Finished it."], done: true, at: sentAt)]
        #expect(w.update(attention: .working, turns: over) == .none)
        #expect(w.update(attention: .done, turns: over) == .speak("Finished it."))
    }

    @Test func aLaterTurnMeansOursIsNotTheReply() {
        var w = VoiceReplyWatch(sent: "go", at: sentAt)
        let t = [turn(1, "go", ["a"], done: true, at: sentAt), turn(2, "typed later", ["b"], done: true, at: sentAt)]
        #expect(w.update(attention: .done, turns: t) == .none)
    }

    @Test func identicalOldPromptIsNotOurs() {
        var w = VoiceReplyWatch(sent: "yes", at: sentAt)
        let t = [turn(1, "yes", ["Old."], done: true, at: sentAt.addingTimeInterval(-3600))]
        #expect(w.update(attention: .done, turns: t) == .none)
        #expect(w.update(attention: .working, turns: t) == .none)
    }

    @Test func blockedIsAnnouncedOnceAndOnlyAfterOurPromptStarted() {
        var w = VoiceReplyWatch(sent: "deploy", at: sentAt)
        // Already blocked when we sent (answering a dialog by voice): not news.
        #expect(w.update(attention: .blocked, turns: []) == .none)
        #expect(w.update(attention: .working, turns: []) == .none)
        #expect(w.update(attention: .blocked, turns: []) == .announceBlocked)
        #expect(w.update(attention: .blocked, turns: []) == .none)
        // After the choice, the reply is still spoken.
        let t = [turn(1, "deploy", ["Deployed."], done: true, at: sentAt)]
        #expect(w.update(attention: .done, turns: t) == .speak("Deployed."))
    }

    @Test func expires() {
        let w = VoiceReplyWatch(sent: "x", at: sentAt)
        #expect(!w.expired(now: sentAt.addingTimeInterval(60)))
        #expect(w.expired(now: sentAt.addingTimeInterval(VoiceReplyWatch.lifetime + 1)))
    }
}

@Suite struct SpokenTextTests {
    @Test(arguments: [
        ("Done. **All 42 tests pass.**\n\nSecond paragraph.", "Done. All 42 tests pass."),
        ("## Summary\n\nbody", "Summary"),
        ("```swift\nlet x = 1\n```\n\nIt compiles.", "It compiles."),
        ("| a | b |\n|---|---|\n\nTable above.", "Table above."),
        ("See [the PR](https://github.com/x/y/pull/1) and https://example.com/z now.", "See the PR and a link now."),
        ("Renamed `turn_changed` to _snake_case_ish_ style.", "Renamed turn_changed to snake_case_ish style."),
        ("- first\n- second", "first second"),
        ("1. one\n2. two", "one two"),
        ("> quoted *thing*", "quoted thing"),
        ("~~old~~ new", "old new"),
        ("", ""),
    ])
    func spoken(_ input: String, _ want: String) {
        #expect(VoiceReplyWatch.spoken(input) == want)
    }

    @Test func runawayParagraphIsCut() {
        let s = String(repeating: "This sentence is about forty characters. ", count: 20)
        let out = VoiceReplyWatch.spoken(s)
        #expect(out.count <= 321 && out.hasSuffix(".") && out.count >= 120)
    }
}

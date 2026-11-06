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

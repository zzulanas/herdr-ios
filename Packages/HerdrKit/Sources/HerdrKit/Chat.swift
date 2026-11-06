import Foundation

// The Chat model: entries from the box-side transcript script, folded into
// turns. Pure, so it is unit-tested here.

/// One entry the box-side script emitted (TranscriptScript).
public enum ChatEntry: Sendable {
    case user(String, Date?)
    case note(String)
    case command(String)
    case compact
    case text(String)
    case tool(id: String, name: String, summary: String, detail: String, at: Date?)
    case result(id: String, isError: Bool, output: String)
    case duration(ms: Int)
}

public struct ToolCall: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var summary: String
    public var detail: String
    public var output: String?
    public var isError = false
    public init(id: String, name: String, summary: String, detail: String, output: String? = nil, isError: Bool = false) {
        self.id = id; self.name = name; self.summary = summary; self.detail = detail; self.output = output; self.isError = isError
    }
}

public enum ChatStep: Identifiable, Equatable, Sendable {
    case text(Int, String)
    case tools(Int, [ToolCall])
    public var id: Int { switch self { case .text(let i, _), .tools(let i, _): i } }
    public var toolCount: Int { if case .tools(_, let c) = self { c.count } else { 0 } }
}

/// One prompt and everything the agent did in answer.
public struct ChatTurn: Identifiable, Equatable, Sendable {
    public enum Prompt: Equatable, Sendable { case user(String), note(String), command(String) }
    public var id: Int
    public var prompt: Prompt?
    public var compacted = false
    public var steps: [ChatStep] = []
    public var durationMs: Int?
    public var startedAt: Date?
    public init(id: Int, prompt: Prompt? = nil, compacted: Bool = false, steps: [ChatStep] = [], durationMs: Int? = nil, startedAt: Date? = nil) {
        self.id = id; self.prompt = prompt; self.compacted = compacted; self.steps = steps; self.durationMs = durationMs; self.startedAt = startedAt
    }

    /// The agent's last text in this turn: its answer once the turn is over.
    public var lastText: String? {
        steps.reversed().lazy.compactMap { step -> String? in
            if case .text(_, let s) = step { return s } else { return nil }
        }.first
    }
}

public enum ChatFold {
    /// Folds entries into turns: a prompt starts one; texts and tool calls
    /// follow; consecutive tool calls share a group; results attach by id.
    public static func turns(_ entries: [ChatEntry]) -> [ChatTurn] {
        var out: [ChatTurn] = []
        var where_: [String: (turn: Int, step: Int, call: Int)] = [:]
        var n = 0
        func next() -> Int { n += 1; return n }
        func current() -> Int {
            if out.isEmpty { out.append(ChatTurn(id: next())) }
            return out.count - 1
        }
        for e in entries {
            switch e {
            case .user(let s, let at): out.append(ChatTurn(id: next(), prompt: .user(s), startedAt: at))
            case .note(let s): out.append(ChatTurn(id: next(), prompt: .note(s)))
            case .command(let s): out.append(ChatTurn(id: next(), prompt: .command(s)))
            case .compact:
                // A boundary and its "continued from" summary arrive together: one marker.
                if let last = out.last, last.compacted, last.prompt == nil, last.steps.isEmpty { continue }
                out.append(ChatTurn(id: next(), compacted: true))
            case .text(let s):
                let i = current(); out[i].steps.append(.text(next(), s))
            case .tool(let id, let name, let sum, let detail, let at):
                let i = current()
                if out[i].startedAt == nil { out[i].startedAt = at }
                let call = ToolCall(id: id, name: name, summary: sum, detail: detail)
                if case .tools(let sid, var calls)? = out[i].steps.last {
                    calls.append(call)
                    out[i].steps[out[i].steps.count - 1] = .tools(sid, calls)
                    where_[id] = (i, out[i].steps.count - 1, calls.count - 1)
                } else {
                    out[i].steps.append(.tools(next(), [call]))
                    where_[id] = (i, out[i].steps.count - 1, 0)
                }
            case .result(let id, let err, let output):
                guard let w = where_[id], case .tools(let sid, var calls) = out[w.turn].steps[w.step] else { continue }
                calls[w.call].output = output
                calls[w.call].isError = err
                out[w.turn].steps[w.step] = .tools(sid, calls)
            case .duration(let ms):
                if !out.isEmpty { out[out.count - 1].durationMs = ms }
            }
        }
        return out
    }
}

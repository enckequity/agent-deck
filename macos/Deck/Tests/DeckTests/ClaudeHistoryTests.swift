import XCTest
@testable import Deck

final class ClaudeHistoryTests: XCTestCase {
    /// A real Claude Code transcript (a finished deck-task run) with every text, command and
    /// tool result replaced; the turn structure, block types, tool names and stop reasons are real.
    func testRealTranscriptFixture() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "claude-transcript", withExtension: "jsonl",
                                                  subdirectory: "Fixtures"))
        let conversation = ClaudeHistory.parse(try Data(contentsOf: url))

        XCTAssertEqual(conversation.entries.first, .user("Fix the example issue."))
        let assistantTexts = conversation.entries.filter { if case .assistant = $0 { true } else { false } }
        XCTAssertEqual(assistantTexts.count, 30)
        XCTAssertEqual(conversation.entries.last, .assistant("Fixed and merged: https://github.com/example/repo/pull/1"))
        // Tool steps between texts fold into single entries; no two step groups are adjacent.
        let steps = conversation.entries.compactMap { if case .steps(let s) = $0 { s } else { nil } }
        XCTAssertFalse(steps.isEmpty)
        XCTAssertEqual(steps.flatMap { $0 }.count, 73)
        for (a, b) in zip(conversation.entries, conversation.entries.dropFirst()) {
            if case .steps = a, case .steps = b { XCTFail("adjacent step groups") }
        }
        XCTAssertTrue(steps.flatMap { $0 }.contains("Review the diff"))
        XCTAssertTrue(steps.flatMap { $0 }.contains { $0.hasPrefix("Edited file") })
        XCTAssertEqual(conversation.marker, .done)
        XCTAssertFalse(conversation.busy)
        XCTAssertEqual(conversation.pullRequest, URL(string: "https://github.com/example/repo/pull/1"))
    }

    func testSkipsNoiseAndTracksTurnState() {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"do the thing"}}"#,
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>Caveat</local-command-caveat>"}}"#,
            #"{"type":"user","message":{"role":"user","content":"<command-name>/model</command-name>"}}"#,
            #"{"type":"user","message":{"role":"user","content":"<task-notification>\n<task-id>x</task-id>"}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#,
            #"{"type":"system","subtype":"turn_duration","content":"noise"}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"subagent chatter"}],"stop_reason":"end_turn"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":""}],"stop_reason":"tool_use"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a/b.swift"}}],"stop_reason":"tool_use"}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"x"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"mcp__hindsight__hindsight_reflect","input":{}}],"stop_reason":"tool_use"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"TodoWrite","input":{}}],"stop_reason":"tool_use"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Need a token.\nBLOCKED: missing credential"}],"stop_reason":"end_turn"}}"#,
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"Stop hook feedback:\ncontinue"}}"#,
            "not json",
        ]
        let conversation = ClaudeHistory.parse(Data(lines.joined(separator: "\n").utf8))
        XCTAssertEqual(conversation.entries, [
            .user("do the thing"),
            .steps(["Read b.swift", "Used reflect"]),
            .assistant("Need a token.\nBLOCKED: missing credential"),
            .autoContinued,
        ])
        XCTAssertTrue(conversation.busy, "an auto-continue nudge starts a new turn")
        XCTAssertEqual(conversation.marker, .none)
    }

    func testMarkerFromFinalReply() {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"go"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"WAITING: CI run"}],"stop_reason":"end_turn"}}"#,
        ]
        let conversation = ClaudeHistory.parse(Data(lines.joined(separator: "\n").utf8))
        XCTAssertEqual(conversation.marker, .waiting("CI run"))
        XCTAssertFalse(conversation.busy)
    }

    func testTranscriptPathEncoding() {
        XCTAssertEqual(
            ClaudeHistory.transcriptPath(directory: "/Users/me/.local/share/agent-deck/conductor/autopilot", claudeSessionID: "abc"),
            "\(ClaudeHistory.projectsPath)/-Users-me--local-share-agent-deck-conductor-autopilot/abc.jsonl")
        XCTAssertEqual(
            ClaudeHistory.transcriptPath(directory: "/Users/me/dev/worktrees/x/claude-fix_it-0923", claudeSessionID: "id"),
            "\(ClaudeHistory.projectsPath)/-Users-me-dev-worktrees-x-claude-fix-it-0923/id.jsonl")
    }

    func testTailReadDropsPartialFirstLine() throws {
        let path = NSTemporaryDirectory() + "deck-tail-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let filler = #"{"type":"user","message":{"role":"user","content":"old"}}"# + "\n"
        var body = String(repeating: filler, count: ClaudeHistory.tailBytes / filler.utf8.count + 10)
        body += #"{"type":"user","message":{"role":"user","content":"newest"}}"# + "\n"
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        let conversation = try XCTUnwrap(ClaudeHistory.load(path: path))
        XCTAssertEqual(conversation.entries.last, .user("newest"))
    }
}

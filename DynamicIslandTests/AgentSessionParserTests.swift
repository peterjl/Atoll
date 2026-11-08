/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import XCTest
@testable import Atoll

final class AgentSessionParserTests: XCTestCase {

    // MARK: Claude Code transcripts

    private func claudeLines() -> [[String: Any]] {
        [
            ["type": "ai-title", "aiTitle": "Fix login bug", "sessionId": "s1"],
            ["type": "user", "uuid": "u1", "timestamp": "2026-11-08T08:00:00.000Z", "gitBranch": "main",
             "message": ["role": "user", "content": "please fix the login bug"]],
            ["type": "assistant", "uuid": "a1", "timestamp": "2026-11-08T08:00:05.000Z",
             "message": ["model": "claude-opus-5-5", "stop_reason": "tool_use",
                         "usage": ["input_tokens": 10, "cache_read_input_tokens": 1000, "cache_creation_input_tokens": 90, "output_tokens": 5],
                         "content": [["type": "text", "text": "Let me look at the auth module."],
                                     ["type": "tool_use", "name": "Bash", "input": ["command": "git status", "description": "Show status"]]]]],
            ["type": "user", "uuid": "u2", "timestamp": "2026-11-08T08:00:06.000Z",
             "message": ["role": "user", "content": [["type": "tool_result", "content": "clean"]]]],
            ["type": "assistant", "uuid": "sub", "isSidechain": true, "timestamp": "2026-11-08T08:00:07.000Z",
             "message": ["stop_reason": "end_turn", "content": [["type": "text", "text": "subagent chatter"]]]],
            ["type": "user", "uuid": "u3", "isMeta": true, "timestamp": "2026-11-08T08:00:07.500Z",
             "message": ["role": "user", "content": "meta note"]],
            ["type": "assistant", "uuid": "a2", "timestamp": "2026-11-08T08:00:09.000Z",
             "message": ["model": "claude-opus-5-5", "stop_reason": "end_turn",
                         "usage": ["input_tokens": 4, "cache_read_input_tokens": 2000, "cache_creation_input_tokens": 0, "output_tokens": 50],
                         "content": [["type": "text", "text": "Fixed: the token check was inverted."]]]],
            ["type": "system", "subtype": "turn_duration", "durationMs": 9000, "timestamp": "2026-11-08T08:00:09.100Z"],
            ["type": "cost-state", "totalCostUSD": 0.42],
        ]
    }

    func testClaudeTranscriptFinishedTurn() {
        let summary = ClaudeTranscriptParser.parse(claudeLines())
        XCTAssertEqual(summary.title, "Fix login bug")
        XCTAssertEqual(summary.lastPrompt, "please fix the login bug")
        XCTAssertEqual(summary.lastSummary, "Fixed: the token check was inverted.")
        XCTAssertEqual(summary.model, "claude-opus-5-5")
        XCTAssertEqual(summary.gitBranch, "main")
        XCTAssertEqual(summary.contextTokens, 2004)
        XCTAssertEqual(summary.sessionCostUSD, 0.42)
        XCTAssertEqual(summary.lastTurnDuration, 9)
        XCTAssertFalse(summary.turnInProgress)
        XCTAssertEqual(summary.steps.map(\.kind), [.prompt, .commentary, .tool, .answer])
        XCTAssertEqual(summary.steps[2].text, "Bash · Show status")
        XCTAssertFalse(summary.steps.contains { $0.text.contains("subagent") }, "sidechain entries are skipped")
    }

    func testClaudeTranscriptTurnInProgressAndInterrupt() {
        var lines = claudeLines()
        lines.append(["type": "user", "uuid": "u9", "timestamp": "2026-11-08T08:01:00.000Z",
                      "message": ["role": "user", "content": "now add a test"]])
        var summary = ClaudeTranscriptParser.parse(lines)
        XCTAssertTrue(summary.turnInProgress)
        XCTAssertEqual(summary.lastPrompt, "now add a test")
        XCTAssertEqual(ClaudeSessionReader.state(status: nil, summary: summary), .working)

        lines.append(["type": "user", "uuid": "u10", "timestamp": "2026-11-08T08:01:05.000Z",
                      "message": ["role": "user", "content": [["type": "text", "text": "[Request interrupted by user]"]]]])
        summary = ClaudeTranscriptParser.parse(lines)
        XCTAssertTrue(summary.interrupted)
        XCTAssertEqual(ClaudeSessionReader.state(status: "idle", summary: summary), .interrupted)
    }

    func testClaudeRegistryStatusMapping() {
        let summary = ClaudeTranscriptSummary()
        XCTAssertEqual(ClaudeSessionReader.state(status: "busy", summary: summary), .working)
        XCTAssertEqual(ClaudeSessionReader.state(status: "idle", summary: summary), .ready)
        XCTAssertEqual(ClaudeSessionReader.state(status: "waiting", summary: summary), .waiting)
        XCTAssertEqual(ClaudeSessionReader.state(status: "requires_action", summary: summary), .waiting)
    }

    func testClaudePromptFiltersHarnessText() {
        XCTAssertNil(ClaudeTranscriptParser.promptText("<command-name>/clear</command-name>"))
        XCTAssertNil(ClaudeTranscriptParser.promptText([["type": "tool_result", "content": "x"]]))
        XCTAssertEqual(ClaudeTranscriptParser.promptText([["type": "text", "text": " hi "]]), "hi")
    }

    func testClaudeRegistryEntryAndSlug() {
        let entry = ClaudeSessionReader.registryEntry(from: [
            "pid": 123, "sessionId": "abc", "cwd": "/Users/me/My.Project", "kind": "bg", "status": "busy",
            "name": "auto-name", "nameSource": "auto", "jobId": "job1", "updatedAt": 1_794_120_300_812,
        ])
        XCTAssertEqual(entry?.pid, 123)
        XCTAssertEqual(entry?.jobID, "job1")
        XCTAssertEqual(entry?.nameIsAutomatic, true)
        XCTAssertEqual(entry?.updatedAt?.timeIntervalSince1970 ?? 0, 1_794_120_300.812, accuracy: 0.01)
        XCTAssertEqual(ClaudeSessionReader.projectSlug(for: "/Users/me/My.Project"), "-Users-me-My-Project")
    }

    // MARK: Codex rollouts

    private func codexLines(endingWith end: [String: Any]?) -> [[String: Any]] {
        var lines: [[String: Any]] = [
            ["timestamp": "2026-11-08T08:00:00.000Z", "type": "session_meta",
             "payload": ["cwd": "/Users/me/proj", "originator": "codex-tui"]],
            ["timestamp": "2026-11-08T08:00:01.000Z", "type": "turn_context", "payload": ["model": "gpt-6.1-sol", "cwd": "/Users/me/proj"]],
            ["timestamp": "2026-11-08T08:00:01.100Z", "type": "event_msg",
             "payload": ["type": "task_started", "started_at": 1_794_124_802, "model_context_window": 475_000]],
            ["timestamp": "2026-11-08T08:00:01.200Z", "type": "event_msg",
             "payload": ["type": "item_completed", "item": ["type": "UserMessage", "id": "m1",
                                                            "content": [["type": "text", "text": "run the tests"]]]]],
            ["timestamp": "2026-11-08T08:00:02.000Z", "type": "event_msg",
             "payload": ["type": "item_completed", "item": ["type": "AgentMessage", "id": "m2", "phase": "commentary",
                                                            "content": [["type": "Text", "text": "Running the suite."]]]]],
            ["timestamp": "2026-11-08T08:00:03.000Z", "type": "event_msg",
             "payload": ["type": "item_completed", "item": ["type": "CommandExecution", "id": "c1", "status": "failed",
                                                            "parsed_cmd": [["type": "unknown", "cmd": "npm test"]]]]],
            ["timestamp": "2026-11-08T08:00:04.000Z", "type": "event_msg",
             "payload": ["type": "token_count",
                         "info": ["last_token_usage": ["input_tokens": 17_074, "output_tokens": 18],
                                  "total_token_usage": ["total_tokens": 17_092], "model_context_window": 475_000],
                         "rate_limits": ["primary": ["used_percent": 61.0, "window_minutes": 10_080, "resets_at": 1_794_379_643],
                                         "secondary": NSNull()]]],
        ]
        if let end { lines.append(end) }
        return lines
    }

    func testCodexRolloutCompletedTurn() {
        let summary = CodexRolloutParser.parse(codexLines(endingWith: [
            "timestamp": "2026-11-08T08:00:05.000Z", "type": "event_msg",
            "payload": ["type": "task_complete", "last_agent_message": "All 12 tests pass.", "duration_ms": 4000],
        ]))
        XCTAssertEqual(summary.state, .ready)
        XCTAssertEqual(summary.lastSummary, "All 12 tests pass.")
        XCTAssertEqual(summary.lastPrompt, "run the tests")
        XCTAssertEqual(summary.lastTurnDuration, 4)
        XCTAssertEqual(summary.model, "gpt-6.1-sol")
        XCTAssertEqual(summary.originator, "codex-tui")
        XCTAssertEqual(summary.contextTokens, 17_074)
        XCTAssertEqual(summary.contextWindow, 475_000)
        XCTAssertEqual(summary.sessionTokens, 17_092)
        XCTAssertEqual(summary.quotaWindows.map(\.label), ["7d"])
        XCTAssertEqual(summary.quotaWindows.first?.usedPercent, 61)
        XCTAssertEqual(summary.steps.map(\.kind), [.prompt, .commentary, .tool])
        XCTAssertEqual(summary.steps.last?.exitCode, -1)
        XCTAssertEqual(summary.steps.last?.text, "Shell · npm test")
    }

    func testCodexRolloutWorkingAbortedAndWaiting() {
        XCTAssertEqual(CodexRolloutParser.parse(codexLines(endingWith: nil)).state, .working)
        XCTAssertEqual(CodexRolloutParser.parse(codexLines(endingWith: [
            "timestamp": "2026-11-08T08:00:05.000Z", "type": "event_msg",
            "payload": ["type": "turn_aborted", "reason": "interrupted", "duration_ms": 88_000],
        ])).state, .interrupted)
        XCTAssertEqual(CodexRolloutParser.parse(codexLines(endingWith: [
            "timestamp": "2026-11-08T08:00:05.000Z", "type": "event_msg",
            "payload": ["type": "exec_approval_request", "command": ["rm", "-rf", "build"]],
        ])).state, .waiting)
    }

    func testCodexAssignsNewestThreadToMatchingProcess() {
        let base = Date(timeIntervalSince1970: 1_794_120_000)
        func thread(_ id: String, created: TimeInterval, updated: TimeInterval, cwd: String = "/p") -> CodexSessionReader.ThreadRow {
            .init(id: id, rolloutPath: "/r/\(id)", cwd: cwd, title: nil, createdAt: base.addingTimeInterval(created),
                  updatedAt: base.addingTimeInterval(updated), originator: "codex-tui", model: nil, gitBranch: nil)
        }
        func process(_ pid: Int32, started: TimeInterval, cwd: String = "/p") -> (info: AgentProcessInspector.Info, cwd: String?) {
            (AgentProcessInspector.Info(pid: pid, parentPID: 1, tty: "ttys001", startedAt: base.addingTimeInterval(started)), cwd)
        }
        let owners = CodexSessionReader.assignProcesses(
            threads: [thread("old", created: 0, updated: 60), thread("new", created: 3000, updated: 3100),
                      thread("elsewhere", created: 10, updated: 20, cwd: "/q")],
            processes: [process(10, started: -1), process(20, started: 2999)]
        )
        XCTAssertEqual(owners["new"], 20)
        XCTAssertEqual(owners["old"], 10)
        XCTAssertNil(owners["elsewhere"])
    }

    func testClaudeAttachTargetMatching() {
        let job = "ce69abdd", session = "ce69abdd-0918-4014-9882-5a297278a914", name = "photo-organizer-design"
        XCTAssertTrue(AgentWindowFocuser.attachTarget("ce69abdd", matchesJob: job, sessionID: session, name: name))
        XCTAssertTrue(AgentWindowFocuser.attachTarget(session, matchesJob: job, sessionID: session, name: name))
        XCTAssertTrue(AgentWindowFocuser.attachTarget("ce69abdd-0918", matchesJob: job, sessionID: session, name: name))
        XCTAssertTrue(AgentWindowFocuser.attachTarget("organizer", matchesJob: job, sessionID: session, name: name))
        XCTAssertFalse(AgentWindowFocuser.attachTarget("5883e5e1", matchesJob: job, sessionID: session, name: name))
        XCTAssertFalse(AgentWindowFocuser.attachTarget("ce", matchesJob: job, sessionID: session, name: name), "too short to be a name part")
    }

    func testCodexRolloutScanFallback() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-home-\(UUID().uuidString)")
        let day = home.appendingPathComponent("sessions/2026/11/08", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let meta = #"{"timestamp":"2026-11-08T08:00:00.000Z","type":"session_meta","payload":{"id":"t-1","cwd":"/Users/me/proj","originator":"codex-tui","timestamp":"2026-11-08T08:00:00.000Z"}}"#
        try (meta + "\n").write(to: day.appendingPathComponent("rollout-2026-11-08T08-00-00-t-1.jsonl"), atomically: true, encoding: .utf8)

        let rows = CodexSessionReader(home: home).rolloutRows(since: Date().addingTimeInterval(-3600))
        XCTAssertEqual(rows.map(\.id), ["t-1"])
        XCTAssertEqual(rows.first?.cwd, "/Users/me/proj")
        XCTAssertEqual(rows.first?.originator, "codex-tui")
    }

    // MARK: Shared pieces

    func testStatuslineSnapshotParsesQuotaAndContext() {
        let parsed = ClaudeStatuslineSnapshot.parse([
            "session_id": "s1",
            "context_window": ["context_window_size": 200_000, "used_percentage": 12],
            "rate_limits": ["five_hour": ["used_percentage": 30, "resets_at": 1_794_140_000],
                            "seven_day": ["used_percentage": 45]],
        ], observedAt: Date())
        XCTAssertEqual(parsed.context.contextWindow, 200_000)
        XCTAssertEqual(parsed.quota?.windows.map(\.label), ["5h", "7d"])
        XCTAssertEqual(parsed.quota?.windows.first?.resetsAt, Date(timeIntervalSince1970: 1_794_140_000))
    }

    func testQuotaWindowLabels() {
        XCTAssertEqual(AgentQuotaWindow.label(forWindowMinutes: 300), "5h")
        XCTAssertEqual(AgentQuotaWindow.label(forWindowMinutes: 10_080), "7d")
        XCTAssertEqual(AgentQuotaWindow.label(forWindowMinutes: 45), "45m")
    }

    func testTailDecodingDropsPartialFirstLine() {
        let data = Data("tial\":1}\n{\"a\":1}\n{\"b\":2}\n".utf8)
        let objects = JSONLTailReader.decodeLines(data, dropFirstPartial: true)
        XCTAssertEqual(objects.count, 2)
        XCTAssertEqual(objects.first?["a"] as? Int, 1)
    }
}

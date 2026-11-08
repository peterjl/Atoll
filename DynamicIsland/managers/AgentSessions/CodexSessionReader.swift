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

import Foundation
import SQLite3

/// What the tail of a Codex rollout (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`) says.
struct CodexRolloutSummary: Equatable {
    /// Derived from the last turn lifecycle event; nil when the tail holds none.
    var state: AgentSessionState? = nil
    var turnStartedAt: Date? = nil
    var lastTurnDuration: TimeInterval? = nil
    var lastPrompt: String? = nil
    var lastSummary: String? = nil
    var steps: [AgentStep] = []
    var model: String? = nil
    var cwd: String? = nil
    var originator: String? = nil
    var contextTokens: Int? = nil
    var contextWindow: Int? = nil
    var sessionTokens: Int? = nil
    var quotaWindows: [AgentQuotaWindow] = []
    var quotaObservedAt: Date? = nil
    var lastEventAt: Date? = nil
}

enum CodexRolloutParser {
    static func parse(_ objects: [[String: Any]], maxSteps: Int = 14) -> CodexRolloutSummary {
        var out = CodexRolloutSummary()
        var steps: [AgentStep] = []
        var awaitingApproval = false

        for obj in objects {
            let timestamp = JSONLTailReader.date(obj["timestamp"])
            if let timestamp { out.lastEventAt = max(out.lastEventAt ?? timestamp, timestamp) }
            guard let payload = obj.dict("payload") else { continue }
            let payloadType = payload.string("type")

            switch obj.string("type") {
            case "session_meta":
                out.cwd = payload.string("cwd") ?? out.cwd
                out.originator = payload.string("originator") ?? out.originator
                continue
            case "turn_context":
                out.model = payload.string("model") ?? out.model
                out.cwd = payload.string("cwd") ?? out.cwd
                continue
            case "event_msg":
                break
            default:
                continue
            }

            switch payloadType {
            case "task_started":
                out.state = .working
                out.turnStartedAt = payload.double("started_at").flatMap(JSONLTailReader.epochDate) ?? timestamp
                if let window = payload.int("model_context_window") { out.contextWindow = window }
                awaitingApproval = false
            case "task_complete":
                out.state = .ready
                awaitingApproval = false
                if let ms = payload.double("duration_ms") { out.lastTurnDuration = ms / 1000 }
                if let message = payload.string("last_agent_message")?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !message.isEmpty {
                    out.lastSummary = ClaudeTranscriptParser.clip(message, limit: 6000)
                }
            case "turn_aborted":
                out.state = .interrupted
                awaitingApproval = false
                if let ms = payload.double("duration_ms") { out.lastTurnDuration = ms / 1000 }
            case "token_count":
                if let info = payload.dict("info") {
                    if let last = info.dict("last_token_usage"), let input = last.int("input_tokens"), input > 0 {
                        out.contextTokens = input
                    }
                    if let total = info.dict("total_token_usage")?.int("total_tokens") { out.sessionTokens = total }
                    if let window = info.int("model_context_window") { out.contextWindow = window }
                }
                if let limits = payload.dict("rate_limits") {
                    let windows = ["primary", "secondary"].compactMap { quotaWindow(limits.dict($0)) }
                    if !windows.isEmpty {
                        out.quotaWindows = windows
                        out.quotaObservedAt = timestamp
                    }
                }
            case "item_completed":
                awaitingApproval = false
                guard let item = payload.dict("item"), let step = step(from: item, timestamp: timestamp) else { continue }
                if step.kind == .prompt { out.lastPrompt = step.text }
                steps.append(step)
            // Older rollouts carry flat events instead of `item_completed`.
            case "user_message":
                if let text = payload.string("message")?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                   !text.hasPrefix("<") {
                    out.lastPrompt = text
                    steps.append(AgentStep(id: "user-\(steps.count)-\(timestamp?.timeIntervalSince1970 ?? 0)",
                                           timestamp: timestamp, kind: .prompt, text: ClaudeTranscriptParser.clip(text)))
                }
            case "agent_message":
                if let text = payload.string("message")?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    steps.append(AgentStep(id: "agent-\(steps.count)-\(timestamp?.timeIntervalSince1970 ?? 0)",
                                           timestamp: timestamp, kind: .commentary, text: ClaudeTranscriptParser.clip(text)))
                }
            default:
                if let payloadType, payloadType.contains("approval_request") || payloadType.contains("elicitation_request") {
                    awaitingApproval = true
                }
            }
        }

        if awaitingApproval, out.state == .working { out.state = .waiting }
        out.steps = Array(steps.suffix(maxSteps))
        return out
    }

    static func quotaWindow(_ window: [String: Any]?) -> AgentQuotaWindow? {
        guard let window, let used = window.double("used_percent") else { return nil }
        let minutes = window.int("window_minutes") ?? 0
        return AgentQuotaWindow(
            label: AgentQuotaWindow.label(forWindowMinutes: minutes),
            usedPercent: used,
            resetsAt: window.double("resets_at").flatMap(JSONLTailReader.epochDate)
        )
    }

    static func step(from item: [String: Any], timestamp: Date?) -> AgentStep? {
        let id = item.string("id") ?? UUID().uuidString
        func texts(_ key: String) -> String? {
            let parts = (item[key] as? [[String: Any]] ?? []).compactMap { $0.string("text") }
            let joined = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }
        switch item.string("type") {
        case "UserMessage":
            guard let text = texts("content"), !text.hasPrefix("<") else { return nil }
            return AgentStep(id: id, timestamp: timestamp, kind: .prompt, text: ClaudeTranscriptParser.clip(text))
        case "AgentMessage":
            guard let text = texts("content") else { return nil }
            let kind: AgentStepKind = item.string("phase") == "final_answer" ? .answer : .commentary
            return AgentStep(id: id, timestamp: timestamp, kind: kind, text: ClaudeTranscriptParser.clip(text))
        case "CommandExecution":
            let parsed = (item["parsed_cmd"] as? [[String: Any]])?.compactMap { $0.string("cmd") }.joined(separator: " && ")
            let raw = (item["command"] as? [String])?.joined(separator: " ") ?? item.string("command")
            let command = (parsed?.isEmpty == false ? parsed : raw) ?? "command"
            var exit = item.int("exit_code")
            if exit == nil, item.string("status") == "failed" { exit = -1 }
            return AgentStep(id: id, timestamp: timestamp, kind: .tool,
                             text: "Shell · \(command.agentPreview(limit: 160))", exitCode: exit)
        case "Extension":
            let query = item.string("query") ?? item.dict("action")?.string("query")
            let kind = item.string("kind") ?? "tool"
            return AgentStep(id: id, timestamp: timestamp, kind: .tool,
                             text: query.map { "\(kind) · \($0.agentPreview(limit: 160))" } ?? kind)
        case "FileChange", "PatchApply":
            let paths = (item["changes"] as? [[String: Any]])?.compactMap { $0.string("path") }
                ?? (item["changes"] as? [String: Any]).map { Array($0.keys) } ?? []
            let names = paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            return AgentStep(id: id, timestamp: timestamp, kind: .tool, text: names.isEmpty ? "Edit files" : "Edit · \(names)")
        default:
            return nil
        }
    }
}

/// Lists recently active Codex threads.
///
/// `~/.codex/state_<n>.sqlite` indexes every thread (cwd, title, rollout path, originator);
/// the rollout log carries turn lifecycle, messages, token counts and rate limits.
final class CodexSessionReader {
    struct ThreadRow: Equatable {
        let id: String
        let rolloutPath: String
        let cwd: String
        let title: String?
        let createdAt: Date?
        let updatedAt: Date
        let originator: String?
        let model: String?
        let gitBranch: String?
    }

    struct Snapshot {
        var sessions: [AgentSession]
        var quota: AgentQuota?
    }

    let home: URL
    private var parsed: [String: (stamp: JSONLTailReader.FileStamp, summary: CodexRolloutSummary)] = [:]
    /// Last successful index read; reused while Codex holds a write lock on its database.
    private var lastRows: [ThreadRow] = []

    init(home: URL = CodexSessionReader.defaultHome()) {
        self.home = home
    }

    static func defaultHome() -> URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    /// - Parameter lookback: threads untouched for longer than this are ignored.
    func snapshot(lookback: TimeInterval, now: Date = Date()) -> Snapshot {
        let cutoff = now.addingTimeInterval(-lookback)
        let rows: [ThreadRow]
        if let fresh = threadRows(since: cutoff) {
            rows = fresh
            lastRows = fresh
        } else {
            rows = lastRows.filter { $0.updatedAt >= cutoff }
        }
        let terminals = AgentProcessInspector.interactiveProcesses(named: "codex")
        let owners = Self.assignProcesses(threads: rows, processes: terminals.map { ($0.info, $0.cwd) })

        var sessions: [AgentSession] = []
        var quota: AgentQuota?
        var keep = Set<String>()
        for row in rows {
            keep.insert(row.rolloutPath)
            let summary = rolloutSummary(path: row.rolloutPath)
            if !summary.quotaWindows.isEmpty,
               (summary.quotaObservedAt ?? .distantPast) > (quota?.observedAt ?? .distantPast) {
                quota = AgentQuota(kind: .codex, windows: summary.quotaWindows, observedAt: summary.quotaObservedAt)
            }

            let originator = row.originator ?? summary.originator ?? ""
            let host: AgentHost
            if Self.isTerminalOriginator(originator) {
                // A terminal thread is only active while its TUI process is.
                guard let pid = owners[row.id] else { continue }
                host = .process(pid: pid)
            } else if originator.lowercased().contains("vscode") {
                host = .editorWorkspace(path: summary.cwd ?? row.cwd)
            } else if Self.isDesktopOriginator(originator) {
                host = .codexDesktop(threadID: row.id)
            } else {
                // `codex exec` and other headless runs: show them only while they run.
                guard summary.state == .working else { continue }
                host = .unknown
            }

            sessions.append(AgentSession(
                kind: .codex,
                sessionID: row.id,
                title: row.title?.agentPreview(limit: 80) ?? summary.lastPrompt?.agentPreview(limit: 60)
                    ?? (row.cwd as NSString).lastPathComponent,
                cwd: summary.cwd ?? row.cwd,
                gitBranch: row.gitBranch,
                model: summary.model ?? row.model,
                state: summary.state ?? .ready,
                lastActivity: max(row.updatedAt, summary.lastEventAt ?? .distantPast),
                turnStartedAt: summary.state == .working ? summary.turnStartedAt : nil,
                lastTurnDuration: summary.lastTurnDuration,
                lastPrompt: summary.lastPrompt,
                lastSummary: summary.lastSummary,
                steps: summary.steps,
                usage: AgentContextUsage(
                    contextTokens: summary.contextTokens,
                    contextWindow: summary.contextWindow,
                    sessionTokens: summary.sessionTokens,
                    sessionCostUSD: nil
                ),
                host: host
            ))
        }
        parsed = parsed.filter { keep.contains($0.key) }
        return Snapshot(sessions: sessions, quota: quota)
    }

    static func isTerminalOriginator(_ originator: String) -> Bool {
        let o = originator.lowercased()
        return o.contains("tui") || o == "codex_cli_rs" || o == "codex-cli"
    }

    static func isDesktopOriginator(_ originator: String) -> Bool {
        let o = originator.lowercased()
        return o.contains("desktop") || o.contains("app")
    }

    /// Pairs each terminal thread with the `codex` process that is running it: same cwd, and the
    /// process started no later than shortly after the thread. Newest threads claim processes first,
    /// so a TUI that started a fresh thread with `/new` only shows that thread.
    static func assignProcesses(threads: [ThreadRow], processes: [(info: AgentProcessInspector.Info, cwd: String?)]) -> [String: Int32] {
        var free = processes
        var owners: [String: Int32] = [:]
        for row in threads.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            guard isTerminalOriginator(row.originator ?? "tui") else { continue }
            let target = standardized(row.cwd)
            let candidates = free.enumerated().filter { standardized($0.element.cwd ?? "") == target }
            guard !candidates.isEmpty else { continue }
            let deadline = (row.createdAt ?? row.updatedAt).addingTimeInterval(120)
            let eligible = candidates.filter { ($0.element.info.startedAt ?? .distantPast) <= deadline }
            let pool = eligible.isEmpty ? candidates : eligible
            guard let pick = pool.max(by: { ($0.element.info.startedAt ?? .distantPast) < ($1.element.info.startedAt ?? .distantPast) })
            else { continue }
            owners[row.id] = pick.element.info.pid
            free.remove(at: pick.offset)
        }
        return owners
    }

    private static func standardized(_ path: String) -> String {
        var p = path
        if p.hasPrefix("file://"), let url = URL(string: p) { p = url.path }
        return (p as NSString).standardizingPath
    }

    private func rolloutSummary(path: String) -> CodexRolloutSummary {
        let url = URL(fileURLWithPath: path)
        guard let stamp = JSONLTailReader.stamp(of: url) else { return CodexRolloutSummary() }
        if let cached = parsed[path], cached.stamp == stamp { return cached.summary }
        var summary = CodexRolloutParser.parse(JSONLTailReader.tailObjects(at: url))
        if summary.cwd == nil || summary.originator == nil {
            let head = CodexRolloutParser.parse(JSONLTailReader.headObjects(at: url, limit: 4))
            summary.cwd = summary.cwd ?? head.cwd
            summary.originator = summary.originator ?? head.originator
            summary.model = summary.model ?? head.model
        }
        parsed[path] = (stamp, summary)
        return summary
    }

    // MARK: Thread index

    func databaseURL() -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil) else {
            return nil
        }
        // state_5.sqlite today; pick the highest schema generation present.
        return files
            .filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
            .max { Self.generation($0) < Self.generation($1) }
    }

    private static func generation(_ url: URL) -> Int {
        Int(url.deletingPathExtension().lastPathComponent.dropFirst("state_".count)) ?? 0
    }

    /// Recently updated threads, newest first; nil when the index could not be read (busy, missing, changed schema).
    func threadRows(since cutoff: Date, limit: Int = 40) -> [ThreadRow]? {
        guard let dbURL = databaseURL() else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)

        let columns = Self.columns(of: "threads", in: db)
        guard columns.isSuperset(of: ["id", "rollout_path", "cwd", "updated_at"]) else { return nil }
        func optional(_ name: String) -> String { columns.contains(name) ? name : "NULL" }
        let title = columns.contains("name") ? "COALESCE(NULLIF(name, ''), \(optional("title")))" : optional("title")
        var filters = ["updated_at >= ?"]
        if columns.contains("archived") { filters.append("archived = 0") }
        if Self.tableExists("thread_spawn_edges", in: db) {
            filters.append("id NOT IN (SELECT child_thread_id FROM thread_spawn_edges)")
        }
        let sql = """
            SELECT id, rollout_path, cwd, \(title), \(optional("created_at")), updated_at,
                   \(optional("originator")), \(optional("model")), \(optional("git_branch"))
            FROM threads WHERE \(filters.joined(separator: " AND "))
            ORDER BY updated_at DESC LIMIT \(limit)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(cutoff.timeIntervalSince1970))

        func text(_ index: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, index) else { return nil }
            let s = String(cString: c)
            return s.isEmpty ? nil : s
        }
        func date(_ index: Int32) -> Date? {
            guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
            return JSONLTailReader.epochDate(sqlite3_column_double(stmt, index))
        }

        var rows: [ThreadRow] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            if let id = text(0), let rollout = text(1), let cwd = text(2), let updated = date(5) {
                rows.append(ThreadRow(id: id, rolloutPath: rollout, cwd: cwd, title: text(3), createdAt: date(4),
                                      updatedAt: updated, originator: text(6), model: text(7), gitBranch: text(8)))
            }
            rc = sqlite3_step(stmt)
        }
        // SQLITE_BUSY / SQLITE_LOCKED mid-read: report failure so callers keep the previous list.
        return rc == SQLITE_DONE ? rows : nil
    }

    private static func columns(of table: String, in db: OpaquePointer) -> Set<String> {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        var names = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 1) { names.insert(String(cString: c)) }
        }
        return names
    }

    private static func tableExists(_ table: String, in db: OpaquePointer) -> Bool {
        var stmt: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, table, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(stmt) == SQLITE_ROW
    }
}

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

/// What the tail of a Claude Code transcript (`~/.claude/projects/<slug>/<session>.jsonl`) says.
struct ClaudeTranscriptSummary: Equatable {
    var title: String? = nil
    var customTitle: String? = nil
    var lastPrompt: String? = nil
    var lastSummary: String? = nil
    var steps: [AgentStep] = []
    var model: String? = nil
    var gitBranch: String? = nil
    var contextTokens: Int? = nil
    var sessionCostUSD: Double? = nil
    var lastTurnDuration: TimeInterval? = nil
    var turnStartedAt: Date? = nil
    var lastEventAt: Date? = nil
    /// A prompt arrived after the last finished turn.
    var turnInProgress = false
    /// The last turn ended with Claude Code's "[Request interrupted …]" marker.
    var interrupted = false
}

enum ClaudeTranscriptParser {
    static func parse(_ objects: [[String: Any]], maxSteps: Int = 14) -> ClaudeTranscriptSummary {
        var out = ClaudeTranscriptSummary()
        var steps: [AgentStep] = []

        for obj in objects {
            let type = obj.string("type")
            switch type {
            case "ai-title":
                if let t = obj.string("aiTitle"), !t.isEmpty { out.title = t }
                continue
            case "custom-title":
                if let t = obj.string("customTitle"), !t.isEmpty { out.customTitle = t }
                continue
            case "summary":
                if out.title == nil, let t = obj.string("summary"), !t.isEmpty { out.title = t }
                continue
            case "last-prompt":
                if let p = obj.string("lastPrompt"), !p.isEmpty { out.lastPrompt = p }
                continue
            case "cost-state":
                if let cost = obj.double("totalCostUSD") { out.sessionCostUSD = cost }
                continue
            default:
                break
            }

            // Subagent traffic is interleaved in some versions; keep the main thread only.
            guard !obj.bool("isSidechain") else { continue }
            let timestamp = JSONLTailReader.date(obj["timestamp"])
            if let timestamp { out.lastEventAt = max(out.lastEventAt ?? timestamp, timestamp) }
            if let branch = obj.string("gitBranch"), !branch.isEmpty, branch != "HEAD" { out.gitBranch = branch }
            let uuid = obj.string("uuid") ?? UUID().uuidString

            switch type {
            case "user":
                guard !obj.bool("isMeta"), let message = obj.dict("message"),
                      let text = promptText(message["content"]) else { continue }
                if text.hasPrefix("[Request interrupted") {
                    out.interrupted = true
                    out.turnInProgress = false
                    continue
                }
                out.lastPrompt = text
                out.turnStartedAt = timestamp
                out.turnInProgress = true
                out.interrupted = false
                steps.append(AgentStep(id: uuid, timestamp: timestamp, kind: .prompt, text: clip(text)))

            case "assistant":
                guard let message = obj.dict("message") else { continue }
                if let model = message.string("model"), !model.hasPrefix("<") { out.model = model }
                if let usage = message.dict("usage") {
                    let prompt = (usage.int("input_tokens") ?? 0)
                        + (usage.int("cache_read_input_tokens") ?? 0)
                        + (usage.int("cache_creation_input_tokens") ?? 0)
                    if prompt > 0 { out.contextTokens = prompt }
                }
                let endsTurn = message.string("stop_reason") == "end_turn"
                let blocks = message["content"] as? [[String: Any]] ?? []
                for (index, block) in blocks.enumerated() {
                    let stepID = "\(uuid)#\(index)"
                    switch block.string("type") {
                    case "text":
                        guard let text = block.string("text")?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !text.isEmpty else { continue }
                        steps.append(AgentStep(id: stepID, timestamp: timestamp,
                                               kind: endsTurn ? .answer : .commentary, text: clip(text)))
                        if endsTurn { out.lastSummary = clip(text, limit: 6000) }
                    case "tool_use":
                        let name = block.string("name") ?? "Tool"
                        steps.append(AgentStep(id: stepID, timestamp: timestamp, kind: .tool,
                                               text: describeTool(name, block.dict("input") ?? [:])))
                    default:
                        continue
                    }
                }
                if endsTurn { out.turnInProgress = false }

            case "system":
                if obj.string("subtype") == "turn_duration" {
                    if let ms = obj.double("durationMs") { out.lastTurnDuration = ms / 1000 }
                    out.turnInProgress = false
                }

            default:
                continue
            }
        }

        out.steps = Array(steps.suffix(maxSteps))
        return out
    }

    /// The text the user typed, or nil for tool results and harness-injected messages.
    static func promptText(_ content: Any?) -> String? {
        var text: String?
        if let s = content as? String {
            text = s
        } else if let blocks = content as? [[String: Any]] {
            guard !blocks.contains(where: { $0.string("type") == "tool_result" }) else { return nil }
            let parts = blocks.compactMap { $0.string("type") == "text" ? $0.string("text") : nil }
            text = parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        // Slash-command echoes, hook output and reminders are wrapped in XML-ish tags.
        if trimmed.hasPrefix("<") { return nil }
        return trimmed
    }

    static func describeTool(_ name: String, _ input: [String: Any]) -> String {
        func file(_ key: String) -> String? {
            input.string(key).map { ($0 as NSString).lastPathComponent }
        }
        let detail: String?
        switch name {
        case "Bash":
            detail = input.string("description") ?? input.string("command")
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit":
            detail = file("file_path") ?? file("notebook_path")
        case "Grep", "Glob":
            detail = input.string("pattern")
        case "Agent", "Task":
            detail = input.string("description")
        case "WebFetch":
            detail = input.string("url")
        case "WebSearch":
            detail = input.string("query")
        default:
            detail = input.string("description")
        }
        guard let detail, !detail.isEmpty else { return name }
        return "\(name) · \(detail.agentPreview(limit: 160))"
    }

    static func clip(_ text: String, limit: Int = 1200) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}

/// Lists the Claude Code sessions that are running right now.
///
/// Claude Code keeps one registry file per live process in `~/.claude/sessions/<pid>.json`
/// (session id, cwd, kind, and a `busy`/`idle` status); the transcript holds the rest.
final class ClaudeSessionReader {
    let home: URL
    private var transcriptURLs: [String: URL] = [:]
    private var parsed: [URL: (stamp: JSONLTailReader.FileStamp, summary: ClaudeTranscriptSummary)] = [:]

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")) {
        self.home = home
    }

    struct RegistryEntry: Equatable {
        let pid: Int32
        let sessionID: String
        let cwd: String
        let kind: String?
        let status: String?
        let name: String?
        let nameIsAutomatic: Bool
        let jobID: String?
        let updatedAt: Date?
        let startedAt: Date?
    }

    func registryEntries() -> [RegistryEntry] {
        let dir = home.appendingPathComponent("sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            return Self.registryEntry(from: obj)
        }
    }

    static func registryEntry(from obj: [String: Any]) -> RegistryEntry? {
        guard let pid = obj.int("pid"), let sessionID = obj.string("sessionId"), let cwd = obj.string("cwd") else {
            return nil
        }
        return RegistryEntry(
            pid: Int32(pid),
            sessionID: sessionID,
            cwd: cwd,
            kind: obj.string("kind"),
            status: obj.string("status"),
            name: obj.string("name"),
            nameIsAutomatic: obj.string("nameSource") == "auto",
            jobID: obj.string("jobId"),
            updatedAt: obj.double("updatedAt").flatMap(JSONLTailReader.epochDate),
            startedAt: obj.double("startedAt").flatMap(JSONLTailReader.epochDate)
        )
    }

    func sessions() -> [AgentSession] {
        let live = registryEntries().filter { AgentProcessInspector.isAlive($0.pid) }
        // A process can re-register after `/clear`; keep one row per session id.
        var bySession: [String: RegistryEntry] = [:]
        for entry in live {
            if let existing = bySession[entry.sessionID],
               (existing.updatedAt ?? .distantPast) >= (entry.updatedAt ?? .distantPast) { continue }
            bySession[entry.sessionID] = entry
        }
        let sessions = bySession.values.map(makeSession)
        let liveURLs = Set(sessions.compactMap { transcriptURLs[$0.sessionID] })
        parsed = parsed.filter { liveURLs.contains($0.key) }
        return sessions
    }

    private func makeSession(_ entry: RegistryEntry) -> AgentSession {
        let summary = transcriptURL(for: entry).map(summary(for:)) ?? ClaudeTranscriptSummary()
        let state = Self.state(status: entry.status, summary: summary)
        let title = summary.customTitle
            ?? (entry.nameIsAutomatic ? nil : entry.name)
            ?? summary.title
            ?? entry.name
            ?? summary.lastPrompt?.agentPreview(limit: 60)
            ?? (entry.cwd as NSString).lastPathComponent
        let lastActivity = [entry.updatedAt, summary.lastEventAt, entry.startedAt].compactMap { $0 }.max() ?? Date()
        let host: AgentHost = entry.kind == "bg"
            ? .claudeBackgroundJob(id: entry.jobID ?? entry.sessionID)
            : .process(pid: entry.pid)

        return AgentSession(
            kind: .claude,
            sessionID: entry.sessionID,
            title: title,
            cwd: entry.cwd,
            gitBranch: summary.gitBranch,
            model: summary.model,
            state: state,
            lastActivity: lastActivity,
            turnStartedAt: state == .working ? summary.turnStartedAt : nil,
            lastTurnDuration: summary.lastTurnDuration,
            lastPrompt: summary.lastPrompt,
            lastSummary: summary.lastSummary,
            steps: summary.steps,
            usage: AgentContextUsage(
                contextTokens: summary.contextTokens,
                contextWindow: Self.contextWindow(forModel: summary.model),
                sessionTokens: nil,
                sessionCostUSD: summary.sessionCostUSD
            ),
            host: host
        )
    }

    static func state(status: String?, summary: ClaudeTranscriptSummary) -> AgentSessionState {
        guard let status = status?.lowercased() else {
            if summary.turnInProgress { return .working }
            return summary.interrupted ? .interrupted : .ready
        }
        if status == "busy" || status == "running" || status == "working" { return .working }
        if ["wait", "block", "requires", "permission", "action", "input"].contains(where: status.contains) {
            return .waiting
        }
        return summary.interrupted ? .interrupted : .ready
    }

    /// Context size is not in the transcript; `[1m]` model ids are the only hint. The
    /// statusline snapshot (see `ClaudeStatuslineSnapshot`) fills it in when available.
    static func contextWindow(forModel model: String?) -> Int? {
        guard let model else { return nil }
        return model.contains("[1m]") ? 1_000_000 : nil
    }

    private func transcriptURL(for entry: RegistryEntry) -> URL? {
        if let cached = transcriptURLs[entry.sessionID], FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        let projects = home.appendingPathComponent("projects")
        let fileName = "\(entry.sessionID).jsonl"
        let direct = projects.appendingPathComponent(Self.projectSlug(for: entry.cwd)).appendingPathComponent(fileName)
        var found: URL? = FileManager.default.fileExists(atPath: direct.path) ? direct : nil
        if found == nil, let dirs = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) {
            found = dirs.map { $0.appendingPathComponent(fileName) }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        }
        if let found { transcriptURLs[entry.sessionID] = found }
        return found
    }

    /// Claude Code names project folders after the cwd with every non-alphanumeric character replaced by "-".
    static func projectSlug(for cwd: String) -> String {
        String(cwd.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" })
    }

    private func summary(for url: URL) -> ClaudeTranscriptSummary {
        guard let stamp = JSONLTailReader.stamp(of: url) else { return ClaudeTranscriptSummary() }
        if let cached = parsed[url], cached.stamp == stamp { return cached.summary }
        var summary = ClaudeTranscriptParser.parse(JSONLTailReader.tailObjects(at: url))
        // The AI title and cost are written early and may have scrolled out of the tail window.
        if summary.title == nil || summary.sessionCostUSD == nil, stamp.size > 768 * 1024 {
            let wide = ClaudeTranscriptParser.parse(JSONLTailReader.tailObjects(at: url, maxBytes: 4 * 1024 * 1024))
            summary.title = summary.title ?? wide.title
            summary.customTitle = summary.customTitle ?? wide.customTitle
            summary.sessionCostUSD = summary.sessionCostUSD ?? wide.sessionCostUSD
        }
        parsed[url] = (stamp, summary)
        return summary
    }
}

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

/// A coding-agent CLI whose local session files Atoll can read.
enum AgentKind: String, CaseIterable, Codable, Sendable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }
}

enum AgentSessionState: String, Equatable, Sendable {
    /// A turn is in progress.
    case working
    /// The agent is blocked on the user (permission / approval prompt). Best effort.
    case waiting
    /// The last turn finished; the agent is waiting for the next prompt.
    case ready
    /// The last turn was interrupted by the user or failed.
    case interrupted

    /// True when the agent no longer needs anything from the session to make progress.
    var needsAttention: Bool { self == .ready || self == .waiting || self == .interrupted }
}

enum AgentStepKind: String, Equatable, Sendable {
    case prompt
    case commentary
    case tool
    case answer
}

/// One entry of the "what has the agent been doing" timeline.
struct AgentStep: Identifiable, Equatable, Sendable {
    let id: String
    let timestamp: Date?
    let kind: AgentStepKind
    let text: String
    /// Exit status for shell commands, when the log records one.
    var exitCode: Int? = nil
}

struct AgentContextUsage: Equatable, Sendable {
    /// Prompt tokens of the most recent model request: how full the context is.
    var contextTokens: Int? = nil
    var contextWindow: Int? = nil
    /// Tokens consumed by the whole session so far.
    var sessionTokens: Int? = nil
    /// Cost as computed by the agent itself (Claude Code records this).
    var sessionCostUSD: Double? = nil

    var contextFraction: Double? {
        guard let contextTokens, let contextWindow, contextWindow > 0 else { return nil }
        return min(1, Double(contextTokens) / Double(contextWindow))
    }
}

struct AgentQuotaWindow: Identifiable, Equatable, Sendable {
    /// Short label derived from the window length, e.g. "5h" or "7d".
    let label: String
    let usedPercent: Double
    let resetsAt: Date?
    var id: String { label }

    static func label(forWindowMinutes minutes: Int) -> String {
        if minutes > 0, minutes % 1440 == 0 { return "\(minutes / 1440)d" }
        if minutes > 0, minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }
}

struct AgentQuota: Equatable, Sendable {
    let kind: AgentKind
    var windows: [AgentQuotaWindow]
    /// When the agent last reported these numbers.
    var observedAt: Date?
}

/// Where a session is running, so Atoll can bring it to the front.
enum AgentHost: Equatable, Sendable {
    /// A CLI process attached to a terminal or editor; resolved through its ancestry when clicked.
    case process(pid: Int32)
    /// A Claude Code background session (`claude --bg`). An open `claude attach` client is focused if one
    /// exists; otherwise a new terminal runs `claude attach <id>`.
    case claudeBackgroundJob(id: String, sessionID: String, name: String?)
    /// A thread of the Codex desktop app, reachable with a `codex://threads/<id>` link.
    case codexDesktop(threadID: String)
    /// A session hosted by an editor extension; the editor window for `path` is brought forward.
    case editorWorkspace(path: String)
    case unknown
}

struct AgentSession: Identifiable, Equatable, Sendable {
    let kind: AgentKind
    let sessionID: String
    var title: String
    var cwd: String
    var gitBranch: String? = nil
    var model: String? = nil
    var state: AgentSessionState
    var lastActivity: Date
    var turnStartedAt: Date? = nil
    var lastTurnDuration: TimeInterval? = nil
    var lastPrompt: String? = nil
    var lastSummary: String? = nil
    /// Most recent steps, oldest first.
    var steps: [AgentStep] = []
    var usage = AgentContextUsage()
    var host: AgentHost = .unknown

    var id: String { "\(kind.rawValue):\(sessionID)" }
    var projectName: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }
}

extension String {
    /// Collapses whitespace and trims to `limit` characters for single-line previews.
    func agentPreview(limit: Int = 400) -> String {
        // Agents answer in Markdown; bold markers are noise in a one-line preview.
        let collapsed = replacingOccurrences(of: "**", with: "")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }
}

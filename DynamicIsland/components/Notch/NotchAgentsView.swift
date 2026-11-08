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

import Defaults
import SwiftUI

/// Live Claude Code / Codex sessions: status, latest step or answer, context and quota.
/// Tapping a row brings the session's terminal or editor window to the front.
struct NotchAgentsView: View {
    static let preferredHeight: CGFloat = 250

    @EnvironmentObject var vm: DynamicIslandViewModel
    @ObservedObject private var manager = AgentSessionsManager.shared
    @State private var expandedID: String?
    @State private var hoveredID: String?
    @State private var suppressionToken = UUID()
    @State private var isSuppressing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if manager.sessions.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 4) {
                        ForEach(manager.sessions) { session in
                            AgentSessionRow(
                                session: session,
                                isExpanded: expandedID == session.id,
                                isHovered: hoveredID == session.id,
                                onFocus: { manager.focus(session) },
                                onToggleExpand: {
                                    withAnimation(.smooth(duration: 0.25)) {
                                        expandedID = expandedID == session.id ? nil : session.id
                                    }
                                }
                            )
                            .onHover { hovering in
                                if hovering { hoveredID = session.id } else if hoveredID == session.id { hoveredID = nil }
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .onAppear { manager.setVisible(true) }
        .onDisappear {
            manager.setVisible(false)
            updateSuppression(for: false)
        }
        .onHover { updateSuppression(for: $0) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ForEach(AgentKind.allCases, id: \.self) { kind in
                if let quota = manager.quotas[kind] {
                    AgentQuotaChip(quota: quota)
                }
            }
            Spacer(minLength: 4)
            if let message = manager.focusMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(summaryLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(height: 18)
    }

    private var summaryLine: String {
        let working = manager.sessions.filter { $0.state == .working }.count
        let waiting = manager.sessions.filter { $0.state == .waiting }.count
        var parts = ["\(manager.sessions.count) active"]
        if working > 0 { parts.append("\(working) working") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        return parts.joined(separator: " · ")
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("No active Claude Code or Codex sessions")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func updateSuppression(for hovering: Bool) {
        guard hovering != isSuppressing else { return }
        isSuppressing = hovering
        vm.setScrollGestureSuppression(hovering, token: suppressionToken)
    }
}

// MARK: - Row

struct AgentSessionRow: View {
    let session: AgentSession
    let isExpanded: Bool
    let isHovered: Bool
    let onFocus: () -> Void
    let onToggleExpand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                AgentKindBadge(kind: session.kind, state: session.state)
                VStack(alignment: .leading, spacing: 2) {
                    titleLine
                    Text(previewText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 6)
                trailing
            }
            if isExpanded {
                AgentSessionDetail(session: session)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(isHovered ? 0.11 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(session.state.tint.opacity(highlightBorder ? 0.35 : 0), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onFocus)
        .help(jumpHelp)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(session.kind.displayName) \(session.title), \(session.state.label)")
    }

    /// Only fresh results get the colored outline, so a session finished yesterday doesn't compete for attention.
    private var highlightBorder: Bool {
        session.state == .waiting
            || (session.state.needsAttention && Date().timeIntervalSince(session.lastActivity) < 1800)
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            Text(session.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(projectLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(-1)
        }
    }

    private var projectLabel: String {
        [session.projectName, session.gitBranch].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var previewText: String {
        switch session.state {
        case .working:
            let latest = session.steps.last { $0.kind != .prompt }
            return (latest?.text ?? session.lastPrompt ?? "Working…").agentPreview(limit: 240)
        case .waiting:
            return "Waiting for your approval"
        case .ready, .interrupted:
            return (session.lastSummary ?? session.steps.last?.text ?? session.lastPrompt ?? "Ready").agentPreview(limit: 240)
        }
    }

    private var jumpHelp: String {
        switch session.host {
        case .claudeBackgroundJob: return "Jump to its terminal (opens claude attach if none is open)"
        case .codexDesktop: return "Open in Codex"
        case .editorWorkspace: return "Open the editor window"
        case .process: return "Jump to this session's window"
        case .unknown: return "No window to jump to"
        }
    }

    private var trailing: some View {
        HStack(spacing: 8) {
            VStack(alignment: .trailing, spacing: 3) {
                AgentStateLabel(session: session)
                if let fraction = session.usage.contextFraction {
                    AgentContextBar(fraction: fraction, label: contextLabel)
                } else if let tokens = session.usage.contextTokens {
                    Text("ctx \(AgentFormat.tokens(tokens))")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Button(action: onToggleExpand) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(isExpanded ? "Hide steps" : "Show recent steps")
        }
    }

    private var contextLabel: String {
        guard let tokens = session.usage.contextTokens, let window = session.usage.contextWindow else { return "" }
        return "\(AgentFormat.tokens(tokens))/\(AgentFormat.tokens(window))"
    }
}

private struct AgentSessionDetail: View {
    let session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(session.steps.suffix(6)) { step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: step.kind.symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(step.exitCode.map { $0 == 0 ? Color.secondary : .red } ?? step.kind.tint)
                        .frame(width: 12)
                    Text(step.text.agentPreview(limit: 300))
                        .font(.system(size: 11))
                        .foregroundStyle(step.kind == .answer ? .white : .secondary)
                        .lineLimit(step.kind == .answer ? 4 : 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let summary = session.lastSummary, session.steps.last?.kind != .answer {
                Divider().opacity(0.3)
                Text(summary.agentPreview(limit: 600))
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .lineLimit(4)
            }
            footer
        }
        .padding(.leading, 30)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let model = session.model { Label(model, systemImage: "cpu").lineLimit(1) }
            if let total = session.usage.sessionTokens { Text("\(AgentFormat.tokens(total)) tokens") }
            if let cost = session.usage.sessionCostUSD, cost > 0 { Text(AgentFormat.money(cost)) }
            if let duration = session.lastTurnDuration, session.state != .working {
                Text("last turn \(AgentFormat.duration(duration))")
            }
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .padding(.top, 2)
    }
}

// MARK: - Pieces

private struct AgentKindBadge: View {
    let kind: AgentKind
    let state: AgentSessionState

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            AgentLogo(kind: kind, size: 15)
                .frame(width: 24, height: 24)
                .background(kind.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Circle()
                .fill(state.tint)
                .frame(width: 7, height: 7)
                .overlay(Circle().stroke(.black, lineWidth: 1.5))
                .offset(x: 2, y: 2)
        }
    }
}

private struct AgentStateLabel: View {
    let session: AgentSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 4) {
                if session.state == .working {
                    ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
                }
                Text(text(now: context.date))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(session.state.tint)
            .monospacedDigit()
        }
    }

    private func text(now: Date) -> String {
        switch session.state {
        case .working:
            guard let started = session.turnStartedAt else { return "Working" }
            return AgentFormat.duration(now.timeIntervalSince(started))
        case .waiting:
            return "Needs input"
        case .ready, .interrupted:
            return "\(session.state.label) · \(AgentFormat.ago(now.timeIntervalSince(session.lastActivity)))"
        }
    }
}

private struct AgentContextBar: View {
    let fraction: Double
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Capsule()
                .fill(.white.opacity(0.15))
                .frame(width: 36, height: 3)
                .overlay(alignment: .leading) {
                    Capsule().fill(tint).frame(width: max(2, 36 * fraction), height: 3)
                }
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .help("Context window used")
    }

    private var tint: Color { fraction > 0.85 ? .red : fraction > 0.6 ? .orange : .accentColor }
}

struct AgentQuotaChip: View {
    let quota: AgentQuota

    var body: some View {
        HStack(spacing: 5) {
            AgentLogo(kind: quota.kind, size: 11)
            ForEach(quota.windows) { window in
                HStack(spacing: 2) {
                    Text(window.label).foregroundStyle(.secondary)
                    Text("\(Int(window.usedPercent.rounded()))%")
                        .foregroundStyle(window.usedPercent >= 90 ? .red : window.usedPercent >= 70 ? .orange : .white)
                }
                .help(resetHelp(window))
            }
        }
        .font(.system(size: 10, weight: .medium))
        .monospacedDigit()
    }

    private func resetHelp(_ window: AgentQuotaWindow) -> String {
        guard let resets = window.resetsAt, resets > Date() else { return "\(quota.kind.displayName) \(window.label) window" }
        return "\(quota.kind.displayName) \(window.label) window resets in \(AgentFormat.duration(resets.timeIntervalSinceNow))"
    }
}

// MARK: - Styling

private extension AgentKind {
    /// Claude orange (#D97757) and the middle stop of Codex's violet-to-blue gradient (#7A9DFF).
    var tint: Color {
        switch self {
        case .claude: return Color(red: 0.851, green: 0.467, blue: 0.341)
        case .codex: return Color(red: 0.478, green: 0.616, blue: 1.0)
        }
    }

    var logoAsset: String {
        switch self {
        case .claude: return "AgentLogoClaudeCode"
        case .codex: return "AgentLogoCodex"
        }
    }
}

/// The official marks: Claude Code's pixel glyph tinted Claude orange, and Codex's own app icon
/// artwork (from the Codex app) shown in its original colors.
struct AgentLogo: View {
    let kind: AgentKind
    var size: CGFloat = 15

    var body: some View {
        switch kind {
        case .claude:
            Image(kind.logoAsset)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .foregroundStyle(kind.tint)
                .accessibilityLabel(kind.displayName)
        case .codex:
            // The Codex app icon's cloud, cut out of its white tile; slightly larger to match the glyph's weight.
            Image(kind.logoAsset)
                .renderingMode(.original)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size * 1.1, height: size * 1.1)
                .frame(width: size, height: size)
                .accessibilityLabel(kind.displayName)
        }
    }
}

private extension AgentSessionState {
    var tint: Color {
        switch self {
        case .working: return .blue
        case .waiting: return .orange
        case .ready: return .green
        case .interrupted: return .red
        }
    }

    var label: String {
        switch self {
        case .working: return "Working"
        case .waiting: return "Needs input"
        case .ready: return "Ready"
        case .interrupted: return "Stopped"
        }
    }
}

private extension AgentStepKind {
    var symbol: String {
        switch self {
        case .prompt: return "person.fill"
        case .commentary: return "text.bubble"
        case .tool: return "hammer.fill"
        case .answer: return "checkmark.seal.fill"
        }
    }

    var tint: Color {
        switch self {
        case .prompt: return .white
        case .commentary: return .secondary
        case .tool: return .secondary
        case .answer: return .green
        }
    }
}

enum AgentFormat {
    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
        case 1_000...: return "\(n / 1000)k"
        default: return "\(n)"
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s >= 86_400 { return "\(s / 86_400)d \(s % 86_400 / 3600)h" }
        if s >= 3600 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        if s >= 60 { return "\(s / 60)m \(s % 60)s" }
        return "\(s)s"
    }

    static func ago(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86_400 { return "\(s / 3600)h ago" }
        return "\(s / 86_400)d ago"
    }

    static func money(_ value: Double) -> String {
        String(format: value < 1 ? "$%.3f" : "$%.2f", value)
    }
}

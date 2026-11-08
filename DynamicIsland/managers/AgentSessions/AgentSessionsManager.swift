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

import Combine
import Defaults
import Foundation
import SwiftUI

/// Owns the session readers. They cache parsed files and are not thread-safe, so every call
/// goes through one serial queue.
private final class AgentSessionsWorker: @unchecked Sendable {
    struct Options: Sendable {
        var showClaude: Bool
        var showCodex: Bool
        var codexLookback: TimeInterval
    }

    struct Output: Sendable {
        var sessions: [AgentSession]
        var claudeQuota: AgentQuota?
        var codexQuota: AgentQuota?
    }

    private let queue = DispatchQueue(label: "com.atoll.agent-sessions", qos: .utility)
    private let claude = ClaudeSessionReader()
    private let codex = CodexSessionReader()

    func read(_ options: Options) async -> Output {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                var output = Output(sessions: [], claudeQuota: nil, codexQuota: nil)
                if options.showClaude {
                    let statusline = ClaudeStatuslineSnapshot.read()
                    output.claudeQuota = statusline.quota
                    output.sessions += claude.sessions().map { session in
                        var session = session
                        if let context = statusline.contexts[session.sessionID] {
                            session.usage.contextWindow = context.contextWindow ?? session.usage.contextWindow
                            session.usage.sessionCostUSD = session.usage.sessionCostUSD ?? context.costUSD
                        }
                        return session
                    }
                }
                if options.showCodex {
                    let snapshot = codex.snapshot(lookback: options.codexLookback)
                    output.codexQuota = snapshot.quota
                    output.sessions += snapshot.sessions
                }
                continuation.resume(returning: output)
            }
        }
    }
}

@MainActor
final class AgentSessionsManager: ObservableObject {
    static let shared = AgentSessionsManager()

    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var quotas: [AgentKind: AgentQuota] = [:]
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var focusMessage: String?

    /// The session named by the most recent "ready" sneak peek; tapping the closed notch focuses it.
    private(set) var announcedSession: AgentSession?

    private let worker = AgentSessionsWorker()
    private var timer: Timer?
    private var visibleViews = 0
    private var isRefreshing = false
    private var previousStates: [String: AgentSessionState] = [:]
    private var hasBaseline = false
    private var cancellables = Set<AnyCancellable>()
    private var focusMessageTask: Task<Void, Never>?

    private static let visibleInterval: TimeInterval = 2
    private static let backgroundInterval: TimeInterval = 5

    private init() {}

    /// Starts or stops polling as the feature toggle changes. Call once at launch.
    func bootstrap() {
        guard cancellables.isEmpty else { return }
        Defaults.publisher(.enableAgentSessionsFeature)
            .map(\.newValue)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in enabled ? self?.start() : self?.stop() }
            .store(in: &cancellables)
        Defaults.publisher(keys: .agentSessionsShowClaude, .agentSessionsShowCodex, .agentSessionsCodexLookbackHours)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    func start() {
        scheduleTimer()
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        sessions = []
        quotas = [:]
        previousStates = [:]
        hasBaseline = false
        announcedSession = nil
    }

    /// Views showing the list call this so polling speeds up while someone is looking.
    func setVisible(_ visible: Bool) {
        visibleViews = max(0, visibleViews + (visible ? 1 : -1))
        guard Defaults[.enableAgentSessionsFeature] else { return }
        scheduleTimer()
        if visible { refresh() }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = visibleViews > 0 ? Self.visibleInterval : Self.backgroundInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = interval * 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        guard Defaults[.enableAgentSessionsFeature], !isRefreshing else { return }
        isRefreshing = true
        let options = AgentSessionsWorker.Options(
            showClaude: Defaults[.agentSessionsShowClaude],
            showCodex: Defaults[.agentSessionsShowCodex],
            codexLookback: max(0.25, Defaults[.agentSessionsCodexLookbackHours]) * 3600
        )
        Task {
            let output = await worker.read(options)
            apply(output)
            isRefreshing = false
        }
    }

    private func apply(_ output: AgentSessionsWorker.Output) {
        let now = Date()
        let sorted = output.sessions.sorted { lhs, rhs in
            let l = Self.rank(lhs, now: now), r = Self.rank(rhs, now: now)
            return l != r ? l < r : lhs.lastActivity > rhs.lastActivity
        }
        announceTransitions(in: sorted)
        if sorted != sessions { sessions = sorted }

        var quotas: [AgentKind: AgentQuota] = [:]
        if let claude = output.claudeQuota ?? Self.usagePanelQuota(.claude) { quotas[.claude] = claude }
        if let codex = output.codexQuota ?? Self.usagePanelQuota(.codex) { quotas[.codex] = codex }
        if quotas != self.quotas { self.quotas = quotas }
        lastRefresh = now
    }

    /// Waiting first, then turns that finished in the last half hour, then running turns, then the rest.
    private static func rank(_ session: AgentSession, now: Date) -> Int {
        switch session.state {
        case .waiting: return 0
        case .ready, .interrupted: return now.timeIntervalSince(session.lastActivity) < 1800 ? 1 : 3
        case .working: return 2
        }
    }

    /// Falls back to the quota the LLM Usage panel already fetched, without triggering a request.
    private static func usagePanelQuota(_ kind: AgentKind) -> AgentQuota? {
        let provider: ProviderID = kind == .claude ? .claude : .codex
        guard case .success(let snapshot)? = LLMUsageManager.shared.results[provider] else { return nil }
        let windows = [("5h", snapshot.sessionLimit), ("7d", snapshot.weekLimit)].compactMap { label, limit in
            limit.map { AgentQuotaWindow(label: label, usedPercent: $0.fraction * 100, resetsAt: $0.resetsAt) }
        }
        return windows.isEmpty ? nil : AgentQuota(kind: kind, windows: windows, observedAt: snapshot.lastUpdated)
    }

    // MARK: Ready notifications

    private func announceTransitions(in sessions: [AgentSession]) {
        defer {
            previousStates = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.state) })
            hasBaseline = true
        }
        guard hasBaseline, Defaults[.agentSessionsNotifyOnReady] else { return }
        let finished = sessions.filter { previousStates[$0.id] == .working && $0.state != .working }
        guard let session = finished.first else { return }
        announcedSession = session
        let name = session.kind.displayName
        let (title, icon, color): (String, String, Color) = switch session.state {
        case .waiting: (String(localized: "\(name) needs you"), "hand.raised.fill", .orange)
        case .interrupted: (String(localized: "\(name) stopped"), "stop.circle.fill", .red)
        default: (String(localized: "\(name) is ready"), "checkmark.circle.fill", .green)
        }
        DynamicIslandViewCoordinator.shared.toggleSneakPeek(
            status: true,
            type: .agentSession,
            duration: Defaults[.agentSessionsSneakPeekDuration],
            icon: icon,
            title: title,
            subtitle: session.title,
            accentColor: color
        )
    }

    // MARK: Focus

    func focus(_ session: AgentSession) {
        Task {
            let outcome = await AgentWindowFocuser.focus(session)
            if case .failed(let message) = outcome { showFocusMessage(message) }
        }
    }

    /// Called when the closed notch is tapped while the agent sneak peek is showing.
    func focusAnnouncedSession() -> Bool {
        guard let session = announcedSession else { return false }
        announcedSession = nil
        focus(sessions.first { $0.id == session.id } ?? session)
        return true
    }

    private func showFocusMessage(_ message: String) {
        focusMessage = message
        focusMessageTask?.cancel()
        focusMessageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.focusMessage = nil
        }
    }
}

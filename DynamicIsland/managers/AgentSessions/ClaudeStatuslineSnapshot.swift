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

/// Claude Code never writes its 5-hour / weekly rate limits or the context window size to disk;
/// it only hands them to the status line command on stdin. A status line script can save that
/// JSON to `~/.claude/atoll/statusline/<session_id>.json`, and this type reads it back.
///
/// One line in a Python status line script is enough:
///
///     json.dump(d, open(os.path.expanduser(f"~/.claude/atoll/statusline/{d['session_id']}.json"), "w"))
enum ClaudeStatuslineSnapshot {
    struct SessionContext: Equatable {
        let contextWindow: Int?
        let usedPercent: Double?
        let costUSD: Double?
    }

    struct Result {
        var quota: AgentQuota?
        var contexts: [String: SessionContext] = [:]
    }

    static func directory(home: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")) -> URL {
        home.appendingPathComponent("atoll/statusline", isDirectory: true)
    }

    static func read(directory: URL = directory(), now: Date = Date(), maxAge: TimeInterval = 3 * 86_400) -> Result {
        var result = Result()
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else {
            return result
        }
        var newestQuotaAt = Date.distantPast
        for url in files where url.pathExtension == "json" {
            let modified = (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            if now.timeIntervalSince(modified) > maxAge {
                try? FileManager.default.removeItem(at: url) // our own cache; keep it from growing
                continue
            }
            guard let data = try? Data(contentsOf: url),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let parsed = parse(obj, observedAt: modified)
            if let sessionID = obj.string("session_id") { result.contexts[sessionID] = parsed.context }
            if let quota = parsed.quota, modified > newestQuotaAt {
                newestQuotaAt = modified
                result.quota = quota
            }
        }
        return result
    }

    static func parse(_ obj: [String: Any], observedAt: Date) -> (context: SessionContext, quota: AgentQuota?) {
        let window = obj.dict("context_window")
        let context = SessionContext(
            contextWindow: window?.int("context_window_size"),
            usedPercent: window?.double("used_percentage"),
            costUSD: obj.dict("cost")?.double("total_cost_usd")
        )
        let limits = obj.dict("rate_limits")
        let windows: [AgentQuotaWindow] = [("five_hour", "5h"), ("seven_day", "7d")].compactMap { key, label in
            guard let entry = limits?.dict(key), let used = entry.double("used_percentage") else { return nil }
            return AgentQuotaWindow(label: label, usedPercent: used,
                                    resetsAt: entry.double("resets_at").flatMap(JSONLTailReader.epochDate))
        }
        let quota = windows.isEmpty ? nil : AgentQuota(kind: .claude, windows: windows, observedAt: observedAt)
        return (context, quota)
    }
}

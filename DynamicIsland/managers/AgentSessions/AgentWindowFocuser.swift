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

import AppKit
import Foundation

/// Brings the window that hosts an agent session to the front.
///
/// - Terminal.app / iTerm2: the tab whose tty matches the agent process is selected via AppleScript.
/// - VS Code-family editors: the editor window for the session's folder is focused (the integrated
///   terminal panel itself cannot be targeted from outside the editor).
/// - Claude Code background sessions: a new terminal window runs `claude attach <id>`.
/// - Codex desktop threads: opened with a `codex://threads/<id>` link.
/// - Anything else: the hosting app is activated.
@MainActor
enum AgentWindowFocuser {
    enum Outcome: Equatable {
        case focused
        case failed(String)
    }

    static let terminalBundleID = "com.apple.Terminal"
    static let iTermBundleID = "com.googlecode.iterm2"
    static let editorBundlePrefixes = [
        "com.microsoft.VSCode", "com.visualstudio.code", "com.vscodium", "com.todesktop.", "com.exafunction.windsurf",
        "com.trae.", "dev.kiro.",
    ]

    @discardableResult
    static func focus(_ session: AgentSession) async -> Outcome {
        switch session.host {
        case .process(let pid):
            return await focusProcess(pid: pid, cwd: session.cwd)
        case .claudeBackgroundJob(let id):
            return await runInNewTerminal("claude attach \(shellQuote(id))")
        case .codexDesktop(let threadID):
            guard let url = URL(string: "codex://threads/\(threadID)"), NSWorkspace.shared.open(url) else {
                return .failed("Codex app not installed")
            }
            return .focused
        case .editorWorkspace(let path):
            return await openFolderInEditor(path, preferredBundleID: nil)
        case .unknown:
            return .failed("Session has no window")
        }
    }

    // MARK: Processes

    static func focusProcess(pid: Int32, cwd: String) async -> Outcome {
        guard AgentProcessInspector.isAlive(pid) else { return .failed("Session has exited") }
        let tty = AgentProcessInspector.info(pid)?.tty
        guard let app = hostingApplication(of: pid) else {
            // tmux/screen/ssh: no GUI ancestor. Try the terminals that expose ttys anyway.
            if let tty, await selectTerminalTab(tty: tty) { return .focused }
            return .failed("No window found (tmux or remote session?)")
        }
        let bundleID = app.bundleIdentifier ?? ""
        if bundleID == terminalBundleID || bundleID == iTermBundleID, let tty {
            if await selectTerminalTab(tty: tty, in: bundleID) { return .focused }
        } else if editorBundlePrefixes.contains(where: bundleID.hasPrefix) {
            return await openFolderInEditor(cwd, preferredBundleID: bundleID)
        }
        app.unhide()
        return app.activate(options: [.activateAllWindows]) ? .focused : .failed("Could not activate \(app.localizedName ?? "app")")
    }

    /// The nearest ancestor that is a regular GUI app (skipping helper processes such as editor pty hosts).
    static func hostingApplication(of pid: Int32) -> NSRunningApplication? {
        for ancestor in AgentProcessInspector.ancestry(of: pid).dropFirst() {
            if let app = NSRunningApplication(processIdentifier: ancestor), app.activationPolicy == .regular {
                return app
            }
        }
        return nil
    }

    /// Selects the Terminal.app / iTerm2 tab attached to `tty` ("ttys001"). Returns false if none matched.
    static func selectTerminalTab(tty: String, in bundleID: String? = nil) async -> Bool {
        let device = "/dev/\(tty)"
        let terminalScript = """
            tell application id "\(terminalBundleID)"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(device)" then
                            if miniaturized of w then set miniaturized of w to false
                            set selected tab of w to t
                            set index of w to 1
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end tell
            return "missing"
            """
        let iTermScript = """
            tell application id "\(iTermBundleID)"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(device)" then
                                select w
                                tell t to select
                                tell s to select
                                activate
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return "missing"
            """
        var candidates: [(String, String)] = []
        if bundleID == nil || bundleID == terminalBundleID { candidates.append((terminalBundleID, terminalScript)) }
        if bundleID == nil || bundleID == iTermBundleID { candidates.append((iTermBundleID, iTermScript)) }
        for (id, script) in candidates where isRunning(id) {
            if case .success("ok") = await runAppleScript(script) { return true }
        }
        return false
    }

    // MARK: Editors

    static func openFolderInEditor(_ path: String, preferredBundleID: String?) async -> Outcome {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let bundleIDs = [preferredBundleID].compactMap { $0 } + ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"]
        guard let appURL = bundleIDs.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first else {
            return .failed("No editor found")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            // Opening a folder that is already open focuses its existing window.
            _ = try await NSWorkspace.shared.open([folder], withApplicationAt: appURL, configuration: configuration)
            return .focused
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: New terminal window

    static func runInNewTerminal(_ command: String) async -> Outcome {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script: String
        if isRunning(iTermBundleID) {
            script = """
                tell application id "\(iTermBundleID)"
                    set w to (create window with default profile)
                    tell current session of w to write text "\(escaped)"
                    activate
                end tell
                """
        } else {
            script = """
                tell application id "\(terminalBundleID)"
                    do script "\(escaped)"
                    activate
                end tell
                """
        }
        switch await runAppleScript(script) {
        case .success: return .focused
        case .failure(let message): return .failed(message)
        }
    }

    // MARK: Helpers

    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    enum ScriptResult: Equatable {
        case success(String)
        case failure(String)
    }

    /// Runs AppleScript through `/usr/bin/osascript` off the main thread. In-process `NSAppleScript`
    /// on a background thread waits on the main run loop for replies from other apps, and on the main
    /// thread it would block the UI while macOS shows the Automation permission prompt.
    static func runAppleScript(_ source: String, timeout: TimeInterval = 20) async -> ScriptResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-"]
                let input = Pipe(), output = Pipe(), errors = Pipe()
                process.standardInput = input
                process.standardOutput = output
                process.standardError = errors
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: .failure(error.localizedDescription))
                    return
                }
                input.fileHandleForWriting.write(Data(source.utf8))
                try? input.fileHandleForWriting.close()
                let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
                let out = output.fileHandleForReading.readDataToEndOfFile()
                let err = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                let text = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: .success(text))
                } else {
                    continuation.resume(returning: .failure(automationMessage(String(decoding: err, as: UTF8.self))))
                }
            }
        }
    }

    private static func automationMessage(_ stderr: String) -> String {
        if stderr.contains("-1743") || stderr.localizedCaseInsensitiveContains("not authorized") {
            return "Allow Atoll to control your terminal in System Settings › Privacy & Security › Automation"
        }
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "AppleScript failed" : trimmed
    }
}

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

import Darwin
import Foundation

/// Process facts read straight from the kernel (no `ps`/`lsof` subprocesses).
enum AgentProcessInspector {
    struct Info: Equatable {
        let pid: Int32
        let parentPID: Int32
        /// Controlling terminal device name such as "ttys001", if any.
        let tty: String?
        let startedAt: Date?
    }

    static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    static func info(_ pid: Int32) -> Info? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var kinfo = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &kinfo, &size, nil, 0) == 0, size > 0 else { return nil }
        let dev = kinfo.kp_eproc.e_tdev
        var tty: String? = nil
        if dev != -1, let name = devname(dev, S_IFCHR) {
            let s = String(cString: name)
            if !s.isEmpty, s != "??" { tty = s }
        }
        let tv = kinfo.kp_proc.p_starttime
        let started = tv.tv_sec > 0
            ? Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
            : nil
        return Info(pid: pid, parentPID: kinfo.kp_eproc.e_ppid, tty: tty, startedAt: started)
    }

    /// The process followed by its parents, nearest first, stopping before launchd.
    static func ancestry(of pid: Int32, maxDepth: Int = 32) -> [Int32] {
        var chain: [Int32] = []
        var current = pid
        while current > 1, chain.count < maxDepth, !chain.contains(current) {
            chain.append(current)
            guard let parent = info(current)?.parentPID else { break }
            current = parent
        }
        return chain
    }

    static func name(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    static func currentDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    static func allPIDs() -> [Int32] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.stride))
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count))).filter { $0 > 0 }
    }

    /// Processes with the given executable name that are attached to a terminal.
    static func interactiveProcesses(named target: String) -> [(info: Info, cwd: String?)] {
        allPIDs().compactMap { pid in
            guard name(pid) == target, let info = info(pid), info.tty != nil else { return nil }
            return (info, currentDirectory(pid))
        }
    }
}

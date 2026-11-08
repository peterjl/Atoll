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

/// Reads JSON objects from the end of an append-only JSONL log without loading the whole file.
enum JSONLTailReader {
    struct FileStamp: Equatable {
        let size: UInt64
        let modified: Date
    }

    static func stamp(of url: URL) -> FileStamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return FileStamp(size: size, modified: modified)
    }

    /// Decodes the complete lines inside the last `maxBytes` of the file, oldest first.
    /// The first line of the window is dropped when the window starts mid-record.
    static func tailObjects(at url: URL, maxBytes: Int = 768 * 1024) -> [[String: Any]] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return [] }
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd() else { return [] }
        return decodeLines(data, dropFirstPartial: start > 0)
    }

    /// Decodes up to `limit` complete lines from the start of the file.
    static func headObjects(at url: URL, maxBytes: Int = 256 * 1024, limit: Int = 8) -> [[String: Any]] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes) else { return [] }
        var objects = decodeLines(data, dropFirstPartial: false, dropLastPartial: data.count >= maxBytes)
        if objects.count > limit { objects.removeLast(objects.count - limit) }
        return objects
    }

    static func decodeLines(_ data: Data, dropFirstPartial: Bool, dropLastPartial: Bool = false) -> [[String: Any]] {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if dropFirstPartial, !lines.isEmpty, data.first != UInt8(ascii: "\n") { lines.removeFirst() }
        if dropLastPartial, !lines.isEmpty, data.last != UInt8(ascii: "\n") { lines.removeLast() }
        return lines.compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
        }
    }

    // MARK: Timestamps

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let formatterLock = NSLock()

    static func date(_ value: Any?) -> Date? {
        if let s = value as? String {
            formatterLock.lock()
            defer { formatterLock.unlock() }
            return isoFractional.date(from: s) ?? isoPlain.date(from: s)
        }
        if let n = value as? NSNumber { return epochDate(n.doubleValue) }
        return nil
    }

    /// Accepts seconds or milliseconds since 1970.
    static func epochDate(_ value: Double) -> Date? {
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1000 : value)
    }
}

/// Small helpers for walking untyped JSON.
extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
    func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func int(_ key: String) -> Int? { (self[key] as? NSNumber)?.intValue }
    func double(_ key: String) -> Double? { (self[key] as? NSNumber)?.doubleValue }
    func bool(_ key: String) -> Bool { (self[key] as? NSNumber)?.boolValue ?? false }
}

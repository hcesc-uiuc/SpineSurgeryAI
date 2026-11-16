//
//  SensorKitRecheck.swift
//  SensingApp
//
//  Issue #85: SensorKit releases data about 24 h after it is recorded, but on
//  P01's phone sometimes 26-33 h. A fetch inside that gap gets nothing back for
//  the newest hours, the progress point moves past them, and they were never
//  asked for again. The missing part of such a chunk is queued here and
//  fetched once more when it is 48 h old, into its own file, without touching
//  the progress point.
//

import Foundation

/// A time window to fetch again, in CF reference-date seconds.
nonisolated struct RecheckWindow: Codable, Equatable {
    var from: Double
    var to: Double
}

nonisolated enum SensorKitRecheck {

    /// SensorKit had released everything by 33 h in every case seen; 48 h leaves room.
    static let dueAfter: TimeInterval = 48 * 3600
    /// SensorKit deletes data after 7 days.
    static let expireAfter: TimeInterval = 6.5 * 24 * 3600
    /// A chunk whose newest sample is this close to its end counts as complete
    /// (phone accel and gyro ~100 Hz, pressure ~10 Hz).
    static let shortTolerance: TimeInterval = 30

    private static let lock = NSLock()

    static func key(_ prefix: String) -> String { "sk_recheck_\(prefix)" }

    static func windows(_ prefix: String, defaults: UserDefaults = .standard) -> [RecheckWindow] {
        guard let data = defaults.data(forKey: key(prefix)),
              let all = try? JSONDecoder().decode([RecheckWindow].self, from: data) else { return [] }
        return all
    }

    private static func save(_ all: [RecheckWindow], _ prefix: String, _ defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: key(prefix)) }
    }

    /// The part of a chunk that came back missing, or nil if it came back whole.
    /// `newest` is the time of the last row written; the recheck skips rows up
    /// to it, so nothing is saved twice.
    static func missingPart(from: Date, to: Date, newest: Date?) -> (Date, Date)? {
        guard let newest else { return (from, to) }
        guard newest < to.addingTimeInterval(-shortTolerance) else { return nil }
        return (max(newest, from), to)
    }

    /// Queues [from, to), split into pieces no longer than `chunk`. Pieces
    /// already queued are not added twice.
    static func add(_ prefix: String, from: Date, to: Date, chunk: TimeInterval,
                    defaults: UserDefaults = .standard) {
        guard to > from else { return }
        lock.lock(); defer { lock.unlock() }
        var all = windows(prefix, defaults: defaults)
        var start = from
        while start < to {
            let end = min(start.addingTimeInterval(chunk), to)
            let w = RecheckWindow(from: start.timeIntervalSinceReferenceDate, to: end.timeIntervalSinceReferenceDate)
            if !all.contains(w) { all.append(w) }
            start = end
        }
        save(all, prefix, defaults)
    }

    static func remove(_ prefix: String, _ w: RecheckWindow, defaults: UserDefaults = .standard) {
        lock.lock(); defer { lock.unlock() }
        save(windows(prefix, defaults: defaults).filter { $0 != w }, prefix, defaults)
    }

    /// Drops windows SensorKit no longer has; returns how many.
    @discardableResult
    static func dropExpired(_ prefix: String, now: Date = Date(), defaults: UserDefaults = .standard) -> Int {
        lock.lock(); defer { lock.unlock() }
        let all = windows(prefix, defaults: defaults)
        let cutoff = now.addingTimeInterval(-expireAfter).timeIntervalSinceReferenceDate
        let kept = all.filter { $0.from >= cutoff }
        save(kept, prefix, defaults)
        return all.count - kept.count
    }

    /// The oldest queued window that is old enough to have been released.
    static func due(_ prefix: String, now: Date = Date(), defaults: UserDefaults = .standard) -> RecheckWindow? {
        let ready = now.addingTimeInterval(-dueAfter).timeIntervalSinceReferenceDate
        return windows(prefix, defaults: defaults).filter { $0.to <= ready }.min { $0.from < $1.from }
    }

    // MARK: - Known gaps dropped on the phone

    /// File name in Documents. A JSON list of
    /// {"sensor": "sensorkit_gyro_phone", "from": ISO-8601, "to": ISO-8601};
    /// copied onto the phone to recheck gaps found on the server.
    static let importFileName = "sensorkit-recheck.json"

    private struct ImportEntry: Decodable {
        let sensor: String
        let from: String
        let to: String
    }

    /// Queues the windows in `url` for the sensors in `chunks` (file prefix ->
    /// chunk length), then renames the file so it is read once. Returns how
    /// many windows were queued.
    @discardableResult
    static func importFile(_ url: URL, chunks: [String: TimeInterval],
                           defaults: UserDefaults = .standard) -> Int {
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([ImportEntry].self, from: data) else { return 0 }
        let iso = ISO8601DateFormatter()
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parse = { (s: String) in iso.date(from: s) ?? isoFrac.date(from: s) }
        var count = 0
        for e in entries {
            guard let chunk = chunks[e.sensor], let from = parse(e.from), let to = parse(e.to) else { continue }
            add(e.sensor, from: from, to: to, chunk: chunk, defaults: defaults)
            count += 1
        }
        let done = url.appendingPathExtension("imported")
        try? FileManager.default.removeItem(at: done)
        try? FileManager.default.moveItem(at: url, to: done)
        return count
    }
}

//
//  SensorRunLog.swift
//  SensingApp
//
//  Issue #85: what each SensorKit fetch run got. One record per sensor per
//  run (samples, the time range of those samples, what triggered it, why it
//  stopped), the last 120 kept in UserDefaults, shown on the SensorKit status
//  screen and written to the log as one summary line.
//

import Foundation

nonisolated struct SensorRunRecord: Codable, Equatable {
    var finishedAt: Date
    var trigger: String
    var samples: Int
    /// "rows" (rows written, SensorKitFetcher sensors) or "results" (SensorKit
    /// results seen by the standalone fetchers: one per sample for ambient
    /// light and device usage, one per batch for Watch accel, PPG, heart rate).
    var unit: String
    var dataStart: Date?
    var dataEnd: Date?
    var chunks: Int?
    var megabytes: Int?
    var stopReason: String
    var failed: Bool
}

nonisolated enum SensorRunLog {

    static let maxRecords = 120   // ~5 days at one run an hour, covers the 72 h view
    private static let lock = NSLock()

    /// Set by BackgroundScheduler when it starts a run; read when a run ends
    /// (on SensorKit's queue), hence the lock.
    nonisolated(unsafe) private static var trigger = "unknown"
    static var currentTrigger: String {
        get { lock.lock(); defer { lock.unlock() }; return trigger }
        set { lock.lock(); trigger = newValue; lock.unlock() }
    }

    static func key(_ kind: SensorKind) -> String { "sk_run_log_\(kind.rawValue)" }

    static func record(_ r: SensorRunRecord, kind: SensorKind, defaults: UserDefaults = .standard) {
        lock.lock(); defer { lock.unlock() }
        var all = records(kind, defaults: defaults)
        all.append(r)
        if all.count > maxRecords { all.removeFirst(all.count - maxRecords) }
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: key(kind)) }
    }

    /// Oldest first.
    static func records(_ kind: SensorKind, defaults: UserDefaults = .standard) -> [SensorRunRecord] {
        guard let data = defaults.data(forKey: key(kind)),
              let all = try? JSONDecoder().decode([SensorRunRecord].self, from: data) else { return [] }
        return all
    }

    struct Totals: Equatable {
        var runs: Int
        var samples: Int
        var dataEnd: Date?
    }

    /// Runs that finished in the last `window`, their samples, and the newest
    /// data any of them got.
    static func totals(_ kind: SensorKind, window: TimeInterval, now: Date = Date(),
                       defaults: UserDefaults = .standard) -> Totals {
        let recent = records(kind, defaults: defaults).filter { now.timeIntervalSince($0.finishedAt) <= window }
        return Totals(runs: recent.count,
                      samples: recent.reduce(0) { $0 + $1.samples },
                      dataEnd: recent.compactMap(\.dataEnd).max())
    }

    /// e.g. "1,240,000 rows, data Nov 6, 8:31 PM - Nov 7, 11:01 AM"
    static func describe(_ r: SensorRunRecord) -> String {
        let n = r.samples.formatted(.number)
        guard let a = r.dataStart, let b = r.dataEnd else { return "\(n) \(r.unit), no data" }
        return "\(n) \(r.unit), data \(a.formatted(date: .abbreviated, time: .shortened))"
            + " - \(b.formatted(date: .abbreviated, time: .shortened))"
    }
}

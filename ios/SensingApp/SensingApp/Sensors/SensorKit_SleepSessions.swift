//
//  SensorKit_SleepSessions.swift
//  SensingApp
//
//  SensorKit sleep sessions (iOS 26+). Writes sensorkit_sleep_watch_*.csv.
//  One SRSleepSession per fetch result: start, duration and a stable id.
//  duration is 0 when the session has no end event.
//
//  Recorded on Apple Watch only. Info.plist key is SRSensorUsageSleep; the
//  system expects entitlement value "sleep-sessions" (Issue #74). Until that is
//  confirmed working, SensorKitRegistry requests its authorization separately.
//

import SensorKit

final class SensorKitSleepSessionsFetcher: SensorKitFetcher {
    static let shared = SensorKitSleepSessionsFetcher()

    init() {
        super.init(
            sensor: .sleepSessions,
            filePrefix: "sensorkit_sleep_watch",
            csvHeader: "timestamp_unix,session_id,start_unix,duration_s",
            devicePreference: .watch,   // SensorKit records sleep sessions on Apple Watch only
            logTag: "SK-Sleep",
            fileIndexKey: "sk_sleep_csv_file_index",
            lastFetchEndKey: "sk_sleep_last_fetch_end",
            maxFileSizeMB: 5
        )
    }

    override func rows(from result: SRFetchResult<AnyObject>) -> [String] {
        guard let s = result.sample as? SRSleepSession else { return [] }
        let t = Date(timeIntervalSinceReferenceDate: result.timestamp.toCFAbsoluteTime())
            .timeIntervalSince1970
        return ["\(String(format: "%.6f", t)),\(s.identifier),"
              + "\(String(format: "%.6f", s.startDate.timeIntervalSince1970)),"
              + "\(String(format: "%.3f", s.duration))"]
    }
}

//
//  SensorKit_KeyboardMetrics.swift
//  SensingApp
//
//  SensorKit keyboard metrics (iPhone). Writes sensorkit_keyboard_phone_*.csv.
//  SRKeyboardMetrics has dozens of fields (many are complex distribution
//  objects); this captures a curated set of scalar aggregates. Typed content
//  is never accessed - only aggregate counts/durations.
//

import SensorKit

final class SensorKitKeyboardMetricsFetcher: SensorKitFetcher {
    static let shared = SensorKitKeyboardMetricsFetcher()

    init() {
        super.init(
            sensor: .keyboardMetrics,
            filePrefix: "sensorkit_keyboard_phone",
            csvHeader: "timestamp_unix,duration_s,version,width_mm,height_mm,total_words,total_taps,total_drags,total_deletes,total_emojis,total_paths,total_autocorrections,total_typing_duration_s",
            devicePreference: .iPhone,
            logTag: "SK-Keyboard",
            fileIndexKey: "sk_keyboard_csv_file_index",
            lastFetchEndKey: "sk_keyboard_last_fetch_end",
            maxFileSizeMB: 5
        )
    }

    override func rows(from result: SRFetchResult<AnyObject>) -> [String] {
        guard let m = result.sample as? SRKeyboardMetrics else { return [] }
        let t = Date(timeIntervalSinceReferenceDate: result.timestamp.toCFAbsoluteTime())
            .timeIntervalSince1970
        let widthMM  = m.width.converted(to: .millimeters).value
        let heightMM = m.height.converted(to: .millimeters).value
        return ["\(String(format: "%.6f", t)),\(m.duration),\(m.version),"
              + "\(String(format: "%.2f", widthMM)),\(String(format: "%.2f", heightMM)),"
              + "\(m.totalWords),\(m.totalTaps),\(m.totalDrags),\(m.totalDeletes),"
              + "\(m.totalEmojis),\(m.totalPaths),\(m.totalAutoCorrections),"
              + "\(m.totalTypingDuration)"]
    }
}

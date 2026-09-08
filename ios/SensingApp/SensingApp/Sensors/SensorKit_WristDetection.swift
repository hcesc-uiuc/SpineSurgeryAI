//
//  SensorKit_WristDetection.swift
//  SensingApp
//
//  SensorKit "on-wrist" detection (paired Apple Watch). All logic lives in
//  SensorKitFetcher. Writes sensorkit_wristdetection_watch_*.csv.
//
//  Notes:
//   - Event-driven, not a 50Hz stream: SRWristDetection is emitted only when
//     the on/off-wrist state changes. The base still flushes at the end of
//     every fetch (didCompleteFetch), so the handful of events per fetch are
//     never stranded in the buffer.
//   - Targets the Watch (devicePreference: .watch) — wrist detection is
//     meaningless for a device that isn't worn.
//

import SensorKit
import Foundation

final class SensorKitWristDetectionFetcher: SensorKitFetcher {
    static let shared = SensorKitWristDetectionFetcher()

    init() {
        super.init(
            sensor: .onWristState,
            filePrefix: "sensorkit_wristdetection_watch",
            csvHeader: "timestamp_unix,on_wrist,wrist_location,crown_orientation",
            devicePreference: .watch,
            logTag: "SK-Wrist",
            fileIndexKey: "sk_wrist_csv_file_index",
            lastFetchEndKey: "sk_wrist_last_fetch_end",
            maxFileSizeMB: 5
        )
    }

    // SRWristDetection arrives as one sample per fetch result (not a batch).
    override func rows(from result: SRFetchResult<AnyObject>) -> [String] {
        guard let sample = result.sample as? SRWristDetection else { return [] }

        let unixTime = Date(timeIntervalSinceReferenceDate: result.timestamp.toCFAbsoluteTime())
            .timeIntervalSince1970

        let location: String
        switch sample.wristLocation {
        case .left:       location = "left"
        case .right:      location = "right"
        @unknown default: location = "unknown"
        }

        let crown: String
        switch sample.crownOrientation {
        case .left:       crown = "left"
        case .right:      crown = "right"
        @unknown default: crown = "unknown"
        }

        return ["\(String(format: "%.6f", unixTime)),\(sample.onWrist ? 1 : 0),\(location),\(crown)"]
    }
}

//
//  SensorKit_AccelPhone.swift
//  SensingApp
//
//  SensorKit accelerometer from the iPhone (issue #85). Replaces the CoreMotion
//  recorder (AcclerometerRecorder) as the phone accelerometer source. The Watch
//  accelerometer is SensorKit_AccelWatch.swift. Writes sensorkit_accel_phone_*.csv.
//

import SensorKit
import CoreMotion

final class SensorKitPhoneAccelerometerFetcher: SensorKitFetcher {
    static let shared = SensorKitPhoneAccelerometerFetcher()

    init() {
        super.init(
            sensor: .accelerometer,
            kind: .accelerometer,
            filePrefix: "sensorkit_accel_phone",
            csvHeader: "timestamp_unix,x,y,z",
            devicePreference: .iPhone,
            logTag: "SK-AccelPhone",
            // Own keys: the Watch fetcher uses sk_csv_file_index / sk_accel_last_fetch_end
            fileIndexKey: "sk_accel_phone_csv_file_index",
            lastFetchEndKey: "sk_accel_phone_last_fetch_end",
            fetchChunkHours: 1   // high rate, like the gyroscope
        )
    }

    // The accelerometer delivers a batch array per fetch result.
    override func rows(from result: SRFetchResult<AnyObject>) -> [String] {
        guard let samples = result.sample as? [CMRecordedAccelerometerData] else { return [] }
        return samples.map { s in
            let a = s.acceleration
            return "\(String(format: "%.6f", s.startDate.timeIntervalSince1970)),"
                 + "\(String(format: "%.8f", a.x)),"
                 + "\(String(format: "%.8f", a.y)),"
                 + "\(String(format: "%.8f", a.z))"
        }
    }
}

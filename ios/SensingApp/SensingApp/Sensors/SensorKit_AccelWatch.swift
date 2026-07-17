//
//  SensorKit_AccelWatch.swift
//  SensingApp
//
//  SensorKit accelerometer (iPhone). All logic lives in SensorKitFetcher;
//  this only declares the config and how to turn a fetch result into rows.
//  Writes sensorkit_accel_phone_*.csv.
//

import SensorKit
import CoreMotion

final class SensorKitAccelerometerFetcher: SensorKitFetcher {
    static let shared = SensorKitAccelerometerFetcher()

    init() {
        super.init(
            sensor: .accelerometer,
            filePrefix: "sensorkit_accel_phone",
            csvHeader: "timestamp_unix,x,y,z",
            devicePreference: .iPhone,
            logTag: "SK-Accel",
            fileIndexKey: "sk_csv_file_index",
            lastFetchEndKey: "sk_accel_last_fetch_end"
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

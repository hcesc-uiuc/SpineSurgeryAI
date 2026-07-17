//
//  SensorKit_Gyro.swift
//  SensingApp
//
//  SensorKit gyroscope / rotation rate (iPhone). All logic lives in
//  SensorKitFetcher. Writes sensorkit_gyro_phone_*.csv.
//

import SensorKit
import CoreMotion

final class SensorKitGyroscopeFetcher: SensorKitFetcher {
    static let shared = SensorKitGyroscopeFetcher()

    init() {
        super.init(
            sensor: .rotationRate,
            filePrefix: "sensorkit_gyro_phone",
            csvHeader: "timestamp_unix,x,y,z",
            devicePreference: .iPhone,
            logTag: "SK-Gyro",
            fileIndexKey: "sk_gyro_csv_file_index",
            lastFetchEndKey: "sk_gyro_last_fetch_end"
        )
    }

    // Rotation rate delivers a batch array per fetch result.
    override func rows(from result: SRFetchResult<AnyObject>) -> [String] {
        guard let samples = result.sample as? [CMRecordedRotationRateData] else { return [] }
        return samples.map { s in
            let r = s.rotationRate
            return "\(String(format: "%.6f", s.startDate.timeIntervalSince1970)),"
                 + "\(String(format: "%.8f", r.x)),"
                 + "\(String(format: "%.8f", r.y)),"
                 + "\(String(format: "%.8f", r.z))"
        }
    }
}

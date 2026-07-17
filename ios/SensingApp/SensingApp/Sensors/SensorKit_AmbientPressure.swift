//
//  SensorKit_AmbientPressure.swift
//  SensingApp
//
//  SensorKit ambient pressure / barometer (iPhone). Writes
//  sensorkit_pressure_phone_*.csv. All logic lives in SensorKitFetcher.
//

import SensorKit
import CoreMotion

final class SensorKitAmbientPressureFetcher: SensorKitFetcher {
    static let shared = SensorKitAmbientPressureFetcher()

    init() {
        super.init(
            sensor: .ambientPressure,
            filePrefix: "sensorkit_pressure_phone",
            csvHeader: "timestamp_unix,pressure_kpa,temperature_c",
            devicePreference: .iPhone,
            logTag: "SK-Pressure",
            fileIndexKey: "sk_pressure_csv_file_index",
            lastFetchEndKey: "sk_pressure_last_fetch_end"
        )
    }

    // Ambient pressure delivers a batch of CMRecordedPressureData per result.
    override func rows(from result: SRFetchResult<AnyObject>) -> [String] {
        guard let samples = result.sample as? [CMRecordedPressureData] else { return [] }
        return samples.map { s in
            let kpa = s.pressure.converted(to: .kilopascals).value
            let c   = s.temperature.converted(to: .celsius).value
            return "\(String(format: "%.6f", s.startDate.timeIntervalSince1970)),"
                 + "\(String(format: "%.4f", kpa)),"
                 + "\(String(format: "%.4f", c))"
        }
    }
}

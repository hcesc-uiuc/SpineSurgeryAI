//
//  SensorKit_GyroWatch.swift
//  SensingApp
//
//  SensorKit gyroscope (rotation rate) from the paired Apple Watch.
//
//  Unlike Core Motion's CMMotionManager (which only runs while the app is
//  alive), SensorKit records continuously at the OS level — even when the app
//  is closed — and you fetch it later, past the 24h embargo. This is the
//  always-on gyro stream a research study needs.
//
//  Thanks to the SensorKitFetcher base class, a whole sensor is just an init
//  + a parse() override.
//

import SensorKit
import CoreMotion
import Foundation

final class SensorKitRotationRateFetcher: SensorKitFetcher {

    init() {
        super.init(
            sensor: .rotationRate,
            filePrefix: "sensorkit_gyro_phone",
            csvHeader: "timestamp_unix,x,y,z",
            devicePreference: .iPhone   // the phone's own gyroscope, recorded 24/7 by the OS
        )
    }

    // Like the accelerometer, rotation rate arrives as a batch of recorded
    // samples per fetch result.
    override func parse(_ result: SRFetchResult<AnyObject>) -> [String] {
        guard let samples = result.sample as? [CMRecordedRotationRateData] else { return [] }
        return samples.map { sample in
            let t = sample.startDate.timeIntervalSince1970
            let r = sample.rotationRate          // x,y,z in rad/s
            return "\(String(format: "%.6f", t)),"
                 + "\(String(format: "%.8f", r.x)),"
                 + "\(String(format: "%.8f", r.y)),"
                 + "\(String(format: "%.8f", r.z))"
        }
    }
}

//
//  GyroscopeMotionRecorder.swift
//  SensingApp
//
//  Records the iPhone's own gyroscope (rotation rate) in real time and writes
//  it to CSV in Documents/to-be-processed/, ready for the Uploader.
//
//  Why CMMotionManager (and not SensorKit or CMSensorRecorder)?
//   • SensorKit `.rotationRate` is the Apple WATCH gyroscope, not the phone's.
//   • CMSensorRecorder only supports historical ACCELEROMETER recording — iOS
//     has no gyroscope equivalent. (That's why the old GyroscopeRecorder was
//     actually recording accelerometer data.)
//   • So real-time CMMotionManager is the ONLY way to capture the iPhone's
//     own gyroscope. It streams while the app is running; there is no 24h
//     embargo and no paired-Watch requirement — data appears immediately.
//

import CoreMotion
import Foundation

final class GyroscopeMotionRecorder {
    static let shared = GyroscopeMotionRecorder()

    private let motion = CMMotionManager()
    private let queue: OperationQueue
    private var writer: PreallocatedCSVBuffer?
    private var sampleCount = 0
    private let flushEvery = 500        // flush to disk every N samples

    private init() {
        queue = OperationQueue()
        queue.name = "GyroscopeMotionRecorder"
        queue.maxConcurrentOperationCount = 1   // serial → safe CSV writes
    }

    var isRecording: Bool { motion.isGyroActive }

    /// Starts streaming gyro at `hz` and writing rows to a fresh CSV file.
    /// Each row: `timestamp_unix_ms,x,y,z`  (rotation rate in rad/s).
    func startRecording(hz: Double = 50) {
        guard motion.isGyroAvailable else {
            print("⚠️ Gyroscope not available on this device")
            Logger.shared.append("Gyroscope not available on this device")
            return
        }
        guard !motion.isGyroActive else {
            print("Gyro already recording")
            return
        }

        let filename = "gyroscope_\(currentTimestampString()).csv"
        writer = PreallocatedCSVBuffer(filename: filename, capacity: 100_000)
        sampleCount = 0

        motion.gyroUpdateInterval = 1.0 / hz
        motion.startGyroUpdates(to: queue) { [weak self] data, error in
            guard let self else { return }
            if let error {
                print("Gyro update error: \(error)")
                CrashReporter.record(error, context: "Gyro.update")
                return
            }
            guard let data else { return }

            let r = data.rotationRate                      // x,y,z in rad/s
            let unixMs = Int64(Date().timeIntervalSince1970 * 1000)
            self.writer?.addRowStr(rowOfData: "\(unixMs),\(r.x),\(r.y),\(r.z)")

            self.sampleCount += 1
            if self.sampleCount >= self.flushEvery {
                self.writer?.flush()
                self.sampleCount = 0
            }
        }

        print("🌀 Gyroscope recording started at \(hz)Hz → \(filename)")
        Logger.shared.append("Gyroscope recording started at \(hz)Hz → \(filename)")
        CrashReporter.log("gyro recording started")
    }

    /// Stops streaming and flushes/closes the current file.
    func stopRecording() {
        guard motion.isGyroActive else {
            print("Gyro not recording")
            return
        }
        motion.stopGyroUpdates()

        // Flush/close on the same serial queue so we don't race the callback.
        queue.addOperation { [weak self] in
            self?.writer?.flush()
            self?.writer?.closeFile()
            self?.writer = nil
            self?.sampleCount = 0
        }

        print("🛑 Gyroscope recording stopped")
        Logger.shared.append("Gyroscope recording stopped")
        CrashReporter.log("gyro recording stopped")
    }

    private func currentTimestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.timeZone = .current
        return formatter.string(from: Date())
    }
}

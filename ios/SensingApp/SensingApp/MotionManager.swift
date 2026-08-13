//
//  MotionManager.swift
//  SensingApp
//
//  Created by Samir Kurudi on 11/20/25.
//  Updated: added stop controls + isActive flags so the Sensors tab
//  can toggle live accelerometer/gyroscope tracking on and off.
//
import Foundation
import CoreMotion
internal import Combine

class MotionManager: ObservableObject {
    private let motion = CMMotionManager()

    @Published var accelerometerData: CMAccelerometerData?
    @Published var gyroscopeData: CMGyroData?

    // Reflects whether updates are actively being requested from CoreMotion
    // right now (bound to the toggles in SensorsTabView).
    @Published var isAccelerometerActive = false
    @Published var isGyroscopeActive = false

    var isAccelerometerAvailable: Bool { motion.isAccelerometerAvailable }
    var isGyroscopeAvailable: Bool { motion.isGyroAvailable }

    init() {
        startAccelerometerUpdates()
        startGyroUpdates()
    }

    func startAccelerometerUpdates() {
        guard motion.isAccelerometerAvailable else { return }

        motion.accelerometerUpdateInterval = 0.1
        motion.startAccelerometerUpdates(to: OperationQueue.main) { [weak self] data, _ in
            self?.accelerometerData = data
        }
        isAccelerometerActive = true
    }

    func stopAccelerometerUpdates() {
        motion.stopAccelerometerUpdates()
        isAccelerometerActive = false
        accelerometerData = nil
    }

    func setAccelerometerEnabled(_ enabled: Bool) {
        enabled ? startAccelerometerUpdates() : stopAccelerometerUpdates()
    }

    func startGyroUpdates() {
        guard motion.isGyroAvailable else { return }

        motion.gyroUpdateInterval = 0.1
        motion.startGyroUpdates(to: OperationQueue.main) { [weak self] data, _ in
            self?.gyroscopeData = data
        }
        isGyroscopeActive = true
    }

    func stopGyroUpdates() {
        motion.stopGyroUpdates()
        isGyroscopeActive = false
        gyroscopeData = nil
    }

    func setGyroscopeEnabled(_ enabled: Bool) {
        enabled ? startGyroUpdates() : stopGyroUpdates()
    }
}

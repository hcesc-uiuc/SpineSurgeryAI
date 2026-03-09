//
//  MotionManager.swift
//  SensingApp
//
//  Created by Samir Kurudi on 11/20/25.
//
import Foundation
import CoreMotion
import Combine

class MotionManager: ObservableObject {
    private let motion = CMMotionManager()

    @Published var accelerometerData: CMAccelerometerData?
    @Published var gyroscopeData: CMGyroData?

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
    }

    func startGyroUpdates() {
        guard motion.isGyroAvailable else { return }

        motion.gyroUpdateInterval = 0.1
        motion.startGyroUpdates(to: OperationQueue.main) { [weak self] data, _ in
            self?.gyroscopeData = data
        }
    }
}

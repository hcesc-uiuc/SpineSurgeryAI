//
//  MotionManager.swift
//  SensingApp
//
//  Created by Samir Kurudi on 11/20/25.
//
//  Live CoreMotion preview for the Sensors tab ONLY. This is not the research
//  pipeline — AcclerometerRecorder and GyroscopeRecorder own that, via
//  CMSensorRecorder, and are entirely separate objects.
//
//  Construction is deliberately inert: these streams run at 10 Hz onto the main
//  queue, and the owning @StateObject lives for the whole app lifetime once the
//  TabView materialises the Sensors tab. Starting them in init() therefore
//  powered the hardware before anyone had looked at the tab. Only start()/stop(),
//  driven by the tab's appear/disappear and scene phase, may turn these on.
//
import Foundation
import CoreMotion
internal import Combine

class MotionManager: ObservableObject {
    private let motion = CMMotionManager()

    @Published var accelerometerData: CMAccelerometerData?
    @Published var gyroscopeData: CMGyroData?

    var isAccelerometerAvailable: Bool { motion.isAccelerometerAvailable }
    var isGyroscopeAvailable: Bool { motion.isGyroAvailable }

    func start() {
        if motion.isAccelerometerAvailable {
            motion.accelerometerUpdateInterval = 0.1
            motion.startAccelerometerUpdates(to: OperationQueue.main) { [weak self] data, _ in
                self?.accelerometerData = data
            }
        }
        if motion.isGyroAvailable {
            motion.gyroUpdateInterval = 0.1
            motion.startGyroUpdates(to: OperationQueue.main) { [weak self] data, _ in
                self?.gyroscopeData = data
            }
        }
    }

    // Clearing the published values matters as much as stopping the hardware:
    // without it the last reading stays frozen on screen while the app is
    // backgrounded, which reads as live data that is no longer being collected.
    func stop() {
        motion.stopAccelerometerUpdates()
        motion.stopGyroUpdates()
        accelerometerData = nil
        gyroscopeData = nil
    }
}

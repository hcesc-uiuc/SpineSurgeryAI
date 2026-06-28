//
//  SensorKitManager.swift
//  SensingApp
//
//  Created by Mohammod Mashfiqui Rabbi Shuvo on 5/15/26.
//


import SensorKit
internal import Combine

class SensorKitManager: NSObject, ObservableObject {
    @Published var authorizationStatus: SRAuthorizationStatus = .notDetermined
    // UserDefaults key
    private let authKey = "sk_authorization_status"

    // Retained recorders. Calling startRecording() on each tells the OS to
    // begin retaining data for the app — without this, fetch() is always empty.
    private var recorders: [SensorKitFetcher] = []

    override init() {
        super.init()
        loadAuthorizationStatus()
    }

    /// Starts (or continues) OS-level recording for every sensor we collect.
    /// Idempotent — safe to call on each launch.
    func startRecordingAllSensors() {
        let fetchers: [SensorKitFetcher] = [
            SensorKitAccelerometerFetcher(),
            SensorKitRotationRateFetcher()
        ]
        fetchers.forEach { $0.startRecording() }
        self.recorders = fetchers   // retain
        print("SensorKit: startRecording requested for accelerometer + rotationRate")
    }
    
    private func loadAuthorizationStatus() {
        let raw = UserDefaults.standard.integer(forKey: authKey)
        authorizationStatus = SRAuthorizationStatus(rawValue: raw) ?? .notDetermined
    }
    
    private func saveAuthorizationStatus(_ status: SRAuthorizationStatus) {
        UserDefaults.standard.set(status.rawValue, forKey: authKey)
        DispatchQueue.main.async {
            self.authorizationStatus = status
        }
    }
    
    func requestAuthorization() {
        guard authorizationStatus != .authorized else {
            print("Sensorkit already authorized")
            // Already authorized on a prior launch — make sure recording is
            // still running (startRecording must be re-asserted each launch).
            startRecordingAllSensors()
            return
        }

        SRSensorReader.requestAuthorization(sensors: [.accelerometer, .rotationRate]) { [weak self] error in
            if let error = error {
                print("SensorKit auth error: \(error)")
                self?.saveAuthorizationStatus(.denied)
                return
            }
            self?.saveAuthorizationStatus(.authorized)
            print("SensorKit authorization granted")
            // Now that we're authorized, tell the OS to start collecting data.
            DispatchQueue.main.async { self?.startRecordingAllSensors() }
        }
    }
    
    var isAuthorized: Bool {
        authorizationStatus == .authorized
    }
    
    //    func requestAuthorization() {
    //        // SensorKit shows a system permission sheet
    //        SRSensorReader.requestAuthorization(sensors: [.accelerometer]) { error in
    //            if let error = error {
    //                print("SensorKit auth error: \(error)")
    //                return
    //            }
    //            print("SensorKit authorization granted")
    //        }
    //    }
    
}

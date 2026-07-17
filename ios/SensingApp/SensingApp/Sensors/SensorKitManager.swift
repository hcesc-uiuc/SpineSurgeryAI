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
    
    override init() {
        super.init()
        loadAuthorizationStatus()
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
            print("Sensorkit Already authorized, skipping")
            SensorKitRegistry.all.forEach { $0.startRecording() }
            return
        }
        self.askForAuthorization()
    }

    func askForAuthorization(){
        // Authorize every sensor in the registry; adding a sensor there is all
        // that's needed to include it here.
        SRSensorReader.requestAuthorization(sensors: SensorKitRegistry.sensors) { [weak self] error in
            if let error = error {
                let nsError = error as NSError
                if nsError.domain == "SRErrorDomain", nsError.code == 8201 {
                    print("SensorKit authorization already granted")
                    self?.saveAuthorizationStatus(.authorized)
                    return // already authorized — not a real error
                }
                print("SensorKit auth error: \(error)")
                self?.saveAuthorizationStatus(.denied)
                return
            }
            self?.saveAuthorizationStatus(.authorized)
            print("SensorKit authorization granted")
            SensorKitRegistry.all.forEach { $0.startRecording() }
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

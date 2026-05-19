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
            return
        }
        
        SRSensorReader.requestAuthorization(sensors: [.accelerometer]) { [weak self] error in
            if let error = error {
                print("SensorKit auth error: \(error)")
                self?.saveAuthorizationStatus(.denied)
                return
            }
            self?.saveAuthorizationStatus(.authorized)
            print("SensorKit authorization granted")
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

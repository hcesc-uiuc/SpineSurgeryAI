//
//  SensorKitManager.swift
//  SensingApp
//
//  Created by Mohammod Mashfiqui Rabbi Shuvo on 5/15/26.
//


import SensorKit
internal import Combine

class SensorKitManager: NSObject, ObservableObject {
    
    // One reader per sensor type
    private let accelerometerReader = SRSensorReader(sensor: .accelerometer)
    
    func requestAuthorization() {
        // SensorKit shows a system permission sheet
        SRSensorReader.requestAuthorization(sensors: [.accelerometer]) { error in
            if let error = error {
                print("SensorKit auth error: \(error)")
                return
            }
            print("SensorKit authorization granted")
        }
    }
}

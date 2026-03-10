//
//  LocationManager.swift
//  SensingApp
//
//  Created by Mohammod Mashfiqui Rabbi Shuvo on 10/21/25.
//

import CoreLocation
import UIKit

class LocationManager: NSObject, CLLocationManagerDelegate {
    static let shared = LocationManager()
    private let manager = CLLocationManager()

    override private init() {
        super.init()
        manager.delegate = self
        manager.allowsBackgroundLocationUpdates = true  // crucial
        manager.pausesLocationUpdatesAutomatically = false
        //-- https://developer.apple.com/documentation/corelocation/cllocationaccuracy
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func start() {
        manager.requestAlwaysAuthorization()
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    // CLLocationManagerDelegate
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        print("📍 Background location: \(location.coordinate.latitude), \(location.coordinate.longitude)")
        // You can trigger background work here
        Logger.shared.append("Background location: \(location.coordinate.latitude), \(location.coordinate.longitude)")
    }
}

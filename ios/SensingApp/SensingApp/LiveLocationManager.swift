//
//  LiveLocationManager.swift
//  SensingApp
//
//  Lightweight, UI-facing location publisher. LocationFileLogger already
//  handles writing location rows to disk for research uploads — this class
//  is separate and only exists to drive the live coordinate shown on the
//  Sensors tab. It does not touch the file-logging pipeline.
//
//  Lifecycle is owned entirely by the Sensors tab: start() when the tab is on
//  screen and the app is active, stop() otherwise.
//

import Foundation
import CoreLocation
internal import Combine

class LiveLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {

    static let shared = LiveLocationManager()

    private let manager = CLLocationManager()

    @Published var coordinate: CLLocationCoordinate2D?
    @Published var horizontalAccuracy: CLLocationAccuracy?
    @Published var lastUpdate: Date?
    @Published var isTracking = false

    var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    override init() {
        super.init()
        manager.delegate = self

        // This drives a coordinate label, not the research pipeline, so it does
        // not need GPS-grade accuracy. Requesting Best with no distance filter
        // pins the GPS on for the whole app: CoreLocation powers the hardware to
        // satisfy the most demanding active client, which would override
        // AdaptiveLocationManager whenever it drops to low power.
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 10
    }

    func start() {
        guard authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else { return }
        manager.startUpdatingLocation()
        isTracking = true
    }

    // The published values are cleared alongside stopping the hardware. Leaving
    // the last fix in place kept a coordinate on screen after the tab was left
    // or the app backgrounded, which looks like location is still being read.
    func stop() {
        manager.stopUpdatingLocation()
        isTracking = false
        coordinate = nil
        horizontalAccuracy = nil
        lastUpdate = nil
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        DispatchQueue.main.async {
            self.coordinate = location.coordinate
            self.horizontalAccuracy = location.horizontalAccuracy
            self.lastUpdate = Date()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("LiveLocationManager error: \(error.localizedDescription)")
    }
}

//
//  LiveLocationManager.swift
//  SensingApp
//
//  Lightweight, UI-facing location publisher. LocationFileLogger already
//  handles writing location rows to disk for research uploads — this class
//  is separate and only exists to drive the live coordinate shown on the
//  Sensors tab. It does not touch the file-logging pipeline.
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

    // Whether the patient wants live location shown. Kept separate from
    // isTracking so leaving the tab can stop the GPS without flipping
    // the toggle off underneath them.
    private(set) var userEnabled = true

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

    func stop() {
        manager.stopUpdatingLocation()
        isTracking = false
    }

    // Called when the Sensors tab appears. Honours the toggle so returning to
    // the tab does not silently restart location the patient turned off.
    func resumeIfEnabled() {
        guard userEnabled else { return }
        start()
    }

    func setTracking(_ enabled: Bool) {
        userEnabled = enabled
        enabled ? start() : stop()
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

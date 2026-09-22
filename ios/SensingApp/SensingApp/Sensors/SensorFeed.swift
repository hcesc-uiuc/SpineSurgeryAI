//
//  SensorFeed.swift
//  SensingApp
//
//  Everything the Sensors tab displays, behind start() / stop().
//
//  Live PREVIEW only. The research recorders (AcclerometerRecorder,
//  AdaptiveLocationManager, the SensorKit fetchers, HealthkitRecorder) are
//  separate and keep collecting whether or not this is running.
//
//  Combines MotionManager and LocationManager into one file.
//
//  Health values come from SensorStatusStore's one-shot queries, not
//  HealthKitManager, whose init registers background observers that wake the app.
//

import Foundation
import CoreMotion
import CoreLocation
internal import Combine

final class SensorFeed: NSObject, ObservableObject, CLLocationManagerDelegate {

    static let shared = SensorFeed()

    @Published private(set) var accelerometer: String?
    @Published private(set) var gyroscope: String?
    @Published private(set) var location: String?
    @Published private(set) var health: [SensorKind: String] = [:]
    @Published private(set) var lastRecorded: [SensorKind: Date] = [:]

    private let motion = CMMotionManager()
    private let locationManager = CLLocationManager()
    private var isRunning = false

    var isAccelerometerAvailable: Bool { motion.isAccelerometerAvailable }
    var isGyroscopeAvailable: Bool { motion.isGyroAvailable }

    static let healthKinds: [SensorKind] = [
        .heartRate, .heartRateVariability, .steps, .bloodOxygen, .activeEnergy, .sleep
    ]

    /// Rows with a real recorder behind them, so a "Last recorded" line means something.
    private static let recordedKinds: [SensorKind] =
        [.accelerometer, .location, .watchAccelerometer, .survey] + healthKinds

    private override init() {
        super.init()
        locationManager.delegate = self
        // A coordinate label, not research data. Best accuracy with no filter would
        // pin the GPS on for the whole app (CoreLocation serves its most demanding
        // client) and override AdaptiveLocationManager's low-power mode.
        locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        locationManager.distanceFilter = 10
        // 4 Hz is as fast as anyone can read a number.
        motion.accelerometerUpdateInterval = 0.25
        motion.gyroUpdateInterval = 0.25
    }

    // MARK: - Lifecycle

    /// Sensors tab on screen and app active. Safe to call repeatedly.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        print("SensorFeed: started (motion + GPS on)")
        Logger.shared.append("SensorFeed: started (motion + GPS on)")

        if motion.isAccelerometerAvailable {
            motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
                // isRunning drops updates already queued when stop() ran.
                guard let self, self.isRunning, let a = data?.acceleration else { return }
                self.accelerometer = Self.axes(a.x, a.y, a.z, unit: "g")
            }
        }
        if motion.isGyroAvailable {
            motion.startGyroUpdates(to: .main) { [weak self] data, _ in
                guard let self, self.isRunning, let r = data?.rotationRate else { return }
                self.gyroscope = Self.axes(r.x, r.y, r.z, unit: "rad/s")
            }
        }
        let status = locationManager.authorizationStatus
        if status == .authorizedAlways || status == .authorizedWhenInUse {
            locationManager.startUpdatingLocation()
        }
        refresh()
    }

    /// Tab left or app no longer active. Live values are blanked so nothing
    /// stale stays on screen. Safe to call repeatedly.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        print("SensorFeed: stopped (motion + GPS off)")
        Logger.shared.append("SensorFeed: stopped (motion + GPS off)")
        motion.stopAccelerometerUpdates()
        motion.stopGyroUpdates()
        locationManager.stopUpdatingLocation()
        accelerometer = nil
        gyroscope = nil
        location = nil
    }

    /// Shows the saved values at once, then re-queries Apple Health and updates.
    func refresh() {
        loadFromStore()
        SensorStatusStore.shared.refreshHealthKitSamples { [weak self] in
            self?.loadFromStore()
        }
    }

    private func loadFromStore() {
        let store = SensorStatusStore.shared
        var values: [SensorKind: String] = [:]
        for kind in Self.healthKinds {
            if let tile = store.homeTile(for: kind) {
                values[kind] = kind.formatted(tile.value)
            }
        }
        health = values

        var dates: [SensorKind: Date] = [:]
        for kind in Self.recordedKinds {
            dates[kind] = store.entry(for: kind)?.date
        }
        lastRecorded = dates
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isRunning, let fix = locations.last else { return }
        location = String(format: "%.4f, %.4f (±%.0fm)",
                          fix.coordinate.latitude, fix.coordinate.longitude, fix.horizontalAccuracy)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("SensorFeed location error: \(error.localizedDescription)")
    }

    // MARK: - Formatting

    /// "Last recorded: Today, 3:45 PM" / "Yesterday, 9:10 PM" / "Sep 8, 2:00 PM".
    func lastRecordedText(for kind: SensorKind) -> String {
        guard let date = lastRecorded[kind] else { return "Not recorded yet" }
        let calendar = Calendar.current
        let day: String
        if calendar.isDateInToday(date) {
            day = "Today"
        } else if calendar.isDateInYesterday(date) {
            day = "Yesterday"
        } else {
            day = date.formatted(.dateTime.month(.abbreviated).day())
        }
        return "Last recorded: \(day), \(date.formatted(date: .omitted, time: .shortened))"
    }

    /// x and y share a line, z sits beneath, so all three fit a narrow row.
    private static func axes(_ x: Double, _ y: Double, _ z: Double, unit: String) -> String {
        String(format: "x: %.2f   y: %.2f\nz: %.2f %@", x, y, z, unit)
    }
}

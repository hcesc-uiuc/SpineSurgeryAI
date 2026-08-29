//
//  SensorFeed.swift
//  SensingApp
//
//  Everything the Sensors tab displays, behind start() / stop().
//
//  This is the live PREVIEW layer, not the research pipeline. The recorders
//  (AcclerometerRecorder, AdaptiveLocationManager, the SensorKit fetchers,
//  HealthkitRecorder) are separate and keep running regardless of this object.
//
//  Deliberately does NOT use HealthKitManager: its init registers an
//  HKObserverQuery plus background delivery for every metric type, which nothing
//  stops, so the app gets woken on every new sample to refresh a screen that is
//  usually not visible. Health values come from SensorStatusStore's one-shot
//  queries instead — the same path HomeView uses.
//

import Foundation
import CoreMotion
import CoreLocation
internal import Combine

final class SensorFeed: ObservableObject {

    static let shared = SensorFeed()

    @Published private(set) var accelerometer: String?
    @Published private(set) var gyroscope: String?
    @Published private(set) var location: String?
    @Published private(set) var health: [SensorKind: String] = [:]

    let motion = MotionManager()
    let locationManager = LiveLocationManager.shared

    private var cancellables = Set<AnyCancellable>()

    static let healthKinds: [SensorKind] = [
        .heartRate, .heartRateVariability, .steps, .bloodOxygen, .activeEnergy, .sleep
    ]

    private init() {
        motion.$accelerometerData
            .sink { [weak self] data in
                guard let a = data?.acceleration else { self?.accelerometer = nil; return }
                self?.accelerometer = Self.axes(a.x, a.y, a.z, unit: "g")
            }
            .store(in: &cancellables)

        motion.$gyroscopeData
            .sink { [weak self] data in
                guard let r = data?.rotationRate else { self?.gyroscope = nil; return }
                self?.gyroscope = Self.axes(r.x, r.y, r.z, unit: "rad/s")
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(locationManager.$coordinate, locationManager.$horizontalAccuracy)
            .sink { [weak self] coordinate, accuracy in
                self?.location = Self.coordinateText(coordinate, accuracy: accuracy)
            }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    /// Call when the Sensors tab is on screen and the app is active.
    func start() {
        motion.start()
        locationManager.start()
        refreshHealth()
    }

    /// Call when the tab is left or the app leaves the foreground. Both managers
    /// nil their published values on stop, which clears the strings above, so no
    /// stale reading is left on screen pretending to be live.
    func stop() {
        motion.stop()
        locationManager.stop()
    }

    /// One-shot HealthKit read. Cumulative types (steps, active energy) come back
    /// as the day's total, so the row moves by the amount actually walked.
    func refreshHealth() {
        SensorStatusStore.shared.refreshHealthKitSamples { [weak self] in
            guard let self else { return }
            var values: [SensorKind: String] = [:]
            for kind in Self.healthKinds {
                if let tile = SensorStatusStore.shared.homeTile(for: kind) {
                    values[kind] = kind.formatted(tile.value)
                }
            }
            self.health = values
        }
    }

    // MARK: - Formatting

    /// x and y share a line, z sits beneath, so all three fit a narrow row.
    private static func axes(_ x: Double, _ y: Double, _ z: Double, unit: String) -> String {
        String(format: "x: %.2f   y: %.2f\nz: %.2f %@", x, y, z, unit)
    }

    private static func coordinateText(_ coordinate: CLLocationCoordinate2D?,
                                       accuracy: CLLocationAccuracy?) -> String? {
        guard let coordinate else { return nil }
        let suffix = accuracy.map { String(format: " (±%.0fm)", $0) } ?? ""
        return String(format: "%.4f, %.4f%@", coordinate.latitude, coordinate.longitude, suffix)
    }
}

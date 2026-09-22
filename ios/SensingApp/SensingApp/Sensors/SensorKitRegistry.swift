//
//  SensorKitRegistry.swift
//  SensingApp
//
//  The single list of every SensorKit sensor the app collects. All wiring
//  (authorization, startRecording, background fetch, debug) iterates this
//  array, so adding a sensor is: write a SensorKitFetcher subclass, add one
//  line here, and add its SRSensorUsage<Name> key to Info.plist.
//

import SensorKit

enum SensorKitRegistry {

    /// Every sensor fetcher, in one place.
    static let all: [SensorKitFetcher] = [
        SensorKitAccelerometerFetcher.shared,
        SensorKitGyroscopeFetcher.shared,
        SensorKitWristDetectionFetcher.shared,
        // Issue #57 - iPhone usage/environment sensors
        SensorKitAmbientPressureFetcher.shared,
        SensorKitPhoneUsageFetcher.shared,
        SensorKitMessagesUsageFetcher.shared,
        SensorKitKeyboardMetricsFetcher.shared,
        // Issue #74
        SensorKitSleepSessionsFetcher.shared,
    ]

    /// Sensors read by the older standalone fetchers (not SensorKitFetcher
    /// subclasses). They still need authorization.
    static let legacySensors: Set<SRSensor> = [
        .photoplethysmogram,
        .ambientLightSensor,
        .deviceUsageReport,
        .wristTemperature,
        .heartRate,
    ]

    /// Sensors whose entitlement value or Info.plist key is not confirmed on a
    /// device yet. Requested in their own call so a failure there cannot block
    /// authorization of everything else.
    static let unconfirmedSensors: Set<SRSensor> = [.sleepSessions]

    /// The main authorization set: every registry and legacy sensor, minus the
    /// unconfirmed ones.
    static var sensors: Set<SRSensor> {
        Set(all.map { $0.sensor }).union(legacySensors).subtracting(unconfirmedSensors)
    }

    /// Requests the main set, then the unconfirmed set. `completion` gets the
    /// main set's error (nil on success); unconfirmed failures are only logged.
    static func requestAuthorization(completion: @escaping (Error?) -> Void) {
        SRSensorReader.requestAuthorization(sensors: sensors) { error in
            SRSensorReader.requestAuthorization(sensors: unconfirmedSensors) { extraError in
                if let extraError {
                    print("SensorKit auth error (unconfirmed sensors): \(extraError)")
                    Logger.shared.append("SensorKit auth error (unconfirmed sensors): \(extraError)")
                }
                completion(error)
            }
        }
    }

    /// For participants who authorized SensorKit before a sensor was added:
    /// asks again only if they finished SensorKit onboarding and some registry
    /// sensor has never been decided. Participants still onboarding are left
    /// to PermissionsFlowView.
    static func requestMissingAuthorizationIfNeeded() {
        let onboarded = SRAuthorizationStatus(
            rawValue: UserDefaults.standard.integer(forKey: "sk_authorization_status")) == .authorized
        guard onboarded else { return }
        let undecided = all.filter { $0.authorizationStatus == .notDetermined }
        guard !undecided.isEmpty else { return }
        print("SensorKit: \(undecided.count) sensor(s) not yet authorized, requesting")
        requestAuthorization { _ in
            all.forEach { $0.startRecordingWithAuthorizationCheck() }
        }
    }
}

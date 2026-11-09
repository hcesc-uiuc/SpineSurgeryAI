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
        .accelerometer,
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

    // Sensors added after onboarding, or turned off in Settings, are
    // caught by PermissionAudit, which re-shows the SensorKit card.

    /// Required sensors that are not currently authorized. Fresh readers, so a
    /// change made in Settings is seen right away.
    static var missingSensors: [SRSensor] {
        #if targetEnvironment(simulator)
        return []
        #else
        return sensors.filter { SRSensorReader(sensor: $0).authorizationStatus != .authorized }
        #endif
    }

    /// True when some required sensor was never asked about, so the system
    /// sheet can still be shown for it.
    static var hasUndecidedSensors: Bool {
        sensors.contains { SRSensorReader(sensor: $0).authorizationStatus == .notDetermined }
    }

    /// Starts every reader: the registry ones plus the legacy standalone ones.
    static func startAllRecording(checkAuthorization: Bool) {
        if checkAuthorization {
            all.forEach { $0.startRecordingWithAuthorizationCheck() }
            SensorKitAccelerometerFetcher.shared.startRecordingWithAuthorizationCheck()
            SensorKitPPGFetcher.shared.startRecordingWithAuthorizationCheck()
            SensorKitAmbientLightFetcher.shared.startRecordingWithAuthorizationCheck()
            SensorKitDeviceUsageFetcher.shared.startRecordingWithAuthorizationCheck()
            SensorKitWristTemperatureFetcher.shared.startRecordingWithAuthorizationCheck()
            SensorKitHeartRateFetcher.shared.startRecordingWithAuthorizationCheck()
        } else {
            all.forEach { $0.startRecording() }
            SensorKitAccelerometerFetcher.shared.startRecording()
            SensorKitPPGFetcher.shared.startRecording()
            SensorKitAmbientLightFetcher.shared.startRecording()
            SensorKitDeviceUsageFetcher.shared.startRecording()
            SensorKitWristTemperatureFetcher.shared.startRecording()
            SensorKitHeartRateFetcher.shared.startRecording()
        }
    }
}

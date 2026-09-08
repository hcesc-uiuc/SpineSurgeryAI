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
    ]

    /// The authorization set, derived from `all`.
    static var sensors: Set<SRSensor> { Set(all.map { $0.sensor }) }
}

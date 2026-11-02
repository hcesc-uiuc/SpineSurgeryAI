//
//  SensorKitStatusTests.swift
//  SensingAppTests
//
//  Issue #85: Debug tab SensorKit status panel.
//

import Foundation
import SensorKit
import XCTest
@testable import SensingApp

final class SensorKitStatusTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    private func row(_ auth: SRAuthorizationStatus, newest: Date?) -> SensorKitStatusRow {
        SensorKitStatusRow(sensor: SensorKitStatusSensor.all[0], authorization: auth,
                           lastFetchEnd: nil, newestSample: newest,
                           waitingFiles: 0, waitingBytes: 0, lastUploaded: nil)
    }

    func testVerdicts() {
        XCTAssertEqual(row(.denied, newest: now).verdict(now: now), .notAuthorized)
        XCTAssertEqual(row(.authorized, newest: nil).verdict(now: now), .noData)
        XCTAssertEqual(row(.authorized, newest: now.addingTimeInterval(-2 * 24 * 3600)).verdict(now: now), .ok)
        XCTAssertEqual(row(.authorized, newest: now.addingTimeInterval(-4 * 24 * 3600)).verdict(now: now), .stale)
    }

    func testEverySensorHasItsOwnFilePrefix() {
        let prefixes = SensorKitStatusSensor.all.map(\.filePrefix)
        XCTAssertEqual(prefixes.count, 13)
        XCTAssertEqual(Set(prefixes).count, prefixes.count)
    }

    func testFileMatchingDoesNotMixSimilarPrefixes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sk-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["sensorkit_accel_watch_00001.csv", "sensorkit_accel_watch_00002.csv.part",
                     "sensorkit_accel_phone_00000.csv", "accelerometer_2026-11-01.csv"] {
            try Data("h\n".utf8).write(to: dir.appendingPathComponent(name))
        }

        let found = SensorKitStatusRow.files(in: dir, prefix: "sensorkit_accel_watch").map(\.lastPathComponent).sorted()

        XCTAssertEqual(found, ["sensorkit_accel_watch_00001.csv", "sensorkit_accel_watch_00002.csv.part"])
    }
}

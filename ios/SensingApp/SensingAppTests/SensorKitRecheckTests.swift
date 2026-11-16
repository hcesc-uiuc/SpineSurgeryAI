//
//  SensorKitRecheckTests.swift
//  SensingAppTests
//
//  Issue #85: chunks that came back short (SensorKit had not released the
//  data yet) are fetched again once they are 48 h old.
//

import Foundation
import XCTest
@testable import SensingApp

final class SensorKitRecheckTests: XCTestCase {

    private let defaults = UserDefaults(suiteName: "SensorKitRecheckTests")!
    private let now = Date(timeIntervalSinceReferenceDate: 815_000_000)
    private let hour: TimeInterval = 3600
    private let p = "sensorkit_gyro_phone"

    override func setUp() { defaults.removePersistentDomain(forName: "SensorKitRecheckTests") }

    func testMissingPart() {
        let a = now.addingTimeInterval(-30 * hour), b = a.addingTimeInterval(0.5 * hour)
        // nothing came back: the whole window
        XCTAssertEqual(SensorKitRecheck.missingPart(from: a, to: b, newest: nil)?.0, a)
        // stopped 20 min in: the rest
        let newest = a.addingTimeInterval(10 * 60)
        XCTAssertEqual(SensorKitRecheck.missingPart(from: a, to: b, newest: newest)?.0, newest)
        // ran to within 5 min of the end: complete
        XCTAssertNil(SensorKitRecheck.missingPart(from: a, to: b, newest: b.addingTimeInterval(-60)))
    }

    func testAddSplitsIntoChunksAndDoesNotDuplicate() {
        let a = now.addingTimeInterval(-60 * hour)
        SensorKitRecheck.add(p, from: a, to: a.addingTimeInterval(2 * hour), chunk: 0.5 * hour, defaults: defaults)
        SensorKitRecheck.add(p, from: a, to: a.addingTimeInterval(2 * hour), chunk: 0.5 * hour, defaults: defaults)
        XCTAssertEqual(SensorKitRecheck.windows(p, defaults: defaults).count, 4)
    }

    func testOnlyDueOnce48HoursOld() {
        let recent = now.addingTimeInterval(-30 * hour)
        SensorKitRecheck.add(p, from: recent, to: recent.addingTimeInterval(hour), chunk: hour, defaults: defaults)
        XCTAssertNil(SensorKitRecheck.due(p, now: now, defaults: defaults))
        let old = now.addingTimeInterval(-60 * hour)
        SensorKitRecheck.add(p, from: old, to: old.addingTimeInterval(hour), chunk: hour, defaults: defaults)
        XCTAssertEqual(SensorKitRecheck.due(p, now: now, defaults: defaults)?.from, old.timeIntervalSinceReferenceDate)
    }

    func testExpiredWindowsAreDropped() {
        let gone = now.addingTimeInterval(-7 * 24 * hour)
        SensorKitRecheck.add(p, from: gone, to: gone.addingTimeInterval(hour), chunk: hour, defaults: defaults)
        XCTAssertEqual(SensorKitRecheck.dropExpired(p, now: now, defaults: defaults), 1)
        XCTAssertTrue(SensorKitRecheck.windows(p, defaults: defaults).isEmpty)
    }

    func testRemove() {
        let a = now.addingTimeInterval(-60 * hour)
        SensorKitRecheck.add(p, from: a, to: a.addingTimeInterval(hour), chunk: hour, defaults: defaults)
        let w = SensorKitRecheck.windows(p, defaults: defaults)[0]
        SensorKitRecheck.remove(p, w, defaults: defaults)
        XCTAssertTrue(SensorKitRecheck.windows(p, defaults: defaults).isEmpty)
    }

    func testImportFileQueuesKnownSensorsAndIsReadOnce() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("recheck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(SensorKitRecheck.importFileName)
        let json = """
        [{"sensor":"sensorkit_gyro_phone","from":"2026-11-13T22:06:00Z","to":"2026-11-13T23:26:00Z"},
         {"sensor":"sensorkit_unknown_phone","from":"2026-11-13T22:06:00Z","to":"2026-11-13T23:26:00Z"}]
        """
        try Data(json.utf8).write(to: url)

        let n = SensorKitRecheck.importFile(url, chunks: [p: 0.5 * hour], defaults: defaults)

        XCTAssertEqual(n, 1)
        XCTAssertEqual(SensorKitRecheck.windows(p, defaults: defaults).count, 3)   // 80 min in 30 min pieces
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".imported"))
    }
}

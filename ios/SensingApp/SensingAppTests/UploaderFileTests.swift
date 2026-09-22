//
//  UploaderFileTests.swift
//  SensingAppTests
//
//  Issue #74: processed/ name collisions and header-only SensorKit CSVs.
//

import Foundation
import XCTest
@testable import SensingApp

final class UploaderFileTests: XCTestCase {

    private var dir: URL!
    private var processed: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("uploader-tests-\(UUID().uuidString)")
        processed = dir.appendingPathComponent("processed")
        try FileManager.default.createDirectory(at: processed, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func file(_ name: String, _ contents: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private var fixedDate: Date {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 17; c.hour = 19; c.minute = 30; c.second = 14
        return Calendar.current.date(from: c)!
    }

    // MARK: processedDestination

    func testDestinationKeepsNameWhenFree() throws {
        let f = try file("sensorkit_pressure_phone_00000.csv", "h\n1\n")
        let dest = Uploader.processedDestination(for: f, in: processed)
        XCTAssertEqual(dest.lastPathComponent, "sensorkit_pressure_phone_00000.csv")
    }

    func testDestinationAddsTimestampWhenNameTaken() throws {
        let f = try file("sensorkit_pressure_phone_00000.csv", "h\n1\n")
        try Data().write(to: processed.appendingPathComponent(f.lastPathComponent))
        let dest = Uploader.processedDestination(for: f, in: processed, now: fixedDate)
        XCTAssertEqual(dest.lastPathComponent, "sensorkit_pressure_phone_00000_20260917-193014.csv")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    func testDestinationAddsCounterWhenTimestampAlsoTaken() throws {
        let f = try file("sensorkit_pressure_phone_00000.csv", "h\n1\n")
        try Data().write(to: processed.appendingPathComponent("sensorkit_pressure_phone_00000.csv"))
        try Data().write(to: processed.appendingPathComponent("sensorkit_pressure_phone_00000_20260917-193014.csv"))
        let dest = Uploader.processedDestination(for: f, in: processed, now: fixedDate)
        XCTAssertEqual(dest.lastPathComponent, "sensorkit_pressure_phone_00000_20260917-193014_2.csv")
    }

    func testMoveSucceedsAfterCollision() throws {
        // The Sep 17 re-upload loop: the same name uploaded twice.
        let first = try file("sensorkit_keyboard_phone_00000.csv", "h\n1\n")
        try FileManager.default.moveItem(at: first, to: Uploader.processedDestination(for: first, in: processed))
        let second = try file("sensorkit_keyboard_phone_00000.csv", "h\n2\n")
        XCTAssertNoThrow(try FileManager.default.moveItem(at: second, to: Uploader.processedDestination(for: second, in: processed)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path), "file must leave to-be-processed")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: processed.path).count, 2)
    }

    // MARK: hasDataRows

    func testHeaderOnlyHasNoRows() throws {
        XCTAssertFalse(Uploader.hasDataRows(try file("a.csv", "timestamp_unix,pressure_kpa,temperature_c\n")))
    }

    func testHeaderWithoutNewlineHasNoRows() throws {
        XCTAssertFalse(Uploader.hasDataRows(try file("b.csv", "timestamp_unix,x,y,z")))
    }

    func testEmptyFileHasNoRows() throws {
        XCTAssertFalse(Uploader.hasDataRows(try file("c.csv", "")))
    }

    func testBlankTrailingLinesAreNotRows() throws {
        XCTAssertFalse(Uploader.hasDataRows(try file("d.csv", "timestamp_unix,x\n\n  \n")))
    }

    func testOneRowCounts() throws {
        XCTAssertTrue(Uploader.hasDataRows(try file("e.csv", "timestamp_unix,x\n1758130214.000000,1\n")))
    }

    func testMissingFileHasNoRows() {
        XCTAssertFalse(Uploader.hasDataRows(dir.appendingPathComponent("missing.csv")))
    }
}

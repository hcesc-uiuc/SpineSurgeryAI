//
//  SensorKitChunkTests.swift
//  SensingAppTests
//
//  Issue #85: a chunk that does not complete is cut off, and every run logs
//  why it stopped.
//

import Foundation
import XCTest
@testable import SensingApp

final class SensorKitChunkTests: XCTestCase {

    private var dir: URL!
    private let defaults = UserDefaults(suiteName: "SensorKitChunkTests")!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("chunk-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaults.removePersistentDomain(forName: "SensorKitChunkTests")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func part(_ text: String) throws -> URL {
        let url = dir.appendingPathComponent("sensorkit_gyro_phone_00001.csv.part")
        try Data(text.utf8).write(to: url)
        return url
    }

    func testFailedChunkIsCutOffAtTheCommittedSize() throws {
        let committed = "timestamp_unix,x,y,z\n1,0,0,0\n"
        let url = try part(committed + "2,0,0,0\n3,0,0")   // second chunk half written
        defaults.set(committed.utf8.count, forKey: SensorKitFetcher.committedBytesKey(for: url.lastPathComponent))

        XCTAssertTrue(SensorKitFetcher.trimToCommitted(url, defaults: defaults))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), committed)
        XCTAssertNil(defaults.object(forKey: SensorKitFetcher.committedBytesKey(for: url.lastPathComponent)))
    }

    func testFileWithNoCompletedChunkIsDeleted() throws {
        let url = try part("timestamp_unix,x,y,z\n1,0,0,0\n")
        defaults.set(0, forKey: SensorKitFetcher.committedBytesKey(for: url.lastPathComponent))

        XCTAssertFalse(SensorKitFetcher.trimToCommitted(url, defaults: defaults))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFileFromAnOlderBuildIsLeftAlone() throws {
        let text = "timestamp_unix,x,y,z\n1,0,0,0\n2,0,0,0\n"
        let url = try part(text)   // no committed size recorded
        XCTAssertTrue(SensorKitFetcher.trimToCommitted(url, defaults: defaults))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
    }

    func testStopReasons() {
        XCTAssertEqual(SensorKitFetcher.stopReason(caughtUp: true, chunks: 3, bytesThisRun: 0, freeBytes: 0), "caught up")
        XCTAssertEqual(SensorKitFetcher.stopReason(caughtUp: false, chunks: 1, bytesThisRun: 0,
                                                   freeBytes: SensorKitFetcher.minFreeBytes - 1), "low storage")
        XCTAssertEqual(SensorKitFetcher.stopReason(caughtUp: false, chunks: 5,
                                                   bytesThisRun: SensorKitFetcher.maxBytesPerRun, freeBytes: nil),
                       "250 MB run limit")
        XCTAssertEqual(SensorKitFetcher.stopReason(caughtUp: false, chunks: SensorKitFetcher.maxChunksPerRun,
                                                   bytesThisRun: 0, freeBytes: nil), "chunk limit")
    }

    func testCommittedSizeLargerThanFileNeverGrowsIt() throws {
        let text = "timestamp_unix,x,y,z\n1,0,0,0\n"
        let url = try part(text)
        defaults.set(text.utf8.count + 500, forKey: SensorKitFetcher.committedBytesKey(for: url.lastPathComponent))

        XCTAssertTrue(SensorKitFetcher.trimToCommitted(url, defaults: defaults))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
    }
}

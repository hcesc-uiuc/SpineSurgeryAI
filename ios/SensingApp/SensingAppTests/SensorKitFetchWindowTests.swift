//
//  SensorKitFetchWindowTests.swift
//  SensingAppTests
//
//  Issue #85: SensorKit fetches go in short chunks that each commit, so a
//  high-rate sensor (gyroscope) keeps moving forward.
//

import Foundation
import XCTest
@testable import SensingApp

final class SensorKitFetchWindowTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 815_000_000)
    private let hour: TimeInterval = 3600

    private func ref(_ date: Date) -> Double { date.timeIntervalSinceReferenceDate }

    func testFirstFetchStartsTwoDaysBackAndIsOneChunk() throws {
        let w = try XCTUnwrap(SensorKitFetcher.nextWindow(lastFetchEnd: 0, now: now, chunk: hour))
        XCTAssertEqual(w.from, now.addingTimeInterval(-48 * hour))
        XCTAssertEqual(w.to, now.addingTimeInterval(-47 * hour))
    }

    func testContinuesFromLastFetchEnd() throws {
        let last = now.addingTimeInterval(-30 * hour)
        let w = try XCTUnwrap(SensorKitFetcher.nextWindow(lastFetchEnd: ref(last), now: now, chunk: hour))
        XCTAssertEqual(w.from, last)
        XCTAssertEqual(w.to, last.addingTimeInterval(hour))
    }

    func testLastChunkStopsAtTheEmbargo() throws {
        let last = now.addingTimeInterval(-25.5 * hour)
        let w = try XCTUnwrap(SensorKitFetcher.nextWindow(lastFetchEnd: ref(last), now: now, chunk: 6 * hour))
        XCTAssertEqual(w.to, now.addingTimeInterval(-25 * hour))
    }

    func testNothingNewInsideTheEmbargo() {
        let last = now.addingTimeInterval(-25 * hour)
        XCTAssertNil(SensorKitFetcher.nextWindow(lastFetchEnd: ref(last), now: now, chunk: hour))
    }

    func testStartOlderThanSevenDaysIsClamped() throws {
        // The gyroscope was stuck at a start a month back.
        let last = now.addingTimeInterval(-30 * 24 * hour)
        let w = try XCTUnwrap(SensorKitFetcher.nextWindow(lastFetchEnd: ref(last), now: now, chunk: hour))
        XCTAssertEqual(w.from, now.addingTimeInterval(-7 * 24 * hour))
    }

    func testChunksReachTheEmbargoWithinTheRunCap() {
        var last = ref(now.addingTimeInterval(-7 * 24 * hour))
        var chunks = 0
        while let w = SensorKitFetcher.nextWindow(lastFetchEnd: last, now: now, chunk: hour) {
            last = ref(w.to)
            chunks += 1
        }
        XCTAssertLessThan(chunks, SensorKitFetcher.maxChunksPerRun)
        XCTAssertEqual(last, ref(now.addingTimeInterval(-25 * hour)))
    }
}

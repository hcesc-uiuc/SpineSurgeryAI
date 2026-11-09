//
//  SensorRunLogTests.swift
//  SensingAppTests
//
//  Issue #85: per-run fetch records and the fetch gate's decisions.
//

import Foundation
import XCTest
@testable import SensingApp

final class SensorRunLogTests: XCTestCase {

    private let defaults = UserDefaults(suiteName: "SensorRunLogTests")!
    private let now = Date(timeIntervalSince1970: 1_794_000_000)

    override func setUp() { defaults.removePersistentDomain(forName: "SensorRunLogTests") }

    private func run(hoursAgo: Double, samples: Int, dataEnd: Date? = nil) -> SensorRunRecord {
        SensorRunRecord(finishedAt: now.addingTimeInterval(-hoursAgo * 3600), trigger: "test",
                        samples: samples, unit: "rows", dataStart: dataEnd?.addingTimeInterval(-3600),
                        dataEnd: dataEnd, chunks: 2, megabytes: 1, stopReason: "caught up", failed: false)
    }

    func testKeepsOnlyTheLast50() {
        for i in 0..<60 { SensorRunLog.record(run(hoursAgo: 0, samples: i), kind: .gyroscope, defaults: defaults) }
        let all = SensorRunLog.records(.gyroscope, defaults: defaults)
        XCTAssertEqual(all.count, 50)
        XCTAssertEqual(all.first?.samples, 10)
        XCTAssertEqual(all.last?.samples, 59)
    }

    func testTotalsOnlyCountRunsInTheWindow() {
        let d1 = now.addingTimeInterval(-30 * 3600), d2 = now.addingTimeInterval(-26 * 3600)
        SensorRunLog.record(run(hoursAgo: 30, samples: 100, dataEnd: now.addingTimeInterval(-60 * 3600)), kind: .pressure, defaults: defaults)
        SensorRunLog.record(run(hoursAgo: 5, samples: 200, dataEnd: d1), kind: .pressure, defaults: defaults)
        SensorRunLog.record(run(hoursAgo: 1, samples: 300, dataEnd: d2), kind: .pressure, defaults: defaults)

        let t = SensorRunLog.totals(.pressure, window: 24 * 3600, now: now, defaults: defaults)
        XCTAssertEqual(t, SensorRunLog.Totals(runs: 2, samples: 500, dataEnd: d2))
        XCTAssertEqual(SensorRunLog.totals(.pressure, window: 72 * 3600, now: now, defaults: defaults).runs, 3)
    }

    func testRunWithoutDataSaysSo() {
        XCTAssertTrue(SensorRunLog.describe(run(hoursAgo: 0, samples: 0)).hasSuffix("no data"))
    }

    func testSensorsAreKeptApart() {
        SensorRunLog.record(run(hoursAgo: 0, samples: 1), kind: .gyroscope, defaults: defaults)
        XCTAssertTrue(SensorRunLog.records(.accelerometer, defaults: defaults).isEmpty)
    }

    // MARK: fetch gate

    func testGateDecisions() {
        typealias G = BackgroundScheduler
        XCTAssertEqual(G.fetchDecision(unlocked: false, running: false, minutesSinceSuccess: 999, minutesSinceAttempt: 999),
                       .skip("phone locked"))
        XCTAssertEqual(G.fetchDecision(unlocked: true, running: true, minutesSinceSuccess: 999, minutesSinceAttempt: 999),
                       .skip("a run is still going"))
        XCTAssertNotEqual(G.fetchDecision(unlocked: true, running: false, minutesSinceSuccess: 30, minutesSinceAttempt: 999), .start)
        XCTAssertNotEqual(G.fetchDecision(unlocked: true, running: false, minutesSinceSuccess: 999, minutesSinceAttempt: 5), .start)
        XCTAssertEqual(G.fetchDecision(unlocked: true, running: false, minutesSinceSuccess: 61, minutesSinceAttempt: 11), .start)
    }
}

//
//  RunEnvironmentTests.swift
//  SensingAppTests
//
//  The guard that keeps launch-time production calls off during test runs.
//

import XCTest
@testable import SensingApp

final class RunEnvironmentTests: XCTestCase {
    func testUnitTestHostIsDetected() {
        XCTAssertTrue(RunEnvironment.isUnitTestHost)
    }
}

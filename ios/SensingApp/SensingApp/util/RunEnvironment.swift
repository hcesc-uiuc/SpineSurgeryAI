//
//  RunEnvironment.swift
//  SensingApp
//
//  Unit tests run inside the real app (TEST_HOST), so its launch code runs
//  too. Launch-time calls to the production backend check this and stay off,
//  so a test run can't register junk device tokens or refresh a real session.
//

import Foundation

enum RunEnvironment {
    /// True when XCTest launched this process as the unit-test host.
    static let isUnitTestHost =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}

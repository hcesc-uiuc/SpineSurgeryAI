//
//  BackgroundSettingsTests.swift
//  SensingAppTests
//
//  Issue #85: refused background tasks are explained, and only one upload
//  run happens at a time.
//

import BackgroundTasks
import Foundation
import XCTest
@testable import SensingApp

final class BackgroundSettingsTests: XCTestCase {

    func testUnavailableNamesLowPowerModeAndBackgroundRefresh() {
        let e = BGTaskScheduler.Error(.unavailable)
        XCTAssertTrue(BackgroundScheduler.describeSubmitError(e).contains("Low Power Mode"))
        XCTAssertTrue(BackgroundScheduler.describeSubmitError(e).contains("Background App Refresh"))
    }

    func testOtherReasons() {
        XCTAssertTrue(BackgroundScheduler.describeSubmitError(BGTaskScheduler.Error(.tooManyPendingTaskRequests))
            .contains("too many"))
        XCTAssertTrue(BackgroundScheduler.describeSubmitError(BGTaskScheduler.Error(.notPermitted))
            .contains("not permitted"))
    }

    func testOnlyOneUploadRunAtATime() {
        XCTAssertTrue(Uploader.beginRun())
        XCTAssertFalse(Uploader.beginRun())
        Uploader.endRun()
        XCTAssertTrue(Uploader.beginRun())
        Uploader.endRun()
    }

    func testSecondRunWaitsForTheFirstInsteadOfSkipping() async {
        XCTAssertTrue(Uploader.beginRun())
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { Uploader.endRun() }
        let got = await Uploader.acquireRun(timeout: 10)
        XCTAssertTrue(got)
        Uploader.endRun()
    }

    func testWaitingGivesUpAfterTheTimeout() async {
        XCTAssertTrue(Uploader.beginRun())
        let got = await Uploader.acquireRun(timeout: 0)
        XCTAssertFalse(got)
        Uploader.endRun()
    }

    func testSensorUploadsNeverUseCellular() {
        XCTAssertFalse(Uploader.wifiOnlySession.configuration.allowsCellularAccess)
        XCTAssertFalse(Uploader.wifiOnlySession.configuration.allowsExpensiveNetworkAccess)
    }
}

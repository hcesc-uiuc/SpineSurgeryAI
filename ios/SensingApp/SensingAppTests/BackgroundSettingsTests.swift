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
}

//
//  LogoutRevocationTests.swift
//  SensingAppTests
//
//  Issue #82: logout() read the refresh token inside a Task that only ran
//  after clearTokens(), so POST /auth/logout was never sent and the server
//  kept the token valid for 365 days. Network calls are stubbed.
//

import Foundation
import XCTest
@testable import SensingApp

@MainActor
final class LogoutRevocationTests: XCTestCase {

    private let refreshKey = "journey_refresh_token"
    private let accessKey  = "journey_access_token"
    private var auth: SecureAuthManager!

    override func setUp() async throws {
        try await super.setUp()
        KeychainManager.shared.delete(key: refreshKey)
        KeychainManager.shared.delete(key: accessKey)
        UploadStubProtocol.reset()
        UploadStubProtocol.handler = { _, _ in .http(200, #"{"ok": true}"#) }

        // Created with an empty Keychain so init doesn't start a silent refresh
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UploadStubProtocol.self]
        auth = SecureAuthManager()
        auth.session = URLSession(configuration: config)
        auth.baseURL = "https://stub.test"
    }

    override func tearDown() async throws {
        KeychainManager.shared.delete(key: refreshKey)
        KeychainManager.shared.delete(key: accessKey)
        UploadStubProtocol.reset()
        auth = nil
        try await super.tearDown()
    }

    func testLogoutSendsTheStoredRefreshTokenToTheServer() async throws {
        KeychainManager.shared.save(key: refreshKey, data: Data("rt-123".utf8))
        KeychainManager.shared.save(key: accessKey, data: Data("at-456".utf8))
        auth.isAuthenticated = true

        let revoke = try XCTUnwrap(auth.logout())
        await revoke.value

        let sent = UploadStubProtocol.requests(path: "/auth/logout")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.method, "POST")
        let body = try XCTUnwrap(sent.first?.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, ["refresh_token": "rt-123"])

        // Local sign-out still happens
        XCTAssertNil(KeychainManager.shared.read(key: refreshKey))
        XCTAssertNil(KeychainManager.shared.read(key: accessKey))
        XCTAssertFalse(auth.isAuthenticated)
    }

    func testLogoutWithoutASessionSendsNothing() async {
        XCTAssertNil(auth.logout())
        XCTAssertTrue(UploadStubProtocol.requests(path: "/auth/logout").isEmpty)
        XCTAssertFalse(auth.isAuthenticated)
    }
}

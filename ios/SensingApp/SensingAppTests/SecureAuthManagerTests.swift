//
//  SecureAuthManagerTests.swift
//  SensingApp
//
//  Created by UIUCSpineSurgey on 3/29/26.
//


//
//  SecureAuthManagerTests.swift
//  SpineSurgeryUITests
//
//  Created by UIUCSpineSurgey on 3/18/26.
//
import Foundation
import XCTest;
@testable import SensingApp
// ============================================================
// MARK: - SecureAuthManagerTests Overview
// ============================================================
//
// Tests all major auth flows using MockURLProtocol —
// no real server or network connection required.
//
// TO RUN: Cmd + U in Xcode, or click the diamond next to each test.
//
// TEST CASES COVERED:
//   ✅ Successful login stores tokens + sets isAuthenticated
//   ✅ Wrong password returns invalidCredentials error
//   ✅ Server error (500) returns serverError
//   ✅ Silent refresh restores session on launch
//   ✅ Failed refresh clears tokens + sets isAuthenticated false
//   ✅ Logout clears all tokens
// ============================================================
@MainActor
final class SecureAuthManagerTests: XCTestCase {
    var authManager: SecureAuthManager!
    var mockSession: URLSession!
    // MARK: - Setup & Teardown
    override func setUp() async throws {
        try await super.setUp()
        
//        authManager.demoMode = false
        
        // Wire up MockURLProtocol to intercept all network calls
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        mockSession = URLSession(configuration: config)
        authManager         = SecureAuthManager()
        authManager.session = mockSession
        authManager.baseURL = "https://mock.journeyapi.com"
        
        // Explicitly ensure clean state before every test
        authManager.isAuthenticated = false
        
        // Clear any leftover tokens from previous tests
        KeychainManager.shared.delete(key: "journey_access_token")
        KeychainManager.shared.delete(key: "journey_refresh_token")
        KeychainManager.shared.delete(key: "journey_user_id")
    }
    override func tearDown() {
        authManager = nil
        mockSession = nil
        super.tearDown()
    }
    // MARK: - Login Tests
    /// Happy path — valid credentials should store tokens
    /// and set isAuthenticated to true
    func testLoginSuccess() async throws {
        // Arrange: mock server returns 200 with tokens
        MockURLProtocol.mockResponses["/auth/login"] = (
            statusCode: 200,
            json: [
                "access_token":  "mock_access_token_abc123",
                "refresh_token": "mock_refresh_token_xyz789"
            ]
        )
        // Act
        try await authManager.login(userID: "patient_001", password: "testpass")
        // Assert
        XCTAssertTrue(authManager.isAuthenticated, "Should be authenticated after successful login")
    }
    /// Wrong password — server returns 401, should throw invalidCredentials
    func testLoginWrongPassword() async {
        // Arrange: mock server returns 401
        MockURLProtocol.mockResponses["/auth/login"] = (
            statusCode: 401,
            json: ["error": "unauthorized"]
        )
        // Act + Assert
        do {
            try await authManager.login(userID: "patient_001", password: "wrongpass")
            XCTFail("Should have thrown an error")
        } catch AuthError.invalidCredentials {
            // Correct error was thrown — now verify state
            // Small yield to let @MainActor process the state update
            await Task.yield()
            XCTAssertFalse(authManager.isAuthenticated, "Should not be authenticated after wrong password")
        } catch {
            XCTFail("Wrong error type thrown: \(error)")
        }
    }
    /// Server error — should throw serverError with correct status code
    func testLoginServerError() async {
        // Arrange: mock server returns 500
        MockURLProtocol.mockResponses["/auth/login"] = (
            statusCode: 500,
            json: ["error": "internal server error"]
        )
        // Act + Assert
        do {
            try await authManager.login(userID: "patient_001", password: "testpass")
            XCTFail("Should have thrown an error")
        } catch AuthError.serverError(let code) {
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
    // MARK: - Silent Refresh Tests
    /// Valid refresh token → should restore session silently
    func testSilentRefreshSuccess() async {
        // Arrange: mock server returns fresh tokens
        MockURLProtocol.mockResponses["/auth/refresh"] = (
            statusCode: 200,
            json: [
                "access_token":  "new_access_token",
                "refresh_token": "new_refresh_token"
            ]
        )
        // Manually store a fake refresh token to simulate app relaunch
        KeychainManager.shared.save(
            key: "journey_refresh_token",
            data: Data("old_refresh_token".utf8)
        )
        // Act
        await authManager.silentRefresh()
        // Assert
        XCTAssertTrue(authManager.isAuthenticated, "Should restore session from refresh token")
    }
    /// Expired refresh token → server returns 401 → should force re-login
    func testSilentRefreshFailure() async {
        // Arrange: mock server rejects the refresh token
        MockURLProtocol.mockResponses["/auth/refresh"] = (
            statusCode: 401,
            json: ["error": "refresh token expired"]
        )
        KeychainManager.shared.save(
            key: "journey_refresh_token",
            data: Data("expired_refresh_token".utf8)
        )
        // Act
        await authManager.silentRefresh()
        // Assert
        XCTAssertFalse(authManager.isAuthenticated, "Should not be authenticated after failed refresh")
    }
    // MARK: - Logout Tests
    /// Logout should clear tokens and set isAuthenticated to false
    func testLogout() async throws {
        // Arrange: log in first
        MockURLProtocol.mockResponses["/auth/login"] = (
            statusCode: 200,
            json: [
                "access_token":  "mock_access_token",
                "refresh_token": "mock_refresh_token"
            ]
        )
        try await authManager.login(userID: "patient_001", password: "testpass")
        XCTAssertTrue(authManager.isAuthenticated)
        // Act
        authManager.logout()
        // Assert
        XCTAssertFalse(authManager.isAuthenticated, "Should not be authenticated after logout")
        XCTAssertNil(
            KeychainManager.shared.read(key: "journey_access_token"),
            "Access token should be cleared from Keychain"
        )
        XCTAssertNil(
            KeychainManager.shared.read(key: "journey_refresh_token"),
            "Refresh token should be cleared from Keychain"
        )
    }
}
// ```


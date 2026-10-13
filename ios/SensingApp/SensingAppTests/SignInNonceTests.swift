//
//  SignInNonceTests.swift
//  SensingAppTests
//
//  Issue #82: the raw nonce goes to /auth/login and its SHA-256 to Apple; the
//  server compares hashlib.sha256(raw).hexdigest() with the token's claim, so
//  both sides must hash identically. Network calls are stubbed.
//

import Foundation
import XCTest
@testable import SensingApp

@MainActor
final class SignInNonceTests: XCTestCase {

    private let participantKey = "journey_participant_id"
    private var savedParticipant: String?
    private var auth: SecureAuthManager!

    override func setUp() async throws {
        try await super.setUp()
        savedParticipant = UserDefaults.standard.string(forKey: participantKey)
        KeychainManager.shared.delete(key: "journey_refresh_token")
        KeychainManager.shared.delete(key: "journey_access_token")
        UploadStubProtocol.reset()
        UploadStubProtocol.handler = { _, _ in
            .http(200, #"{"access_token": "at", "refresh_token": "rt"}"#)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UploadStubProtocol.self]
        auth = SecureAuthManager()
        auth.session = URLSession(configuration: config)
        auth.baseURL = "https://stub.test"
    }

    override func tearDown() async throws {
        UserDefaults.standard.set(savedParticipant, forKey: participantKey)
        KeychainManager.shared.delete(key: "journey_refresh_token")
        KeychainManager.shared.delete(key: "journey_access_token")
        UploadStubProtocol.reset()
        auth = nil
        try await super.tearDown()
    }

    func testSha256MatchesServerHexdigest() {
        // python3 -c "import hashlib; print(hashlib.sha256(b'abc').hexdigest())"
        XCTAssertEqual(SignInNonce.sha256("abc"),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testRandomIsUnpaddedBase64URLAndFresh() {
        let a = SignInNonce.random(), b = SignInNonce.random()
        XCTAssertEqual(a.count, 43)                       // 32 bytes, no padding
        XCTAssertNil(a.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        XCTAssertNotEqual(a, b)
    }

    func testLoginSendsNonceAndCode() async throws {
        try await auth.login(identityToken: "apple.jwt", fullName: nil, appleUserID: "apple.user",
                             enrollmentCode: "123456", nonce: "raw-nonce")

        XCTAssertEqual(try loginBody(), ["identity_token": "apple.jwt",
                                         "enrollment_code": "123456",
                                         "nonce": "raw-nonce"])
        XCTAssertTrue(auth.isAuthenticated)
    }

    func testLoginWithoutNonceOmitsIt() async throws {
        try await auth.login(identityToken: "apple.jwt", fullName: nil, appleUserID: "apple.user")
        XCTAssertEqual(try loginBody(), ["identity_token": "apple.jwt"])
    }

    func testTooManyAttemptsHasItsOwnError() async {
        UploadStubProtocol.handler = { _, _ in .http(429, #"{"error": "too_many_attempts"}"#) }
        do {
            try await auth.login(identityToken: "apple.jwt", fullName: nil, appleUserID: "apple.user",
                                 enrollmentCode: "123456")
            XCTFail("expected tooManyAttempts")
        } catch AuthError.tooManyAttempts {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    private func loginBody() throws -> [String: String] {
        let sent = UploadStubProtocol.requests(path: "/auth/login")
        XCTAssertEqual(sent.count, 1)
        let body = try XCTUnwrap(sent.first?.body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
    }
}

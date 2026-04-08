MockURLProtocol:


//
//  MockURLProtocol.swift
//  SpineSurgeryUI
//
//  Created by UIUCSpineSurgey on 3/18/26.
//
import Foundation
// ============================================================
// MARK: - MockURLProtocol Overview
// ============================================================
//
// PURPOSE:
// Intercepts URLSession network calls during testing and returns
// fake server responses — no real server or internet needed.
//
// HOW IT WORKS:
// URLSession allows custom URLProtocol subclasses to intercept
// requests before they hit the network. MockURLProtocol catches
// every request, matches it against a predefined response table,
// and returns the mock data immediately.
//
// SETUP FOR TESTING:
// In your XCTestCase setUp():
//
//   let config = URLSessionConfiguration.ephemeral
//   config.protocolClasses = [MockURLProtocol.self]
//   authManager.session = URLSession(configuration: config)
//
// ADDING NEW MOCK ENDPOINTS:
// Add a new entry to MockURLProtocol.mockResponses:
//
//   "/your/endpoint": (statusCode: 200, json: ["key": "value"])
//
// SIMULATING ERRORS:
// Set the response to a non-200 status code:
//
//   "/auth/login": (statusCode: 401, json: ["error": "unauthorized"])
// ============================================================
class MockURLProtocol: URLProtocol {
    // MARK: - Mock Response Table
    //
    // Maps URL path strings to (statusCode, JSON body) pairs.
    // Modify these to simulate different server scenarios.
    // Add new entries here as new endpoints are built.
    static var mockResponses: [String: (statusCode: Int, json: [String: Any])] = [
        // Successful login → returns a fake token pair
        "/auth/login": (
            statusCode: 200,
            json: [
                "access_token":  "mock_access_token_abc123",
                "refresh_token": "mock_refresh_token_xyz789"
            ]
        ),
        // Successful token refresh → returns a new fake access token
        "/auth/refresh": (
            statusCode: 200,
            json: [
                "access_token":  "mock_refreshed_access_token_def456",
                "refresh_token": "mock_refresh_token_xyz789"
            ]
        )
    ]
    // MARK: - URLProtocol Required Overrides
    /// Tells URLSession this protocol handles every request
    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }
    /// Returns the request unchanged (no modifications needed)
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }
    /// Called when URLSession fires a request — we intercept here
    /// and return the mock response instead of hitting the network
    override func startLoading() {
        // Extract the URL path to look up in our response table
        guard let url  = request.url,
              let path = URL(string: url.absoluteString)?.path,
              let mock = MockURLProtocol.mockResponses[path]
        else {
            // Path not found in mock table — return 404
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        // Build the mock HTTP response with the configured status code
        let response = HTTPURLResponse(
            url: url,
            statusCode: mock.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        // Encode the mock JSON body to Data
        let data = (try? JSONSerialization.data(withJSONObject: mock.json)) ?? Data()
        // Deliver mock response to URLSession as if it came from the network
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    /// Required by URLProtocol — nothing to cancel in a mock
    override func stopLoading() {}
}



//
//  MockURLProtocol.swift
//  SensingApp
//

import Foundation

final class MockURLProtocol: URLProtocol {

    static var mockResponses: [String: (statusCode: Int, json: [String: Any])] = [
        "/auth/login": (
            statusCode: 200,
            json: [
                "access_token": "mock_access_token_abc123",
                "refresh_token": "mock_refresh_token_xyz789"
            ]
        ),
        "/auth/refresh": (
            statusCode: 200,
            json: [
                "access_token": "mock_refreshed_access_token_def456",
                "refresh_token": "mock_refresh_token_xyz789"
            ]
        )
    ]

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard
            let url = request.url,
            let mock = Self.mockResponses[url.path]
        else {
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil
            )!

            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: mock.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!

        let data = (try? JSONSerialization.data(withJSONObject: mock.json, options: [])) ?? Data()

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

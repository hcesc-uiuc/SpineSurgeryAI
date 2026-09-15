//
//  S3UploaderTests.swift
//  SensingAppTests
//
//  Issue #72: an upload only counts once the complete step replies
//  HTTP 200 with "status": "completed". Network calls are stubbed.
//

import Foundation
import XCTest
@testable import SensingApp

/// Routes each request to a per-test handler and records what was sent.
final class UploadStubProtocol: URLProtocol {

    struct Recorded {
        let method: String
        let path: String
        let body: Data?
    }

    enum Reply {
        case http(Int, String)
        case networkError
    }

    nonisolated(unsafe) static var handler: ((URLRequest, Int) -> Reply)?
    nonisolated(unsafe) static var recorded: [Recorded] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handler = nil
        recorded = []
    }

    static func requests(path: String) -> [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return recorded.filter { $0.path == path }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let body = request.httpBody ?? request.httpBodyStream.map(Self.readAll)

        Self.lock.lock()
        Self.recorded.append(Recorded(method: request.httpMethod ?? "", path: path, body: body))
        let count = Self.recorded.filter { $0.path == path }.count
        let handler = Self.handler
        Self.lock.unlock()

        switch handler?(request, count) ?? .http(404, "{}") {
        case .networkError:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case let .http(status, text):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

final class S3UploaderTests: XCTestCase {

    private let presignPath = "/api/noauth/uploads/presign"
    private let completePath = "/api/noauth/uploads/complete"
    private let s3Path = "/uploads/accel/20260915T000000_accelerometer_test.csv"

    private var uploader: S3TestUploader!
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        UploadStubProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UploadStubProtocol.self]
        uploader = S3TestUploader(session: URLSession(configuration: config))

        fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("accelerometer_test.csv")
        try? Data("ts,x,y,z\n1,0,0,1\n".utf8).write(to: fileURL)
    }

    override func tearDown() {
        UploadStubProtocol.reset()
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private var presignOK: String {
        """
        {"upload_id":"u-1","key":"uploads/accel/x.csv","url":"https://bucket.s3.amazonaws.com\(s3Path)?sig=1",
         "headers":{"Content-Type":"text/csv"},"expires_in":900}
        """
    }

    /// Stubs presign 201 and the given S3 status; `complete` picks the reply per attempt.
    private func stub(s3Status: Int = 200, complete: @escaping (Int) -> UploadStubProtocol.Reply) {
        let presign = presignOK
        let presignPath = presignPath
        let completePath = completePath
        UploadStubProtocol.handler = { request, attempt in
            switch request.url?.path {
            case presignPath:  return .http(201, presign)
            case completePath: return complete(attempt)
            default:           return .http(s3Status, "")
            }
        }
    }

    private func completeSuccessFlag() -> Bool? {
        guard let body = UploadStubProtocol.requests(path: completePath).first?.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return json["success"] as? Bool
    }

    func testCompletedReplyCountsAsUploaded() async {
        stub { _ in .http(200, #"{"status":"completed","key":"uploads/accel/x.csv"}"#) }
        let ok = await uploader.runFullFlow(filenameURL: fileURL, kind: "accel")
        XCTAssertTrue(ok)
        XCTAssertEqual(UploadStubProtocol.requests(path: completePath).count, 1)
    }

    func testFailedStatusWithHTTP200IsNotUploaded() async {
        stub { _ in .http(200, #"{"status":"failed","error":"object not found in S3"}"#) }
        let ok = await uploader.runFullFlow(filenameURL: fileURL, kind: "accel")
        XCTAssertFalse(ok)
        XCTAssertEqual(UploadStubProtocol.requests(path: completePath).count, 1, "a definite answer is not retried")
    }

    func testUnknownUploadIDIsNotUploaded() async {
        stub { _ in .http(404, #"{"error":"upload not found"}"#) }
        let ok = await uploader.runFullFlow(filenameURL: fileURL, kind: "other")
        XCTAssertFalse(ok)
        XCTAssertEqual(UploadStubProtocol.requests(path: completePath).count, 1)
    }

    func testUnreadableBodyIsNotUploaded() async {
        stub { _ in .http(200, "<html>proxy page</html>") }
        let ok = await uploader.runFullFlow(filenameURL: fileURL, kind: "accel")
        XCTAssertFalse(ok)
    }

    func testServerErrorsAreRetriedThenSucceed() async {
        stub { attempt in attempt < 3 ? .http(500, "<html>error</html>") : .http(200, #"{"status":"completed"}"#) }
        let ok = await uploader.runFullFlow(filenameURL: fileURL, kind: "accel")
        XCTAssertTrue(ok)
        XCTAssertEqual(UploadStubProtocol.requests(path: completePath).count, 3)
    }

    func testNetworkErrorIsRetriedThenSucceeds() async {
        stub { attempt in attempt == 1 ? .networkError : .http(200, #"{"status":"completed"}"#) }
        let ok = await uploader.runFullFlow(filenameURL: fileURL, kind: "accel")
        XCTAssertTrue(ok)
        XCTAssertEqual(UploadStubProtocol.requests(path: completePath).count, 2)
    }

    func testPersistentServerErrorGivesUpAfterMaxAttempts() async {
        stub { _ in .http(503, "") }
        let ok = await uploader.runFullFlow(filenameURL: fileURL, kind: "accel")
        XCTAssertFalse(ok)
        XCTAssertEqual(UploadStubProtocol.requests(path: completePath).count, S3UploadConfig.completeMaxAttempts)
    }

    func testS3RejectionIsNotUploadedAndReportsFailure() async {
        // Even if the backend were to answer "completed", a failed PUT must not count.
        stub(s3Status: 403) { _ in .http(200, #"{"status":"completed"}"#) }
        let ok = await uploader.runFullFlow(filenameURL: fileURL, kind: "accel")
        XCTAssertFalse(ok)
        XCTAssertEqual(completeSuccessFlag(), false)
    }

    func testPresignFailureSkipsUploadAndComplete() async {
        UploadStubProtocol.handler = { _, _ in .http(500, "<html>error</html>") }
        let ok = await uploader.runFullFlow(filenameURL: fileURL, kind: "other")
        XCTAssertFalse(ok)
        XCTAssertEqual(UploadStubProtocol.requests(path: presignPath).count, 1)
        XCTAssertTrue(UploadStubProtocol.requests(path: s3Path).isEmpty)
        XCTAssertTrue(UploadStubProtocol.requests(path: completePath).isEmpty)
    }
}

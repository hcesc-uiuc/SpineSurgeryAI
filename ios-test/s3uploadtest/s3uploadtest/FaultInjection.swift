//
//  FaultInjection.swift
//  s3uploadtest  —  Issue #72
//
//  Harness-only fault modes. They tamper with the harness's own requests so the
//  REAL backend and S3 return real failure replies, without editing the vendored
//  upload code. Each mode targets one branch of the complete step:
//
//      none            -> normal run, expect pass
//      badUploadID     -> complete gets an unknown upload_id -> backend 404
//      fakeS3Success   -> PUT is not sent, a fake 200 is returned -> backend
//                         finds no object -> 200 {"status":"failed"}
//      s3Rejects       -> PUT signature is corrupted -> S3 403 -> complete(success:false)
//
//  Only the presign path is affected; multipart (loc/hk) requests pass through.
//

import Foundation

enum FaultMode: String, CaseIterable, Identifiable {
    case none, badUploadID, fakeS3Success, s3Rejects

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none:          return "Normal"
        case .badUploadID:   return "Bad upload ID"
        case .fakeS3Success: return "Fake S3 success"
        case .s3Rejects:     return "S3 rejects"
        }
    }

    /// What a presign-path file should do under this mode.
    var presignShouldPass: Bool { self == .none }

    /// Session handed to S3TestUploader(session:).
    func session() -> URLSession {
        guard self != .none else { return .shared }
        FaultInjectionProtocol.mode = self
        let config = URLSessionConfiguration.default
        config.protocolClasses = [FaultInjectionProtocol.self]
        return URLSession(configuration: config)
    }
}

final class FaultInjectionProtocol: URLProtocol {

    nonisolated(unsafe) static var mode: FaultMode = .none

    /// Plain session for forwarding; it has no custom protocols, so no recursion.
    private static let forwarder = URLSession(configuration: .default)
    private var forwardTask: URLSessionDataTask?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var outgoing = request
        let path = request.url?.path ?? ""
        let isS3Put = request.httpMethod == "PUT" && (request.url?.host ?? "").contains("amazonaws.com")
        let isComplete = path.hasSuffix("/uploads/complete")

        switch Self.mode {
        case .fakeS3Success where isS3Put:
            print("  [fault] fakeS3Success: PUT not sent, returning fake 200")
            respond(status: 200, data: Data())
            return
        case .s3Rejects where isS3Put:
            print("  [fault] s3Rejects: corrupting PUT signature")
            outgoing.url = URL(string: (request.url?.absoluteString ?? "") + "0")
            outgoing.httpBody = Data()
        case .badUploadID where isComplete:
            print("  [fault] badUploadID: sending unknown upload_id to complete")
            var json = (bodyData().flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
            json["upload_id"] = UUID().uuidString.lowercased()
            // Clear the stream first: setting httpBodyStream also resets httpBody.
            outgoing.httpBodyStream = nil
            outgoing.httpBody = try? JSONSerialization.data(withJSONObject: json)
        default:
            if outgoing.httpBody == nil, let data = bodyData() {
                outgoing.httpBody = data
            }
        }

        forwardTask = Self.forwarder.dataTask(with: outgoing) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            if let response {
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            if let data { self.client?.urlProtocol(self, didLoad: data) }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        forwardTask?.resume()
    }

    override func stopLoading() {
        forwardTask?.cancel()
    }

    private func respond(status: Int, data: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func bodyData() -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

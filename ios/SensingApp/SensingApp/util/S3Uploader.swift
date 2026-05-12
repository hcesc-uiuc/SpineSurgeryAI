//
//  S3Uploader.swift
//  SensingApp
//
//  Created by Mohammod Mashfiqui Rabbi Shuvo on 5/8/26.
//


// S3UploadTest.swift
// Drop this into a new single-view SwiftUI Xcode project (iOS target).
// Run on simulator or device — tap the buttons in order to verify the full flow.



import Foundation

// MARK: - Config
private let _baseURL = "https://rvsh5s5hg66ezcom2itcz7a27y0smcig.lambda-url.us-east-2.on.aws"

/// Namespace for S3 upload configuration constants.
public enum S3UploadConfig {
    public nonisolated(unsafe) static let baseURL      = _baseURL
    public nonisolated(unsafe) static let presignURL   = "\(_baseURL)/api/noauth/uploads/presign"
    public nonisolated(unsafe) static let completeURL  = "\(_baseURL)/api/noauth/uploads/complete"
    public nonisolated(unsafe) static let participantID = "P0001"   // change to a real test participant
}

// Top-level aliases for backwards compatibility
public var baseURL: String      { S3UploadConfig.baseURL }
public var presignURL: String   { S3UploadConfig.presignURL }
public var completeURL: String  { S3UploadConfig.completeURL }
public var participantID: String { S3UploadConfig.participantID }

// MARK: - Models
private struct PresignResponse: Encodable, Sendable {
    let upload_id: String
    let key: String
    let url: String
    let headers: [String: String]
    let expires_in: Int
}

extension PresignResponse: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        upload_id  = try c.decode(String.self, forKey: .upload_id)
        key        = try c.decode(String.self, forKey: .key)
        url        = try c.decode(String.self, forKey: .url)
        headers    = try c.decode([String: String].self, forKey: .headers)
        expires_in = try c.decode(Int.self, forKey: .expires_in)
    }
    private enum CodingKeys: String, CodingKey {
        case upload_id, key, url, headers, expires_in
    }
}

private struct CompleteResponse: Codable, Sendable {
    let status: String
    let key: String?
    let error: String?
}

// MARK: - Uploader
/*
 In Swift, an actor is essentially a class with built-in data race protection.
 
 Class — reference type with no concurrency guarantees. Multiple threads can read
        and write its properties simultaneously, leading to data races unless
        you manually synchronize with locks, serial queues, etc.
 
 Actor — also a reference type, but the Swift runtime ensures that only one
        task can access its mutable state at a time. Accessing an actor's properties
        or methods from outside requires await, because the caller may need to wait for
        the actor to become available.
 
 
 */
public actor S3TestUploader {

    // Creates a small dummy CSV in the temp directory and uploads it.
    func runFullFlow(filenameURL: URL, kind: String) async -> Bool {
        print("--- Starting \(kind) upload flow ---")

        // 1. Write a dummy file to disk
        let tmpURL = filenameURL
        let filename = tmpURL.lastPathComponent
        
        // 2. Presign
        print("Step 1: Requesting presigned URL...")
        guard let presign = await requestPresign(filename: filename, kind: kind) else { return false }
        print("  upload_id: \(presign.upload_id)")
        print("  key: \(presign.key)")

        // 3. PUT to S3
        print("Step 2: Uploading to S3...")
        let s3Success = await putToS3(presign: presign, fileURL: tmpURL)
        print("  S3 PUT success: \(s3Success)")

        // 4. Complete
        print("Step 3: Notifying server of result...")
        await notifyComplete(uploadID: presign.upload_id, success: s3Success)

        print("--- Done ---\n")
        return s3Success
    }
    
    

    private func requestPresign(filename: String, kind: String) async -> PresignResponse? {
        guard let url = URL(string: S3UploadConfig.presignURL) else {
            print("ERROR: invalid presign URL")
            return nil
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "participantId": S3UploadConfig.participantID,
            "filename": filename,
            "content_type": "text/csv",
            "kind": kind
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("  presign HTTP status: \(status)")
            if let raw = String(data: data, encoding: .utf8) {
                print("  presign response: \(raw)")
            }
            guard status == 201 else {
                print("ERROR: expected 201 from presign")
                return nil
            }
            return try JSONDecoder().decode(PresignResponse.self, from: data)
        } catch {
            print("ERROR presign: \(error)")
            return nil
        }
    }

    private func putToS3(presign: PresignResponse, fileURL: URL) async -> Bool {
        guard let s3URL = URL(string: presign.url) else {
            print("ERROR: invalid S3 URL")
            return false
        }
        var req = URLRequest(url: s3URL)
        req.httpMethod = "PUT"
        for (k, v) in presign.headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        do {
            let (_, response) = try await URLSession.shared.upload(for: req, fromFile: fileURL)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("  S3 PUT HTTP status: \(status)")
            return status == 200
        } catch {
            print("ERROR S3 PUT: \(error)")
            return false
        }
    }

    private func notifyComplete(uploadID: String, success: Bool) async {
        guard let url = URL(string: S3UploadConfig.completeURL) else {
            print("ERROR: invalid complete URL")
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["upload_id": uploadID, "success": success]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("  complete HTTP status: \(status)")
            if let raw = String(data: data, encoding: .utf8) {
                print("  complete response: \(raw)")
            }
        } catch {
            print("ERROR complete: \(error)")
        }
    }
}

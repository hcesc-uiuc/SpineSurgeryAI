//
//  S3Uploader.swift
//  VENDORED VERBATIM from ios/SensingApp/SensingApp/util/S3Uploader.swift
//  ---------------------------------------------------------------------------
//  This is a copy of the app's upload code so the harness exercises the
//  exact same code path (Issues #69, #72). Do NOT edit here — if the app version
//  changes, re-copy it. Kept in sync manually with the dev branch.
//  ---------------------------------------------------------------------------

//
//  S3Uploader.swift
//  SensingApp
//
//  Created by Mohammod Mashfiqui Rabbi Shuvo on 5/8/26.
//
//  Presigned upload flow: presign -> PUT to S3 -> complete.
//  An upload only counts as successful once the backend confirms it in the
//  complete step (HTTP 200 and "status": "completed"). See ios-test/UPLOAD_FLOW.md.
//

import Foundation

// MARK: - Config
private let _baseURL = "https://rvsh5s5hg66ezcom2itcz7a27y0smcig.lambda-url.us-east-2.on.aws"

/// Namespace for S3 upload configuration constants.
public enum S3UploadConfig {
    public nonisolated(unsafe) static let baseURL      = _baseURL
    public nonisolated(unsafe) static let presignURL   = "\(_baseURL)/api/noauth/uploads/presign"
    public nonisolated(unsafe) static let completeURL  = "\(_baseURL)/api/noauth/uploads/complete"
    public static var participantID: String { ParticipantID.current }   // anonymous SHA-256 participant hash

    /// Attempts for the complete call when it hits a network error or a 5xx.
    public static let completeMaxAttempts = 3
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

private struct CompleteResponse: Sendable {
    let status: String
    let key: String?
    let error: String?
}

extension CompleteResponse: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(String.self, forKey: .status)
        key    = try c.decodeIfPresent(String.self, forKey: .key)
        error  = try c.decodeIfPresent(String.self, forKey: .error)
    }
    private enum CodingKeys: String, CodingKey {
        case status, key, error
    }
}

// MARK: - Uploader
public actor S3TestUploader {

    private let session: URLSession

    /// `session` is injectable so tests and the upload harness can intercept requests.
    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Uploads one file. Returns true only when the backend confirms the upload
    /// was recorded; the caller moves the file to processed/ on true.
    func runFullFlow(filenameURL: URL, kind: String) async -> Bool {
        print("--- Starting \(kind) upload flow ---")
        let filename = filenameURL.lastPathComponent

        print("Step 1: Requesting presigned URL...")
        guard let presign = await requestPresign(filename: filename, kind: kind) else { return false }
        print("  upload_id: \(presign.upload_id)")
        print("  key: \(presign.key)")

        print("Step 2: Uploading to S3...")
        let s3Success = await putToS3(presign: presign, fileURL: filenameURL)
        print("  S3 PUT success: \(s3Success)")

        // Report failures too, so the backend deletes the partial object and closes the row.
        print("Step 3: Notifying server of result...")
        let completed = await notifyComplete(uploadID: presign.upload_id, success: s3Success)

        let recorded = s3Success && completed
        print("  upload recorded by backend: \(recorded)")
        print("--- Done ---\n")
        return recorded
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
            let (data, response) = try await session.data(for: req)
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
            let (_, response) = try await session.upload(for: req, fromFile: fileURL)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("  S3 PUT HTTP status: \(status)")
            return status == 200
        } catch {
            print("ERROR S3 PUT: \(error)")
            return false
        }
    }

    /// Returns true only for HTTP 200 with "status": "completed".
    /// Network errors and 5xx are retried; any other reply is final.
    private func notifyComplete(uploadID: String, success: Bool) async -> Bool {
        guard let url = URL(string: S3UploadConfig.completeURL) else {
            print("ERROR: invalid complete URL")
            return false
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["upload_id": uploadID, "success": success]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let maxAttempts = S3UploadConfig.completeMaxAttempts
        for attempt in 1...maxAttempts {
            do {
                let (data, response) = try await session.data(for: req)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                print("  complete HTTP status: \(status)")
                if let raw = String(data: data, encoding: .utf8) {
                    print("  complete response: \(raw)")
                }

                if status >= 500 && attempt < maxAttempts {
                    print("  complete: server error, retrying (\(attempt)/\(maxAttempts))")
                    await backoff(attempt: attempt)
                    continue
                }
                guard status == 200,
                      let reply = try? JSONDecoder().decode(CompleteResponse.self, from: data) else {
                    print("  complete: not recorded (HTTP \(status))")
                    return false
                }
                if reply.status == "completed" {
                    print("  complete: completed")
                    return true
                }
                print("  complete: \(reply.status)\(reply.error.map { " (\($0))" } ?? "")")
                return false
            } catch {
                print("ERROR complete: \(error)")
                if attempt < maxAttempts {
                    print("  complete: network error, retrying (\(attempt)/\(maxAttempts))")
                    await backoff(attempt: attempt)
                    continue
                }
                return false
            }
        }
        return false
    }

    /// 1s, then 2s. Kept short because uploads run inside a background task.
    private func backoff(attempt: Int) async {
        try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
    }
}

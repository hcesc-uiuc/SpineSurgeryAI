//
//  Uploader.swift
//  SensingApp
//
//  Created by Mohammod Mashfiqui Rabbi Shuvo on 11/5/25.
//

import Foundation

struct Uploader {

    static let shared = Uploader()
    static let BaseURL = "http://18.116.67.186"
    static let PresignURL = "\(BaseURL)/api/uploads/presign"
    static let CompleteURL = "\(BaseURL)/api/uploads/complete"
    static let SurveyURL = "\(BaseURL)/api/uploadjson/survey"

    private struct PresignResponse: Codable {
        let upload_id: String
        let key: String
        let url: String
        let headers: [String: String]
        let expires_in: Int
    }

    func uploadFolder() async {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!

        let file_prefixes = ["log_"]
        for file_prefix in file_prefixes {
            let matchingFiles = filesWithPrefix(in: documentsURL, prefix: file_prefix)
            let numberOfFiles = matchingFiles.count
            for (index, file) in matchingFiles.enumerated() {
                if let size = fileSize(from: file) {
                    let fileSizeInKB = Int(Double(size) / 1024)
                    print("\(index+1)/\(numberOfFiles) Uploading file: \(file.lastPathComponent); \(fileSizeInKB)KB")
                    await uploadFile(fileURL: file, kind: "accel")
                }
                break
            }
        }
    }

    func uploadFile(fileURL: URL, kind: String = "accel") async {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("File \(fileURL.lastPathComponent) does not exist")
            return
        }
        print("File \(fileURL.lastPathComponent) exists")

        // Step 1: Request presigned URL from server
        guard let presignURL = URL(string: Uploader.PresignURL) else {
            print("Upload failed: invalid presign URL")
            return
        }

        var presignReq = URLRequest(url: presignURL)
        presignReq.httpMethod = "POST"
        presignReq.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let fileSizeBytes = fileSize(from: fileURL) ?? 0
        let presignBody: [String: Any] = [
            "filename": fileURL.lastPathComponent,
            "content_type": "application/octet-stream",
            "size": fileSizeBytes,
            "kind": kind
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: presignBody) else {
            print("Upload failed: could not encode presign request")
            return
        }
        presignReq.httpBody = bodyData

        do {
            let (presignData, presignResp) = try await URLSession.shared.data(for: presignReq)
            guard let httpPresign = presignResp as? HTTPURLResponse, httpPresign.statusCode == 201 else {
                print("Upload failed: presign request returned non-201")
                return
            }
            guard let presign = try? JSONDecoder().decode(PresignResponse.self, from: presignData) else {
                print("Upload failed: could not decode presign response")
                return
            }

            // Step 2: PUT file bytes directly to S3 (no multipart, raw body streamed from disk)
            guard let s3URL = URL(string: presign.url) else {
                print("Upload failed: invalid S3 presigned URL")
                return
            }
            var s3Req = URLRequest(url: s3URL)
            s3Req.httpMethod = "PUT"
            for (headerKey, headerValue) in presign.headers {
                s3Req.setValue(headerValue, forHTTPHeaderField: headerKey)
            }

            let (_, s3Response) = try await URLSession.shared.upload(for: s3Req, fromFile: fileURL)
            let uploadSuccess = (s3Response as? HTTPURLResponse)?.statusCode == 200

            // Step 3: Notify server of upload result
            guard let completeURL = URL(string: Uploader.CompleteURL) else { return }
            var completeReq = URLRequest(url: completeURL)
            completeReq.httpMethod = "POST"
            completeReq.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let completeBody: [String: Any] = [
                "upload_id": presign.upload_id,
                "success": uploadSuccess
            ]
            completeReq.httpBody = try? JSONSerialization.data(withJSONObject: completeBody)

            let (_, _) = try await URLSession.shared.data(for: completeReq)

            if uploadSuccess {
                print("     Upload success! Key: \(presign.key)")
            } else {
                print("Upload failed: S3 PUT returned non-200")
            }

        } catch {
            print("Upload failed: \(error)")
        }
    }

    func uploadSurveyResults(payload: [String: Any]) async {

        guard let url = URL(string: Uploader.SurveyURL) else { return }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (_, response) = try await URLSession.shared.upload(for: request, from: jsonData)
            print("Upload success: \(response)")
        } catch {
            print("Upload error: \(error.localizedDescription)")
        }
    }

    func filesWithPrefix(in directory: URL, prefix: String) -> [URL] {
        let fileManager = FileManager.default

        do {
            let fileURLs = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )

            // Filter by prefix
            return fileURLs.filter { $0.lastPathComponent.hasPrefix(prefix) }

        } catch {
            print("Error reading directory: \(error)")
            return []
        }
    }

    func fileSize(from url: URL) -> Int? {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            return values.fileSize   // bytes
        } catch {
            print("Error: \(error)")
            return nil
        }
    }
}

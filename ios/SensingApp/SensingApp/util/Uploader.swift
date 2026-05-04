//
//  Uploader.swift
//  SensingApp
//
//  Created by Mohammod Mashfiqui Rabbi Shuvo on 11/5/25.
//

import Foundation


struct Uploader {
    
    static let shared = Uploader()
    // static let UploadURL = "http://18.116.67.186/api/uploadfile"
    static let UploadURL = "http://18.116.67.186/api/noauth/uploadfile"
    
    
    func uploadFolder() async {
        
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let toBeProcessedURL = documentsURL.appendingPathComponent("to-be-processed")
        let processedURL = documentsURL.appendingPathComponent("processed")
        
        // Create the "processed" directory if it doesn't already exist
        if !fileManager.fileExists(atPath: processedURL.path) {
            try? fileManager.createDirectory(at: processedURL, withIntermediateDirectories: true)
        }
        
        //let file_prefixes = ["accelerometer_"] //, "log_"] //add more extension in future
        //let file_prefixes = ["log_"] //add more extension in future
        let todaysDateString = getTodaysDateString()
        let file_prefixes = ["locations_", "accelerometer_", "healthkit_"]
        for file_prefix in file_prefixes {
            let matchingFiles = filesWithPrefix(in: toBeProcessedURL, prefix: file_prefix)
            let numberOfFiles = matchingFiles.count
            for (index, file) in matchingFiles.enumerated() {
                
                // Skip today's file — it may still be open for writing
                let nameWithoutExtension = file.deletingPathExtension().lastPathComponent
                if nameWithoutExtension.hasSuffix(todaysDateString) {
                    print("\(file.lastPathComponent) is today's file, skipping")
                    continue
                }
                
                if let size = fileSize(from: file) {
                    let fileSizeInKB = Int(Double(size) / 1024)
                    print("\(index+1)/\(numberOfFiles) Uploading file: \(file.lastPathComponent); \(fileSizeInKB)KB")
                    let success = await uploadFile(fileURL: file)
                    if success {
                        // Move the file to "processed/" so it isn't re-uploaded on the next run
                        let destination = processedURL.appendingPathComponent(file.lastPathComponent)
                        do {
                            try fileManager.moveItem(at: file, to: destination)
                            print("     Moved \(file.lastPathComponent) -> processed/")
                        } catch {
                            print("     Failed to move \(file.lastPathComponent): \(error)")
                        }
                    }
                }
            }
        }
    }
    
    
    // Returns true if the upload succeeded, false otherwise.
    func uploadFile(fileURL: URL) async -> Bool {
        
        if FileManager.default.fileExists(atPath: fileURL.path) {
            print("File \(fileURL.lastPathComponent) exists")
        }else{
            print("File \(fileURL.lastPathComponent) does not exist")
        }
        
        
        let boundary = "Boundary-\(UUID().uuidString)"
        guard let url = URL(string: Uploader.UploadURL) else {
            print("\(Uploader.UploadURL) does not exist")
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // Build the multipart form body
        var body = Data()
        let filename = fileURL.lastPathComponent
        let mimetype = "application/octet-stream"

        // --- file data part ---
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimetype)\r\n\r\n".data(using: .utf8)!)
        if let fileData = try? Data(contentsOf: fileURL) {
            body.append(fileData)
        }
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        // Await the upload directly — no fire-and-forget Task needed since the caller is async
        do {
            let (_, _) = try await upload(data: body, request: request)
            print("     Upload success!")
            return true
        } catch {
            print("Upload failed: \(error)")
            return false
        }
        
    }
    
    
    ///
    /// Coded taken from Sami'r code.
    ///
    func uploadSurveyResults(payload: [String: Any]) async {

        guard let url = URL(string: Uploader.UploadURL) else { return }
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
    
    
    //==========================
    //  Internal
    //==========================
     
    func upload(data: Data, request: URLRequest) async throws -> (Data, URLResponse) {
        // `upload(for:from:)` works with Data
        let (responseData, response) = try await URLSession.shared.upload(
            for: request,
            from: data
        )
        return (responseData, response)
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
    
    
    func getTodaysDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
    
    
}

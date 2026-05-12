//
//  Uploader.swift
//  SensingApp
//
//  Created by Mohammod Mashfiqui Rabbi Shuvo on 11/5/25.
//

import Foundation


struct Uploader {
    
    static let shared = Uploader()
    //static let UploadURL = "http://18.116.67.186/api/noauth/uploadfile"
    static let UploadURL = "https://rvsh5s5hg66ezcom2itcz7a27y0smcig.lambda-url.us-east-2.on.aws/api/noauth/uploadfile"
    //static let UploadURL = "http://18.116.67.186/api/noauth/uploadfile/accel"
    //    static let UploadURL = "https://rvsh5s5hg66ezcom2itcz7a27y0smcig.lambda-url.us-east-2.on.aws/api/noauth/uploadfile/accel"
    
    
    func uploadFolder() async {
        
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let toBeProcessedURL = documentsURL.appendingPathComponent("to-be-processed")
        let processedURL = documentsURL.appendingPathComponent("processed")
        
        let uploader = S3TestUploader()
        
        // Create the "processed" directory if it doesn't already exist
        if !fileManager.fileExists(atPath: processedURL.path) {
            try? fileManager.createDirectory(at: processedURL, withIntermediateDirectories: true)
        }
        
        //let file_prefixes = ["accelerometer_"] //, "log_"] //add more extension in future
        //let file_prefixes = ["log_"] //add more extension in future
        let todaysDateString = getTodaysDateString()
        let file_prefixes = ["locations_", "accelerometer_", "healthkit_"]
        //let kinds = ["location", "accelerometer", "healthkit"]
        let kinds = [
            "locations_": "loc",
            "accelerometer_": "accel",
            "healthkit_": "hk"
        ]
        
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
                    
                    let kind = kinds[file_prefix]!
                    if kind == "accel" {
                        let uploadSuccess = await uploader.runFullFlow(filenameURL: file, kind: kind)
                        if uploadSuccess {
                            // Move the file to "processed/" so it isn't re-uploaded on the next run
                            let destination = processedURL.appendingPathComponent(file.lastPathComponent)
                            do {
                                try fileManager.moveItem(at: file, to: destination)
                                print("     Moved \(file.lastPathComponent) -> processed/")
                            } catch {
                                print("     Failed to move \(file.lastPathComponent): \(error)")
                            }
                        }
                    }else{
                        //we will upload directly to the uploadFile link
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
                    
                    
                    //                    let success = await uploadFile(fileURL: file)
                    //                    if success {
                    //                        // Move the file to "processed/" so it isn't re-uploaded on the next run
                    //                        let destination = processedURL.appendingPathComponent(file.lastPathComponent)
                    //                        do {
                    //                            try fileManager.moveItem(at: file, to: destination)
                    //                            print("     Moved \(file.lastPathComponent) -> processed/")
                    //                        } catch {
                    //                            print("     Failed to move \(file.lastPathComponent): \(error)")
                    //                        }
                    //                    }
                }
            }
        }
    }
    
    
    // Returns true if the upload succeeded, false otherwise.
    func uploadFile(fileURL: URL) async -> Bool {
        
        if FileManager.default.fileExists(atPath: fileURL.path) {
            print("File \(fileURL.lastPathComponent) exists")
            // print("File full name: \(fileURL.absoluteString)")
        }else{
            print("File \(fileURL.lastPathComponent) does not exist")
            return false
        }
        
        let parameters = [
            [
                "key": "participantId",
                "value": "P0001",
                "type": "text"
            ],
            [
                "key": "file",
                "src": fileURL.path,
                "type": "file"
            ]
        ] as [[String: Any]]
        
        
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        var error: Error? = nil
        for param in parameters {
            if param["disabled"] != nil { continue }
            let paramName = param["key"]!
            body += Data("--\(boundary)\r\n".utf8)
            body += Data("Content-Disposition:form-data; name=\"\(paramName)\"".utf8)
            if param["contentType"] != nil {
                body += Data("\r\nContent-Type: \(param["contentType"] as! String)".utf8)
            }
            let paramType = param["type"] as! String
            if paramType == "text" {
                let paramValue = param["value"] as! String
                body += Data("\r\n\r\n\(paramValue)\r\n".utf8)
            } else {
                let paramSrc = param["src"] as! String
                let fileURL = URL(fileURLWithPath: paramSrc)
                if let fileContent = try? Data(contentsOf: fileURL) {
                    body += Data("; filename=\"\(fileURL.lastPathComponent)\"\r\n".utf8)
                    body += Data("Content-Type: \"content-type header\"\r\n".utf8)
                    body += Data("\r\n".utf8)
                    body += fileContent
                    body += Data("\r\n".utf8)
                }
            }
        }
        body += Data("--\(boundary)--\r\n".utf8);
        let postData = body
        
        guard let url = URL(string: Uploader.UploadURL) else {
            print("\(Uploader.UploadURL) does not exist")
            return false
        }
        var request = URLRequest(url: url,timeoutInterval: Double.infinity)
        request.addValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpMethod = "POST"
        request.httpBody = postData
        
        // Await the upload directly — no fire-and-forget Task needed since the caller is async
        
//        let task = URLSession.shared.dataTask(with: request) { data, response, error in
//            guard let data = data else {
//                print(String(describing: error))
//                return
//            }
//            print(String(data: data, encoding: .utf8)!)
//        }
//        task.resume()
        
        do {
            let (responseData, response) = try await upload(data: body, request: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status != 200 {
                print("     Upload failed!")
                print("     \(response)")
                print("     \(responseData)")
                return false
            }else{
                print("     Upload success!")
                print("     Response code: \(status)")
                // print("     Data: \(responseData)")
                // As JSON (pretty printed)
                if let json = try? JSONSerialization.jsonObject(with: responseData),
                   let pretty = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
                   let prettyStr = String(data: pretty, encoding: .utf8) {
                    print("JSON: \(prettyStr)")
                }
                return true
            }
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
        let (responseData, response) = try await URLSession.shared.data(
            for: request
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

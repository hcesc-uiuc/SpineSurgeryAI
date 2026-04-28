//
//  PreallocatedCSVBuffer.swift
//  SensingTrialApp
//
//  Created by Mashfiqui Rabbi on 10/7/25.
//

import Foundation

//This file is specific to accelerometer data.
final class PreallocatedCSVBuffer {
    private var buffer: [String]
    private var index = 0
    private let capacity: Int
    private let fileURL: URL
    private var fileHandle: FileHandle?

    init(filename: String = "data.csv", capacity: Int = 10_000) {
        self.capacity = capacity
        self.buffer = Array(repeating: "", count: capacity)

        // Prepare file path
        let fileManager = FileManager.default
        let docsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        fileURL = docsURL.appendingPathComponent("to-be-processed").appendingPathComponent(filename)

        // Create file with header if needed
        if !fileManager.fileExists(atPath: fileURL.path) {
            let header = "timestamp,x,y,z\n"
            try? header.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        
        //open the file
        fileHandle = try? FileHandle(forWritingTo: fileURL)
        fileHandle?.seekToEndOfFile()
    }

    /// Add one row — overwrites oldest if full
    func addRow(timestamp: Double, x: Double, y: Double, z: Double) {
        buffer[index] = "\(timestamp),\(x),\(y),\(z)"
        index += 1

        // Optional: auto flush when full
        if index == capacity {
            flush()
        }
    }
    
    func addRowStr(rowOfData: String) {
        buffer[index] = rowOfData
        index += 1

        // Optional: auto flush when full
        if index == capacity {
            flush()
        }
    }

    /// Write entire used buffer to disk and reset index
    func flush() {
        guard index > 0 else { return }

        // Only write used portion of the buffer
        let joined = buffer[0..<index].joined(separator: "\n") + "\n"

        //        if let handle = try? FileHandle(forWritingTo: fileURL) {
        //            handle.seekToEndOfFile()
        if let data = joined.data(using: .utf8) {
            fileHandle?.write(data)
        }
        // handle.closeFile() //Here we are closing
        //        } else {
        //            try? joined.write(to: fileURL, atomically: true, encoding: .utf8)
        //        }

        print("✅ Wrote \(index) rows to \(fileURL.lastPathComponent)")
        index = 0  // reuse buffer from start
    }

    deinit {
        flush()
    }
    
    func closeFile(){
        fileHandle?.closeFile()
    }
}

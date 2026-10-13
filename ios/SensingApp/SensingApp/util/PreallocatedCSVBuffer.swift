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
    private let fileURL: URL        // to-be-processed/<name>.csv.part — ours until sealed
    private var fileHandle: FileHandle?
    private var isClosed = false

    init(filename: String = "data.csv", capacity: Int = 10_000) {
        self.capacity = capacity
        self.buffer = Array(repeating: "", count: capacity)

        // Prepare file path. Writing happens under ".part" so the uploader never
        // takes a file this buffer still has open.
        let fileManager = FileManager.default
        let docsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docsURL.appendingPathComponent("to-be-processed")
        fileURL = dir.appendingPathComponent(filename + ".part")

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

        // The throwing API: the non-throwing write(_:) raises an uncatchable
        // Objective-C exception when the disk is full.
        if let data = joined.data(using: .utf8), let handle = fileHandle {
            do {
                try handle.write(contentsOf: data)
            } catch {
                print("Write failed for \(fileURL.lastPathComponent): \(error)")
                Logger.shared.append("Write failed for \(fileURL.lastPathComponent): \(error)")
            }
        }

        print("Wrote \(index) rows to \(fileURL.lastPathComponent)")
        index = 0  // reuse buffer from start
    }

    deinit {
        closeFile()
    }

    /// Flushes, closes, and publishes the file under its final name so the
    /// uploader can take it. Safe to call more than once.
    func closeFile() {
        guard !isClosed else { return }
        flush()
        fileHandle?.synchronizeFile()
        fileHandle?.closeFile()
        fileHandle = nil
        isClosed = true

        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let sealed = try FileManager.default.seal(fileURL)
            print("Sealed \(sealed.lastPathComponent)")
        } catch {
            print("Failed to seal \(fileURL.lastPathComponent): \(error)")
            Logger.shared.append("Failed to seal \(fileURL.lastPathComponent): \(error)")
        }
    }
}

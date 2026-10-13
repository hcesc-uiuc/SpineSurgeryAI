//
//  FileSealingTests.swift
//  SensingAppTests
//
//  Issue #74: file size reads, sealing collisions, rotated databases, WAL cleanup.
//

import Foundation
import SQLite3
import XCTest
@testable import SensingApp

final class FileSealingTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sealing-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func file(_ name: String, _ contents: String = "h\n1\n") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private var emptyDefaults: UserDefaults {
        UserDefaults(suiteName: "sealing-tests-\(UUID().uuidString)")!
    }

    // MARK: currentSize

    func testCurrentSizeSeesAppendsOffTheMainThread() throws {
        // URL.resourceValues kept returning the first size here, so rotation never fired.
        let url = try file("sensorkit_accel_phone_00000.csv.part", "h\n")
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()

        let done = expectation(description: "writes")
        DispatchQueue.global().async {
            _ = try? url.resourceValues(forKeys: [.fileSizeKey])   // prime the URL cache
            for i in 1...3 {
                try? handle.write(contentsOf: Data(repeating: 65, count: 1000))
                XCTAssertEqual(FileManager.default.currentSize(of: url), 2 + i * 1000)
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    // MARK: seal

    func testSealDropsPartExtension() throws {
        let sealed = try FileManager.default.seal(try file("sensorkit_accel_phone_00004.csv.part"))
        XCTAssertEqual(sealed.lastPathComponent, "sensorkit_accel_phone_00004.csv")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sensorkit_accel_phone_00004.csv.part").path))
    }

    func testSealPicksFreeNameWhenTaken() throws {
        _ = try file("sensorkit_accel_phone_00004.csv", "old\n")
        _ = try file("sensorkit_accel_phone_00004-1.csv", "older\n")
        let sealed = try FileManager.default.seal(try file("sensorkit_accel_phone_00004.csv.part", "new\n"))

        XCTAssertEqual(sealed.lastPathComponent, "sensorkit_accel_phone_00004-2.csv")
        XCTAssertEqual(try String(contentsOf: sealed, encoding: .utf8), "new\n")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("sensorkit_accel_phone_00004.csv"),
                                  encoding: .utf8), "old\n")
    }

    // MARK: isSealed for databases

    func testJustRotatedDatabaseIsSealedWithoutGrace() throws {
        // Rotation happens right before each upload, so the grace period must not hold it back.
        let rotated = try file("sqlite_2026-10-05_03-45-17.db")
        let defaults = emptyDefaults
        defaults.set("sqlite_2026-10-05_13-05-40.db", forKey: "dbFileName")
        XCTAssertTrue(Uploader.isSealed(rotated, defaults: defaults))
    }

    func testDatabaseWithLeftoverWALIsNotSealed() throws {
        let rotated = try file("sqlite_2026-10-05_03-45-17.db")
        _ = try file("sqlite_2026-10-05_03-45-17.db-wal", "pending rows")
        let defaults = emptyDefaults
        defaults.set("sqlite_2026-10-05_13-05-40.db", forKey: "dbFileName")
        XCTAssertFalse(Uploader.isSealed(rotated, defaults: defaults))
    }

    // MARK: foldLeftoverWALFiles

    /// A database as pre-#74 builds left it. `crashed: false` is a clean close
    /// under Apple's default persistent WAL (empty -wal and -shm stay behind);
    /// `crashed: true` copies the files while the connection is still open, so
    /// the rows exist only in the -wal, as after a crash.
    private func legacyDatabase(_ name: String, rows: Int, crashed: Bool) throws -> String {
        let path = dir.appendingPathComponent(name).path
        let livePath = dir.appendingPathComponent("live-" + name).path
        var db: OpaquePointer?
        sqlite3_open(crashed ? livePath : path, &db)
        sqlite3_exec(db, "PRAGMA journal_mode = WAL;", nil, nil, nil)
        var persistWAL: Int32 = 1
        sqlite3_file_control(db, "main", SQLITE_FCNTL_PERSIST_WAL, &persistWAL)
        sqlite3_exec(db, "PRAGMA wal_autocheckpoint = 0; CREATE TABLE data (x);", nil, nil, nil)
        for i in 0..<rows { sqlite3_exec(db, "INSERT INTO data VALUES (\(i));", nil, nil, nil) }
        if crashed {
            for suffix in ["", "-wal", "-shm"] {
                try FileManager.default.copyItem(atPath: livePath + suffix, toPath: path + suffix)
            }
        }
        sqlite3_close_v2(db)
        return path
    }

    private func rowCount(_ path: String) -> Int32 {
        var db: OpaquePointer?
        sqlite3_open(path, &db)
        defer { sqlite3_close_v2(db) }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT count(*) FROM data", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        sqlite3_step(stmt)
        return sqlite3_column_int(stmt, 0)
    }

    func testFoldMovesWALRowsIntoDatabaseAndRemovesSidecars() throws {
        let path = try legacyDatabase("sqlite_2026-10-05_03-45-17.db", rows: 50, crashed: true)
        let walSize = FileManager.default.currentSize(of: URL(fileURLWithPath: path + "-wal")) ?? 0
        XCTAssertGreaterThan(walSize, 0, "fixture should hold rows only in the -wal")

        SQLiteSaver.foldLeftoverWALFiles(in: dir, activeName: "sqlite_2026-10-05_13-05-40.db")

        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "-shm"))
        XCTAssertEqual(rowCount(path), 50)
    }

    func testFoldSkipsActiveDatabase() throws {
        let path = try legacyDatabase("sqlite_2026-10-05_13-05-40.db", rows: 3, crashed: false)
        SQLiteSaver.foldLeftoverWALFiles(in: dir, activeName: "sqlite_2026-10-05_13-05-40.db")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "-wal"))
    }
}

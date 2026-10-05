//
//  EnrollmentCode.swift
//  SensingApp
//
//  Coordinator-issued 6-digit codes, asked for at a phone's FIRST sign-in so
//  random App Store users can't join the study.
//
//  The hashes are a speed bump, not a secret: all 10^6 codes can be hashed in
//  under a second. The real gate is the server (403 → invalidEnrollmentCode).
//
//  A code must be added in BOTH places, or the phone rejects it before the
//  server ever sees it:
//    1. echo -n 123456 | shasum -a 256   → append the digest below
//    2. python manage_enrollment_codes.py add 123456
//
//  Known limits: codes are shared and can't be revoked without an app update;
//  a new phone re-asks until the backend can say "this account is enrolled".
//

import Foundation
import CryptoKit

enum EnrollmentGate {

    /// SHA-256 (lowercase hex) digests of the valid 6-digit codes.
    private static let validCodeHashes: Set<String> = [
        "31edb8a5cb6d54725aa4de0e6c08cb8eccaa3857929e3d1f1c1406b6eba3dd46",
        "e776c75105a3bfb8f814806f304c993882839bb6e844efc4837c657ddb609976",
        "9ff4a8311d44c753fa528f7f0d75a57ef5bc38103019e72ffaf5b5709a3db51a",
        "58009946159e95ee598cf5fe8bfa3161a5131354b46ed23ba09ef2d4962777d6",
        "b8ba2c7b82567dc3455a20c21f27bb54491ba9fd899e74aec5fa8662f574ae96",
        "731cb46a035c0b459db64138bf20070508c1634ceb9dfac990477d5cd1a66c40",
        "6b10910a1aa8275732b34f8724a0c0cc477e902b63f75d9b39d48eb921032749",
        "9fd8dbceed673e4d40877ec5a616f1f36689eec13255f35e2ff9a7420a3a716d",
        "96565866998f29b616dbe29c88756e224ca4d022238ad3952cb1a46dcdd2570a",
        "056d79ccd39c3e10b24f6d9093f1fc0f25336aac8f6995abc2db184f8d45f0e4"
    ]

    /// True when the entered text is one of the coordinator-issued codes.
    static func validate(_ code: String) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 6, trimmed.allSatisfy(\.isNumber) else { return false }
        return validCodeHashes.contains(sha256Hex(trimmed))
    }

    private static func sha256Hex(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

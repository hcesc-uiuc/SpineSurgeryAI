//
//  EnrollmentCode.swift
//  SensingApp
//
//  Coordinator-issued study enrollment codes.
//
//  Random App Store users must not be able to join the study: at FIRST
//  sign-in the login screen asks for a 6-digit code handed out by the
//  study coordinators. Returning users on the same device are not asked
//  again (see ProfileStore.isEnrolled).
//
//  INTERIM CLIENT-SIDE VALIDATION:
//  Until the backend implements server-side codes (PROFILE_API.md), the
//  valid codes are baked into the app — as SHA-256 hashes, so the codes
//  cannot be read out of the shipped binary with `strings`. The plaintext
//  codes are distributed to coordinators out-of-band and are intentionally
//  NOT in this repository.
//
//  To add a code:   echo -n 123456 | shasum -a 256
//  and append the hex digest to validCodeHashes.
//
//  KNOWN LIMITS (accepted for the pilot):
//    • Codes are shared, reusable, and cannot be revoked without an
//      app update.
//    • A new device cannot know an Apple ID is already enrolled, so the
//      prompt reappears there until the backend can answer that lookup.
//  Server-side replacement: validate() becomes a single call to
//  POST /auth/login with enrollment_code (already sent — see
//  SecureAuthManager.login), and this hash list is deleted.
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

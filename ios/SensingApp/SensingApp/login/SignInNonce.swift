//
//  SignInNonce.swift
//  SensingApp
//
//  Sign in with Apple nonce. The app makes a fresh random value per sign-in,
//  hands Apple its SHA-256 (Apple signs that into the identity token's "nonce"
//  claim), and sends the raw value to /auth/login. The server checks
//  SHA-256(raw) == claim and records it as used, so a leaked identity token
//  can't be replayed. Made locally because the SignInWithAppleButton request
//  closure is synchronous and can't wait on a network call.
//

import Foundation
import CryptoKit
import Security

enum SignInNonce {

    /// 32 random bytes, base64url without padding.
    static func random() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Lowercase hex SHA-256: the value given to Apple, and what the server
    /// compares against hashlib.sha256(raw).hexdigest().
    static func sha256(_ raw: String) -> String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The "nonce" claim of an Apple identity token, read WITHOUT checking the
    /// signature: only used to pick which raw nonce goes with this token. The
    /// server verifies the token itself.
    static func claim(inIdentityToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return payload["nonce"] as? String
    }
}


import Foundation
import CryptoKit
import SwiftUI
internal import Combine

@MainActor
class SecureAuthManager: ObservableObject {

    @Published var isAuthenticated = false
    @AppStorage("isLoggedIn") private var storedLogin: Bool = false

    private let key = "study_app_password_hash"
    private let salt = "study_app_salt_2026" // constant salt for now

    init() {
        setupPasswordIfNeeded()
        // Restore login state from AppStorage
        isAuthenticated = storedLogin
    }

    private func setupPasswordIfNeeded() {
        if KeychainManager.shared.read(key: key) == nil {
            let hash = hashPassword("password") // default initial password
            KeychainManager.shared.save(key: key, data: hash)
        }
    }

    func login(password: String) {
        guard let storedHash = KeychainManager.shared.read(key: key) else { return }

        let inputHash = hashPassword(password)

        if inputHash == storedHash {
            isAuthenticated = true
            storedLogin = true
        }
    }

    func logout() {
        isAuthenticated = false
        storedLogin = false
    }

    private func hashPassword(_ password: String) -> Data {
        let combined = password + salt
        let hashed = SHA256.hash(data: Data(combined.utf8))
        return Data(hashed)
    }
}

// Type4Me/Auth/CloudAuthManager.swift

import Foundation
import os

@MainActor
final class CloudAuthManager: ObservableObject, Sendable {
    static let shared = CloudAuthManager()

    @Published private(set) var isLoggedIn = false
    @Published private(set) var userEmail: String?
    @Published private(set) var userID: String?

    private let logger = Logger(subsystem: "com.type4me.app", category: "CloudAuth")

    // JWT stored in UserDefaults (not Keychain for simplicity — it's short-lived anyway)
    private var jwt: String? {
        get { UserDefaults.standard.string(forKey: "tf_cloud_jwt") }
        set { UserDefaults.standard.set(newValue, forKey: "tf_cloud_jwt") }
    }

    private init() {
        // Restore session from stored JWT
        if let token = jwt, !isTokenExpired(token) {
            isLoggedIn = true
            userEmail = UserDefaults.standard.string(forKey: "tf_cloud_email")
            userID = UserDefaults.standard.string(forKey: "tf_cloud_user_id")
        }
    }

    func sendCode(email: String) async throws {
        let endpoint = CloudConfig.apiEndpoint + "/auth/send-code"
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["email": email])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CloudAuthError.serverError(body)
        }
    }

    func verify(email: String, code: String) async throws {
        let endpoint = CloudConfig.apiEndpoint + "/auth/verify"
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct VerifyRequest: Encodable { let email: String; let code: String }
        request.httpBody = try JSONEncoder().encode(VerifyRequest(email: email, code: code))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            if (response as? HTTPURLResponse)?.statusCode == 401 {
                throw CloudAuthError.invalidCode
            }
            throw CloudAuthError.serverError(String(data: data, encoding: .utf8) ?? "")
        }

        struct VerifyResponse: Decodable { let token: String; let user_id: String; let email: String }
        let result = try JSONDecoder().decode(VerifyResponse.self, from: data)

        jwt = result.token
        UserDefaults.standard.set(result.email, forKey: "tf_cloud_email")
        UserDefaults.standard.set(result.user_id, forKey: "tf_cloud_user_id")
        isLoggedIn = true
        userEmail = result.email
        userID = result.user_id
    }

    func accessToken() async -> String? {
        guard let token = jwt, !isTokenExpired(token) else {
            isLoggedIn = false
            return nil
        }
        return token
    }

    func signOut() async {
        jwt = nil
        UserDefaults.standard.removeObject(forKey: "tf_cloud_email")
        UserDefaults.standard.removeObject(forKey: "tf_cloud_user_id")
        isLoggedIn = false
        userEmail = nil
        userID = nil
    }

    // Check JWT expiry without verifying signature (client-side only)
    private func isTokenExpired(_ token: String) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count == 3,
              let payloadData = Data(base64URLEncoded: String(parts[1])),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let exp = payload["exp"] as? TimeInterval else {
            return true
        }
        return Date().timeIntervalSince1970 > exp
    }
}

// Base64URL decoding helper
private extension Data {
    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        self.init(base64Encoded: base64)
    }
}

enum CloudAuthError: Error, LocalizedError {
    case notConfigured
    case invalidCode
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Type4Me Cloud is not configured"
        case .invalidCode: return "Invalid or expired verification code"
        case .serverError(let msg): return "Server error: \(msg)"
        }
    }
}

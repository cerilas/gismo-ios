import Foundation
import SwiftUI
import GoogleSignIn
import UIKit

// MARK: - User Model

struct GismoUser: Codable, Equatable, Identifiable {
    let id: String
    let fullName: String
    let email: String
    let phone: String
    let cleanPhone: String
    let phoneVerified: Bool
    let googleId: String?
    let isGoogleConnected: Bool
    let avatarUrl: String
    let authProvider: String

    enum CodingKeys: String, CodingKey {
        case id
        case fullName          = "full_name"
        case email
        case phone
        case cleanPhone        = "clean_phone"
        case phoneVerified     = "phone_verified"
        case googleId          = "google_id"
        case isGoogleConnected = "is_google_connected"
        case avatarUrl         = "avatar_url"
        case authProvider      = "auth_provider"
    }

    var initials: String {
        let parts = fullName.split(separator: " ").map(String.init)
        if parts.count >= 2,
           let first = parts.first?.first,
           let last = parts.last?.first {
            return "\(first)\(last)".uppercased()
        }
        return String(fullName.prefix(2)).uppercased()
    }
}

// MARK: - API Responses

private struct AuthResponse: Decodable {
    let success: Bool?
    let token: String?
    let user: GismoUser?
    let error: String?
    let message: String?
}

private struct SendOTPResponse: Decodable {
    let success: Bool?
    let smsSent: Bool?
    let phone: String?
    let cleanPhone: String?
    let expiresIn: Int?
    let message: String?
    let error: String?
}

private struct MeResponse: Decodable {
    let authenticated: Bool?
    let user: GismoUser?
    let error: String?
}

// MARK: - AuthService

@MainActor
final class AuthService: ObservableObject {
    static let shared = AuthService()

    @Published var currentUser: GismoUser?
    @Published var isAuthenticated: Bool = false
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private let tokenKey = "gismo_auth_jwt_token"
    private let userKey  = "gismo_auth_current_user"

    private var authToken: String? {
        get { UserDefaults.standard.string(forKey: tokenKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: tokenKey)
            } else {
                UserDefaults.standard.removeObject(forKey: tokenKey)
            }
        }
    }

    private init() {
        loadSavedSession()
    }

    // MARK: - Session Persistence

    func loadSavedSession() {
        if let token = authToken, !token.isEmpty,
           let data = UserDefaults.standard.data(forKey: userKey),
           let savedUser = try? JSONDecoder().decode(GismoUser.self, from: data) {
            self.currentUser = savedUser
            self.isAuthenticated = true
            Task {
                await refreshProfile()
            }
        } else {
            self.currentUser = nil
            self.isAuthenticated = false
        }
    }

    private func saveSession(token: String, user: GismoUser) {
        self.authToken = token
        if let encoded = try? JSONEncoder().encode(user) {
            UserDefaults.standard.set(encoded, forKey: userKey)
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
            self.currentUser = user
            self.isAuthenticated = true
            self.errorMessage = nil
        }
    }

    func refreshProfile() async {
        guard let token = authToken, !token.isEmpty else { return }
        guard let url = URL(string: "\(Config.baseURL)/api/auth/me") else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(Config.apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = Config.requestTimeout

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                signOut()
                return
            }
            let decoded = try JSONDecoder().decode(MeResponse.self, from: data)
            if let user = decoded.user {
                if let encoded = try? JSONEncoder().encode(user) {
                    UserDefaults.standard.set(encoded, forKey: userKey)
                }
                self.currentUser = user
            }
        } catch {
            // Keep cached session if offline
        }
    }

    // MARK: - 1. Send Cerilas SMS OTP

    func sendOTP(phone: String, email: String? = nil, purpose: String = "register") async throws -> String {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        var body: [String: Any] = [
            "phone": phone,
            "purpose": purpose
        ]
        if let email, !email.isEmpty {
            body["email"] = email
        }

        let response: SendOTPResponse = try await post(path: "/api/auth/send-otp", body: body)
        if response.success == true {
            return response.message ?? "Doğrulama kodu telefonunuza SMS olarak gönderildi."
        } else {
            let msg = response.error ?? "SMS doğrulama kodu gönderilemedi."
            errorMessage = msg
            throw NSError(domain: "Auth", code: 400, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    // MARK: - 2. Register with Email + Phone + Password + SMS OTP

    func register(
        fullName: String,
        email: String,
        phone: String,
        password: String,
        otpCode: String
    ) async throws {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let body: [String: Any] = [
            "full_name": fullName.trimmingCharacters(in: .whitespacesAndNewlines),
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            "phone": phone.trimmingCharacters(in: .whitespacesAndNewlines),
            "password": password,
            "otp_code": otpCode.trimmingCharacters(in: .whitespacesAndNewlines)
        ]

        let response: AuthResponse = try await post(path: "/api/auth/register", body: body)
        guard let token = response.token, let user = response.user else {
            let msg = response.error ?? "Kayıt işlemi tamamlanamadı."
            errorMessage = msg
            throw NSError(domain: "Auth", code: 400, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        saveSession(token: token, user: user)
    }

    // MARK: - 3. Login with Email or Phone + Password

    func loginWithPassword(identifier: String, password: String) async throws {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let body: [String: Any] = [
            "identifier": identifier.trimmingCharacters(in: .whitespacesAndNewlines),
            "password": password
        ]

        let response: AuthResponse = try await post(path: "/api/auth/login", body: body)
        guard let token = response.token, let user = response.user else {
            let msg = response.error ?? "Giriş yapılamadı."
            errorMessage = msg
            throw NSError(domain: "Auth", code: 401, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        saveSession(token: token, user: user)
    }

    // MARK: - 4. Login with Phone + Cerilas SMS OTP

    func loginWithOTP(phone: String, otpCode: String) async throws {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let body: [String: Any] = [
            "phone": phone.trimmingCharacters(in: .whitespacesAndNewlines),
            "otp_code": otpCode.trimmingCharacters(in: .whitespacesAndNewlines)
        ]

        let response: AuthResponse = try await post(path: "/api/auth/login-otp", body: body)
        guard let token = response.token, let user = response.user else {
            let msg = response.error ?? "SMS ile giriş yapılamadı."
            errorMessage = msg
            throw NSError(domain: "Auth", code: 401, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        saveSession(token: token, user: user)
    }

    // MARK: - 5. Sign In / Sign Up with Google (Persists in DB)

    func signInWithGoogle() async throws {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController ?? windowScene.windows.first?.rootViewController else {
            throw NSError(domain: "Auth", code: 500, userInfo: [NSLocalizedDescriptionKey: "Ekran bulunamadı."])
        }

        let topVC = Self.topViewController(from: rootVC)
        let clientId = GoogleAuthService.shared.clientId
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientId)

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let googleUser: GIDGoogleUser = try await withCheckedThrowingContinuation { continuation in
            GIDSignIn.sharedInstance.signIn(
                withPresenting: topVC,
                hint: nil,
                additionalScopes: GoogleAuthService.shared.requiredScopes
            ) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let user = result?.user else {
                    continuation.resume(
                        throwing: NSError(
                            domain: "Auth",
                            code: 400,
                            userInfo: [NSLocalizedDescriptionKey: "Google hesap bilgisi alınamadı."]
                        )
                    )
                    return
                }
                continuation.resume(returning: user)
            }
        }

        // Sync with GoogleAuthService
        GoogleAuthService.shared.currentUser = googleUser
        GoogleAuthService.shared.isConnected = true
        GoogleAuthService.shared.lastAuthError = nil

        let idToken = googleUser.idToken?.tokenString ?? ""
        let googleId = googleUser.userID ?? ""
        let email = googleUser.profile?.email ?? ""
        let fullName = googleUser.profile?.name ?? ""
        let avatarUrl = googleUser.profile?.imageURL(withDimension: 200)?.absoluteString ?? ""

        let body: [String: Any] = [
            "id_token": idToken,
            "google_id": googleId,
            "email": email,
            "full_name": fullName,
            "avatar_url": avatarUrl
        ]

        let response: AuthResponse = try await post(path: "/api/auth/google", body: body)
        guard let token = response.token, let user = response.user else {
            let msg = response.error ?? "Google ile giriş sunucuya kaydedilemedi."
            errorMessage = msg
            throw NSError(domain: "Auth", code: 500, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        saveSession(token: token, user: user)
    }

    // MARK: - 6. Sign Out & Delete Account

    func signOut() {
        authToken = nil
        UserDefaults.standard.removeObject(forKey: userKey)
        GoogleAuthService.shared.signOut()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            self.currentUser = nil
            self.isAuthenticated = false
            self.errorMessage = nil
        }
    }

    func deleteAccount() async throws {
        guard let token = authToken, !token.isEmpty else { return }
        guard let url = URL(string: "\(Config.baseURL)/api/auth/account") else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue(Config.apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 12

        _ = try? await URLSession.shared.data(for: req)
        signOut()
    }

    // MARK: - Networking Helper

    private func post<T: Decodable>(path: String, body: [String: Any]) async throws -> T {
        guard let url = URL(string: "\(Config.baseURL)\(path)") else {
            throw NSError(domain: "Auth", code: 400, userInfo: [NSLocalizedDescriptionKey: "Geçersiz sunucu adresi."])
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Config.apiKey, forHTTPHeaderField: "x-api-key")
        if let token = authToken, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 14
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 500

        if httpStatus >= 400 {
            if let errJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let serverError = errJson["error"] as? String {
                errorMessage = serverError
                throw NSError(domain: "Auth", code: httpStatus, userInfo: [NSLocalizedDescriptionKey: serverError])
            }
            let fallback = "Sunucu hatası (\(httpStatus)). Lütfen tekrar deneyin."
            errorMessage = fallback
            throw NSError(domain: "Auth", code: httpStatus, userInfo: [NSLocalizedDescriptionKey: fallback])
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func topViewController(from root: UIViewController) -> UIViewController {
        var current = root
        while let presented = current.presentedViewController {
            current = presented
        }
        return current
    }
}

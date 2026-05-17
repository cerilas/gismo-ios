import Foundation
import Combine

// MARK: - ESP32 Local Service
// Communicates with ESP32 while phone is on ESP32's AP network.

class ESPService {
    static let shared = ESPService()

    /// Default ESP32 AP gateway address
    var baseURL = Config.espBaseURL

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    // MARK: - Scan Available Networks

    func scanNetworks() async throws -> [WiFiNetwork] {
        guard let url = URL(string: "\(baseURL)/scan") else {
            throw ESPError.invalidURL
        }
        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ESPError.serverError
        }
        let decoded = try JSONDecoder().decode([ESPNetworkResponse].self, from: data)
        return decoded.map { WiFiNetwork(ssid: $0.ssid, rssi: $0.rssi, isSecured: $0.auth != 0) }
    }

    // MARK: - Send WiFi Credentials

    func connectToNetwork(ssid: String, password: String, robotID: UUID, robotName: String) async throws {
        guard let url = URL(string: "\(baseURL)/connect") else {
            throw ESPError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = [
            "ssid": ssid,
            "pass": password,
            "robot_id": robotID.uuidString,
            "robot_name": robotName
        ]
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ESPError.serverError
        }
    }

    // MARK: - Check Status

    func checkStatus() async throws -> ESPStatus {
        guard let url = URL(string: "\(baseURL)/status") else {
            throw ESPError.invalidURL
        }
        let (data, _) = try await session.data(from: url)
        return try JSONDecoder().decode(ESPStatus.self, from: data)
    }
}

// MARK: - Response Types

struct ESPNetworkResponse: Codable {
    let ssid: String
    let rssi: Int
    let auth: Int   // 0 = open, >0 = secured
}

struct ESPStatus: Codable {
    let connected: Bool
    let ip: String?
    let ssid: String?
}

// MARK: - Errors

enum ESPError: LocalizedError {
    case invalidURL
    case serverError
    case notConnectedToESP

    var errorDescription: String? {
        switch self {
        case .invalidURL:         return "Geçersiz URL."
        case .serverError:        return "ESP32 yanıt vermedi."
        case .notConnectedToESP:  return "Lütfen önce ESP32'nin WiFi ağına bağlanın."
        }
    }
}

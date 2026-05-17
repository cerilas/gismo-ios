import Foundation

// MARK: - Backend Service
// Uses WebSocket for live robot list, status and command traffic.
// REST health check remains for basic backend availability checks.

class DatabaseService {
    static let shared = DatabaseService()

    private let baseURL: String = Config.baseURL
    private let apiKey: String  = Config.apiKey

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = Config.requestTimeout
        config.timeoutIntervalForResource = Config.requestTimeout * 2
        return URLSession(configuration: config)
    }()

    // MARK: - Shared request builder

    private func makeRequest(_ path: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body = body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    // MARK: - Send Command

    func sendCommand(_ command: RobotCommand, to robotID: UUID) async throws {
        try await WebSocketService.shared.sendCommand(command, to: robotID)
    }

    private func sendCommandOverREST(_ command: RobotCommand, to robotID: UUID) async throws {
        let request = try makeRequest("/api/commands", method: "POST", body: [
            "robot_id": robotID.uuidString,
            "command":  command.rawValue
        ])
        let (data, response) = try await session.data(for: request)
        try validateResponse(data: data, response: response)
    }

    // MARK: - Fetch Robots

    func fetchRobots() async throws -> [Robot] {
        try await WebSocketService.shared.fetchRobots()
    }

    private func fetchAllRobotsOverREST() async throws -> [Robot] {
        let pageSize = 100
        var page = 1
        var allRobots: [RobotDTO] = []
        var seenRobotIDs = Set<String>()

        while true {
            let response: RobotListResponse = try await fetchRobotPage(page: page, limit: pageSize)
            let newRobots = response.robots.filter { seenRobotIDs.insert($0.id).inserted }
            allRobots.append(contentsOf: newRobots)

            let shouldFetchNextPage = response.hasMore(currentPage: page, pageSize: pageSize)
                || (response.pagination == nil && response.robots.count == pageSize && !newRobots.isEmpty)

            guard shouldFetchNextPage else {
                return allRobots.map { $0.toRobot() }
            }

            page += 1
        }
    }

    private func fetchRobotPage(page: Int, limit: Int) async throws -> RobotListResponse {
        let request = try makeRequest("/api/robots?page=\(page)&limit=\(limit)")
        let (data, response) = try await session.data(for: request)
        try validateResponse(data: data, response: response)
        return try JSONDecoder().decode(RobotListResponse.self, from: data)
    }

    // MARK: - Register Robot

    func registerRobot(_ robot: Robot) async throws {
        try await WebSocketService.shared.registerRobot(robot)
    }

    private func registerRobotOverREST(_ robot: Robot) async throws {
        let request = try makeRequest("/api/robots", method: "POST", body: [
            "id":   robot.id.uuidString,
            "name": robot.name
        ])
        let (data, response) = try await session.data(for: request)
        try validateResponse(data: data, response: response)
    }

    // MARK: - Delete Robot

    func deleteRobot(id: UUID) async throws {
        try await WebSocketService.shared.deleteRobot(id: id)
    }

    private func deleteRobotOverREST(id: UUID) async throws {
        let request = try makeRequest("/api/robots/\(id.uuidString)", method: "DELETE")
        let (data, response) = try await session.data(for: request)
        try validateResponse(data: data, response: response)
    }

    // MARK: - Health Check

    func healthCheck() async -> Bool {
        guard let url = URL(string: "\(baseURL)/health") else { return false }
        do {
            let (_, response) = try await session.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func validateResponse(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.requestFailed(statusCode: nil, message: nil)
        }

        guard (200...299).contains(http.statusCode) else {
            let errorMessage = try? JSONDecoder().decode(APIErrorResponse.self, from: data).displayMessage

            if http.statusCode == 401 {
                throw APIError.unauthorized(message: errorMessage)
            }

            throw APIError.requestFailed(statusCode: http.statusCode, message: errorMessage)
        }
    }
}

// MARK: - DTOs

private struct RobotListResponse: Decodable {
    let robots: [RobotDTO]
    let pagination: Pagination?

    init(from decoder: Decoder) throws {
        if let robots = try? [RobotDTO](from: decoder) {
            self.robots = robots
            self.pagination = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let robots = try container.decodeIfPresent([RobotDTO].self, forKey: .data) {
            self.robots = robots
        } else if let robots = try container.decodeIfPresent([RobotDTO].self, forKey: .robots) {
            self.robots = robots
        } else {
            self.robots = try [RobotDTO](from: decoder)
        }

        pagination = try container.decodeIfPresent(Pagination.self, forKey: .pagination)
            ?? container.decodeIfPresent(Pagination.self, forKey: .meta)
    }

    func hasMore(currentPage: Int, pageSize: Int) -> Bool {
        guard let pagination else { return false }

        if let hasMore = pagination.hasMore {
            return hasMore
        }

        if let totalPages = pagination.totalPages {
            return currentPage < totalPages
        }

        if let total = pagination.total {
            return currentPage * pageSize < total
        }

        return false
    }

    fileprivate enum CodingKeys: String, CodingKey {
        case data
        case robots
        case pagination
        case meta
    }
}

private struct Pagination: Decodable {
    let total: Int?
    let totalPages: Int?
    let hasMore: Bool?

    fileprivate enum CodingKeys: String, CodingKey {
        case total
        case totalPages
        case total_pages
        case hasMore
        case has_more
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = try container.decodeIfPresent(Int.self, forKey: .total)
        totalPages = try container.decodeIfPresent(Int.self, forKey: .totalPages)
            ?? container.decodeIfPresent(Int.self, forKey: .total_pages)
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore)
            ?? container.decodeIfPresent(Bool.self, forKey: .has_more)
    }
}

private struct RobotDTO: Decodable {
    let id: String
    let name: String
    let lastIP: String?
    let isOnline: Bool
    let lastSeen: String?

    fileprivate enum CodingKeys: String, CodingKey {
        case id
        case robotID = "robot_id"
        case name
        case robotName = "robot_name"
        case lastIP = "lastIP"
        case lastIp = "lastIp"
        case last_ip
        case ipAddress
        case ip_address
        case isOnline
        case is_online
        case online
        case lastSeen
        case last_seen
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.firstString(for: [CodingKeys.id, CodingKeys.robotID]) ?? UUID().uuidString
        name = try container.firstString(for: [CodingKeys.name, CodingKeys.robotName]) ?? "Gismo"
        lastIP = try container.firstString(for: [
            CodingKeys.lastIP,
            CodingKeys.lastIp,
            CodingKeys.last_ip,
            CodingKeys.ipAddress,
            CodingKeys.ip_address
        ])
        isOnline = try container.firstBool(for: [
            CodingKeys.isOnline,
            CodingKeys.is_online,
            CodingKeys.online
        ]) ?? false
        lastSeen = try container.firstString(for: [CodingKeys.lastSeen, CodingKeys.last_seen])
    }

    func toRobot() -> Robot {
        Robot(
            id: UUID(uuidString: id) ?? UUID(),
            name: name,
            ipAddress: lastIP,
            lastSeen: nil,
            isOnline: isOnline
        )
    }
}

private extension KeyedDecodingContainer where Key == RobotDTO.CodingKeys {
    func firstString(for keys: [Key]) throws -> String? {
        for key in keys {
            if let value = try? decodeIfPresent(String.self, forKey: key) {
                return value
            }
            if let value = try? decodeIfPresent(Int.self, forKey: key) {
                return String(value)
            }
        }
        return nil
    }

    func firstBool(for keys: [Key]) throws -> Bool? {
        for key in keys {
            if let value = try? decodeIfPresent(Bool.self, forKey: key) {
                return value
            }
            if let value = try? decodeIfPresent(Int.self, forKey: key) {
                return value != 0
            }
            if let value = try? decodeIfPresent(String.self, forKey: key) {
                switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "true", "1", "yes", "online":
                    return true
                case "false", "0", "no", "offline":
                    return false
                default:
                    break
                }
            }
        }
        return nil
    }
}

private struct APIErrorResponse: Decodable {
    let error: String?
    let message: String?

    var displayMessage: String? {
        message ?? error
    }
}

// MARK: - Errors

enum APIError: LocalizedError {
    case invalidURL
    case unauthorized(message: String?)
    case requestFailed(statusCode: Int?, message: String?)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Geçersiz sunucu adresi."
        case .unauthorized(let message):
            return message ?? "API anahtarı geçersiz. Config.apiKey değerini Railway API_KEY ile aynı yapın."
        case .requestFailed(let statusCode, let message):
            if let message {
                return message
            }
            if let statusCode {
                return "Sunucu isteği başarısız oldu. HTTP \(statusCode)."
            }
            return "Sunucu isteği başarısız oldu. Bağlantıyı kontrol edin."
        case .notConnected:
            return "Sunucuya bağlanılamadı."
        }
    }
}

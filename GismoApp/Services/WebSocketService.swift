import Foundation

@MainActor
final class WebSocketService {
    static let shared = WebSocketService()
    static let robotsDidChangeNotification = Notification.Name("WebSocketServiceRobotsDidChange")

    private let session = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pendingRequests: [String: CheckedContinuation<Data, Error>] = [:]
    private var cachedRobots: [Robot] = []

    private init() {}

    func connect() {
        guard task == nil else { return }
        guard let url = makeWebSocketURL() else { return }

        var request = URLRequest(url: url)
        request.setValue(Config.apiKey, forHTTPHeaderField: "x-api-key")

        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        failPendingRequests(WebSocketError.disconnected)
    }

    func fetchRobots() async throws -> [Robot] {
        let data = try await request([
            "type": "list_robots"
        ], expecting: "robots")
        let response = try JSONDecoder().decode(RobotsResponse.self, from: data)
        cachedRobots = response.robots.map { $0.toRobot() }
        notifyRobotsChanged()
        return cachedRobots
    }

    func sendCommand(_ command: RobotCommand, to robotID: UUID) async throws {
        _ = try await request([
            "type": "command",
            "robot_id": robotID.uuidString,
            "command": command.rawValue
        ], expecting: "command_ack")
    }

    func registerRobot(_ robot: Robot) async throws {
        let data = try await request([
            "type": "register_robot",
            "id": robot.id.uuidString,
            "name": robot.name
        ], expecting: "robot_registered")
        let response = try JSONDecoder().decode(RobotResponse.self, from: data)
        upsertRobot(response.robot.toRobot())
    }

    func deleteRobot(id: UUID) async throws {
        _ = try await request([
            "type": "delete_robot",
            "robot_id": id.uuidString
        ], expecting: "robot_deleted_ack")
        cachedRobots.removeAll { $0.id == id }
        notifyRobotsChanged()
    }

    func currentRobots() -> [Robot] {
        cachedRobots
    }

    private func makeWebSocketURL() -> URL? {
        guard var components = URLComponents(string: Config.baseURL) else { return nil }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/ws"
        components.queryItems = [
            URLQueryItem(name: "role", value: "app"),
            URLQueryItem(name: "api_key", value: Config.apiKey)
        ]
        return components.url
    }

    private func request(_ message: [String: Any], expecting expectedType: String) async throws -> Data {
        connect()

        guard let task else {
            throw WebSocketError.disconnected
        }

        let requestID = UUID().uuidString
        var payload = message
        payload["request_id"] = requestID

        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(decoding: data, as: UTF8.self)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID] = continuation

            task.send(.string(text)) { [weak self] error in
                guard let error else { return }
                Task { @MainActor in
                    self?.resumeRequest(requestID, with: .failure(error))
                }
            }

            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                self?.timeoutRequest(requestID, expectedType: expectedType)
            }
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            guard let task else { return }

            do {
                let message = try await task.receive()
                try handle(message)
            } catch {
                self.task = nil
                failPendingRequests(error)
                return
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) throws {
        let data: Data

        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let messageData):
            data = messageData
        @unknown default:
            return
        }

        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else {
            return
        }

        if type == "error" {
            let requestID = object["request_id"] as? String
            let message = object["message"] as? String ?? "WebSocket isteği başarısız oldu."
            if let requestID {
                resumeRequest(requestID, with: .failure(WebSocketError.server(message)))
            }
            return
        }

        if let requestID = object["request_id"] as? String {
            resumeRequest(requestID, with: .success(data))
        }

        switch type {
        case "robot_update", "robot_upserted":
            let response = try JSONDecoder().decode(RobotResponse.self, from: data)
            upsertRobot(response.robot.toRobot())
        case "robot_deleted":
            if let robotID = object["robot_id"] as? String,
               let id = UUID(uuidString: robotID) {
                cachedRobots.removeAll { $0.id == id }
                notifyRobotsChanged()
            }
        default:
            break
        }
    }

    private func upsertRobot(_ robot: Robot) {
        if let index = cachedRobots.firstIndex(where: { $0.id == robot.id }) {
            cachedRobots[index] = robot
        } else {
            cachedRobots.insert(robot, at: 0)
        }
        notifyRobotsChanged()
    }

    private func notifyRobotsChanged() {
        NotificationCenter.default.post(
            name: Self.robotsDidChangeNotification,
            object: self,
            userInfo: ["robots": cachedRobots]
        )
    }

    private func resumeRequest(_ requestID: String, with result: Result<Data, Error>) {
        guard let continuation = pendingRequests.removeValue(forKey: requestID) else { return }

        switch result {
        case .success(let data):
            continuation.resume(returning: data)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func timeoutRequest(_ requestID: String, expectedType: String) {
        resumeRequest(requestID, with: .failure(WebSocketError.timeout(expectedType)))
    }

    private func failPendingRequests(_ error: Error) {
        let requests = pendingRequests
        pendingRequests.removeAll()
        for continuation in requests.values {
            continuation.resume(throwing: error)
        }
    }
}

private struct RobotsResponse: Decodable {
    let robots: [WebSocketRobotDTO]
}

private struct RobotResponse: Decodable {
    let robot: WebSocketRobotDTO
}

private struct WebSocketRobotDTO: Decodable {
    let id: String
    let name: String
    let lastIP: String?
    let isOnline: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case lastIP = "last_ip"
        case isOnline = "is_online"
    }

    func toRobot() -> Robot {
        Robot(
            id: UUID(uuidString: id) ?? UUID(),
            name: name,
            ipAddress: lastIP,
            isOnline: isOnline
        )
    }
}

private enum WebSocketError: LocalizedError {
    case disconnected
    case server(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .disconnected:
            return "WebSocket bağlantısı kapalı."
        case .server(let message):
            return message
        case .timeout(let type):
            return "\(type) WebSocket yanıtı zaman aşımına uğradı."
        }
    }
}

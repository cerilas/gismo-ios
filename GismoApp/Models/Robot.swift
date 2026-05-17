import Foundation

// MARK: - Robot Model

struct Robot: Identifiable, Codable {
    var id: UUID
    var name: String
    var ipAddress: String?
    var lastSeen: Date?
    var isOnline: Bool

    init(id: UUID = UUID(), name: String, ipAddress: String? = nil, lastSeen: Date? = nil, isOnline: Bool = false) {
        self.id = id
        self.name = name
        self.ipAddress = ipAddress
        self.lastSeen = lastSeen
        self.isOnline = isOnline
    }
}

// MARK: - Robot Command

enum RobotCommand: String, CaseIterable {
    case forward  = "F"
    case backward = "B"
    case left     = "L"
    case right    = "R"
    case stop     = "S"
    case resetWiFi = "A"

    var displayName: String {
        switch self {
        case .forward:  return "İleri"
        case .backward: return "Geri"
        case .left:     return "Sol"
        case .right:    return "Sağ"
        case .stop:     return "Dur"
        case .resetWiFi: return "AP Modu"
        }
    }

    var systemIcon: String {
        switch self {
        case .forward:  return "arrow.up"
        case .backward: return "arrow.down"
        case .left:     return "arrow.left"
        case .right:    return "arrow.right"
        case .stop:     return "stop.fill"
        case .resetWiFi: return "wifi.exclamationmark"
        }
    }
}

// MARK: - Mock Data

extension Robot {
    static let mockRobots: [Robot] = [
        Robot(id: UUID(), name: "Gismo-01", ipAddress: "192.168.1.45", lastSeen: Date(), isOnline: true),
        Robot(id: UUID(), name: "Gismo-02", ipAddress: "192.168.1.67", lastSeen: Date().addingTimeInterval(-3600), isOnline: false)
    ]
}

import Foundation

@MainActor
class ControlViewModel: ObservableObject {
    @Published var robot: Robot
    @Published var currentCommand: RobotCommand = .stop
    @Published var isConnected: Bool
    @Published var lastCommandTime: Date?
    @Published var commandLog: [CommandEntry] = []
    @Published var errorMessage: String?
    @Published var commandStatusMessage: String?

    private var robotsObserver: NSObjectProtocol?

    struct CommandEntry: Identifiable {
        let id = UUID()
        let command: RobotCommand
        let time: Date
    }

    init(robot: Robot) {
        self.robot = robot
        self.isConnected = robot.isOnline
        WebSocketService.shared.connect()
        robotsObserver = NotificationCenter.default.addObserver(
            forName: WebSocketService.robotsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let self,
                let robots = notification.userInfo?["robots"] as? [Robot],
                let updatedRobot = robots.first(where: { $0.id == robot.id })
            else { return }

            Task { @MainActor in
                self.robot = updatedRobot
                self.isConnected = updatedRobot.isOnline
            }
        }
    }

    deinit {
        if let robotsObserver {
            NotificationCenter.default.removeObserver(robotsObserver)
        }
    }

    // MARK: - Send Command

    func sendCommand(_ command: RobotCommand) {
        guard isConnected else {
            errorMessage = "Robot çevrimdışı. Komut gönderilemedi."
            return
        }

        errorMessage = nil
        commandStatusMessage = "Komut gönderiliyor: \(command.rawValue)"

        Task {
            do {
                try await DatabaseService.shared.sendCommand(command, to: robot.id)
                currentCommand = command
                lastCommandTime = Date()
                commandStatusMessage = "Komut gönderildi: \(command.rawValue)"
                commandLog.insert(CommandEntry(command: command, time: Date()), at: 0)
                if commandLog.count > 20 { commandLog.removeLast() }
            } catch {
                errorMessage = error.localizedDescription
                commandStatusMessage = nil
                isConnected = false
                currentCommand = .stop
            }
        }
    }

    func stopRobot() {
        sendCommand(.stop)
    }

    func resetRobotToAPMode() {
        guard isConnected else {
            errorMessage = "Robot çevrimdışı. AP moduna alma komutu gönderilemedi."
            return
        }

        errorMessage = nil
        commandStatusMessage = "Robot AP moduna alınıyor..."

        Task {
            do {
                try await DatabaseService.shared.sendCommand(.resetWiFi, to: robot.id)
                currentCommand = .stop
                lastCommandTime = Date()
                commandStatusMessage = "Komut gönderildi. Robot GISMO_AP olarak yeniden başlayacak."
            } catch {
                errorMessage = error.localizedDescription
                commandStatusMessage = nil
            }
        }
    }

    // MARK: - Joystick Direction Mapping

    func commandFromJoystick(dx: CGFloat, dy: CGFloat, threshold: CGFloat = 0.3) -> RobotCommand {
        let magnitude = sqrt(dx * dx + dy * dy)
        guard magnitude > threshold else { return .stop }

        let angle = atan2(dy, dx) * (180 / .pi)
        switch angle {
        case -135 ..< -45:  return .forward   // Up
        case  45  ..< 135:  return .backward  // Down
        case -45  ..< 45:   return .right     // Right
        default:            return .left      // Left
        }
    }
}

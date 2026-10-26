import Foundation

@MainActor
class RobotListViewModel: ObservableObject {
    @Published var robots: [Robot] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    private var loadTask: Task<Void, Never>?
    private var robotsObserver: NSObjectProtocol?
    private var nameObserver: NSObjectProtocol?
    private static let demoRobotID = UUID(uuidString: "00000000-0000-0000-0000-000000002423")!

    init() {
        WebSocketService.shared.connect()
        robotsObserver = NotificationCenter.default.addObserver(
            forName: WebSocketService.robotsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let robots = notification.userInfo?["robots"] as? [Robot] else { return }
            Task { @MainActor in
                guard let self else { return }
                self.robots = self.applyUserRobotName(to: robots)
            }
        }
        nameObserver = NotificationCenter.default.addObserver(
            forName: AuthService.robotNameDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.robots = self.applyUserRobotName(to: self.robots, forceSyncToServer: true)
            }
        }
    }

    deinit {
        if let robotsObserver {
            NotificationCenter.default.removeObserver(robotsObserver)
        }
        if let nameObserver {
            NotificationCenter.default.removeObserver(nameObserver)
        }
    }

    private func perRobotNameKey(for robotId: UUID) -> String {
        let uid = AuthService.shared.currentUser?.id ?? "guest"
        return "user_robot_name_\(uid)_\(robotId.uuidString.lowercased())"
    }

    private func applyUserRobotName(to rawList: [Robot], forceSyncToServer: Bool = false) -> [Robot] {
        let customName = AuthService.shared.customRobotName.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = rawList

        for idx in list.indices {
            let robotId = list[idx].id
            let savedPerRobot = (UserDefaults.standard.string(forKey: perRobotNameKey(for: robotId)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let current = list[idx].name.trimmingCharacters(in: .whitespacesAndNewlines)
            let isDefaultName = current.isEmpty
                || current.lowercased().hasPrefix("gismo")
                || current.lowercased() == "robot"

            let targetName: String? = {
                if !savedPerRobot.isEmpty {
                    return savedPerRobot
                }
                if !customName.isEmpty && (idx == 0 || isDefaultName) {
                    return customName
                }
                return nil
            }()

            if let targetName, !targetName.isEmpty {
                if list[idx].name != targetName {
                    list[idx].name = targetName
                    let updated = list[idx]
                    if updated.id != Self.demoRobotID {
                        Task {
                            try? await DatabaseService.shared.registerRobot(updated)
                        }
                    }
                } else if forceSyncToServer && list[idx].id != Self.demoRobotID {
                    let updated = list[idx]
                    Task {
                        try? await DatabaseService.shared.registerRobot(updated)
                    }
                }
            }
        }

        if list.isEmpty && UserDefaults.standard.bool(forKey: "isTestModeEnabled") {
            let demoName = (UserDefaults.standard.string(forKey: perRobotNameKey(for: Self.demoRobotID)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            list = [
                Robot(
                    id: Self.demoRobotID,
                    name: demoName.isEmpty ? AuthService.shared.effectiveRobotName : demoName,
                    ipAddress: "192.168.4.1",
                    lastSeen: Date(),
                    isOnline: true
                )
            ]
        }

        return list
    }

    func renameRobot(_ robot: Robot, to rawName: String) {
        let cleanName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }

        UserDefaults.standard.set(cleanName, forKey: perRobotNameKey(for: robot.id))
        AuthService.shared.saveCustomRobotName(cleanName)

        if let index = robots.firstIndex(where: { $0.id == robot.id }) {
            robots[index].name = cleanName
            let updated = robots[index]
            if updated.id != Self.demoRobotID {
                Task {
                    do {
                        try await DatabaseService.shared.registerRobot(updated)
                    } catch {
                        print("Robot isim güncelleme hatası: \(error)")
                    }
                }
            }
        }
    }

    func loadRobots() async {
        loadTask?.cancel()

        let task = Task {
            isLoading = true
            errorMessage = nil

            do {
                let fetched = try await DatabaseService.shared.fetchRobots()
                guard !Task.isCancelled else { return }

                robots = applyUserRobotName(to: fetched)
                isLoading = false
            } catch is CancellationError {
                finishCancelledLoad()
            } catch let error as URLError where error.code == .cancelled {
                finishCancelledLoad()
            } catch {
                guard !Task.isCancelled else {
                    finishCancelledLoad()
                    return
                }

                if UserDefaults.standard.bool(forKey: "isTestModeEnabled") {
                    robots = applyUserRobotName(to: [])
                    errorMessage = nil
                } else {
                    errorMessage = error.localizedDescription
                }
                isLoading = false
            }
        }

        loadTask = task
        await task.value
    }

    private func finishCancelledLoad() {
        isLoading = false
    }

    func addRobot(_ robot: Robot) {
        var added = robot
        let trimmed = added.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased().hasPrefix("gismo") {
            added.name = AuthService.shared.effectiveRobotName
        } else {
            AuthService.shared.saveCustomRobotName(trimmed)
        }

        if let index = robots.firstIndex(where: { $0.id == added.id }) {
            robots[index] = added
        } else {
            robots.append(added)
        }

        // Arka planda veritabanına kaydet
        Task {
            do {
                try await DatabaseService.shared.registerRobot(added)
            } catch {
                print("Robot kaydetme hatası: \(error)")
            }
        }
    }

    func deleteRobot(at offsets: IndexSet) {
        // Find which robots to delete
        let toDelete = offsets.map { robots[$0] }
        robots.remove(atOffsets: offsets)
        
        // Delete from backend
        Task {
            for robot in toDelete {
                do {
                    try await DatabaseService.shared.deleteRobot(id: robot.id)
                } catch {
                    print("Robot silme hatası: \(error)")
                }
            }
        }
    }

    func deleteRobot(_ robot: Robot) {
        guard let index = robots.firstIndex(where: { $0.id == robot.id }) else { return }
        let removedRobot = robots.remove(at: index)
        errorMessage = nil

        Task {
            do {
                try await DatabaseService.shared.deleteRobot(id: removedRobot.id)
            } catch {
                robots.insert(removedRobot, at: min(index, robots.count))
                errorMessage = error.localizedDescription
            }
        }
    }
}

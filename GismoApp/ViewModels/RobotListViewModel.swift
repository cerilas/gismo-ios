import Foundation

@MainActor
class RobotListViewModel: ObservableObject {
    @Published var robots: [Robot] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    private var loadTask: Task<Void, Never>?
    private var robotsObserver: NSObjectProtocol?

    init() {
        WebSocketService.shared.connect()
        robotsObserver = NotificationCenter.default.addObserver(
            forName: WebSocketService.robotsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let robots = notification.userInfo?["robots"] as? [Robot] else { return }
            Task { @MainActor in
                self?.robots = robots
            }
        }
    }

    deinit {
        if let robotsObserver {
            NotificationCenter.default.removeObserver(robotsObserver)
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

                robots = fetched
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

                errorMessage = error.localizedDescription
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
        if let index = robots.firstIndex(where: { $0.id == robot.id }) {
            robots[index] = robot
        } else {
            robots.append(robot)
        }

        // Arka planda veritabanına kaydet
        Task {
            do {
                try await DatabaseService.shared.registerRobot(robot)
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

import Foundation
import Combine

enum SetupStep: Int, CaseIterable {
    case connectToESP = 0
    case scanWiFi     = 1
    case enterPassword = 2
    case success      = 3
}

class SetupViewModel: ObservableObject {
    @Published var currentStep: SetupStep = .connectToESP
    @Published var networks: [WiFiNetwork] = []
    @Published var selectedNetwork: WiFiNetwork?
    @Published var password: String = ""
    @Published var isScanning = false
    @Published var isConnecting = false
    @Published var errorMessage: String?
    @Published var connectionStatusMessage: String?
    @Published var robotName: String = "Gismo-\(Int.random(in: 10...99))"
    let robotID = UUID()
    private let savedWiFiPasswordsKey = "savedWiFiPasswords"
    private let robotOnlineTimeout: TimeInterval = 45
    private let robotOnlinePollInterval: UInt64 = 2_000_000_000
    private var connectedRobot: Robot?

    // MARK: - Step Navigation

    func goToNextStep() {
        guard let next = SetupStep(rawValue: currentStep.rawValue + 1) else { return }
        currentStep = next
    }

    func goToPreviousStep() {
        guard currentStep.rawValue > 0,
              let prev = SetupStep(rawValue: currentStep.rawValue - 1) else { return }
        currentStep = prev
    }

    // MARK: - Scan Networks

    func scanNetworks() {
        isScanning = true
        errorMessage = nil
        networks = []

        Task {
            do {
                let fetchedNetworks = try await ESPService.shared.scanNetworks()
                await MainActor.run {
                    self.networks = fetchedNetworks
                    self.isScanning = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isScanning = false
                }
            }
        }
    }

    func selectNetwork(_ network: WiFiNetwork) {
        selectedNetwork = network
        password = savedPassword(for: network.ssid) ?? ""
        goToNextStep()
    }

    // MARK: - Connect Robot to Network

    func connectRobot() {
        guard let network = selectedNetwork else { return }
        isConnecting = true
        errorMessage = nil
        connectionStatusMessage = "WiFi bilgileri robota gönderiliyor..."

        Task {
            do {
                try await ESPService.shared.connectToNetwork(
                    ssid: network.ssid,
                    password: password,
                    robotID: robotID,
                    robotName: robotName
                )
                await MainActor.run {
                    self.connectionStatusMessage = "Robotun sunucuya canlı bağlanması bekleniyor..."
                }
                let onlineRobot = try await registerAndWaitForRobotToComeOnline(buildRobot())

                await MainActor.run {
                    self.connectedRobot = onlineRobot
                    self.savePassword(self.password, for: network.ssid)
                    self.connectionStatusMessage = nil
                    self.isConnecting = false
                    self.goToNextStep() // → .success
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.connectionStatusMessage = nil
                    self.isConnecting = false
                }
            }
        }
    }

    func buildRobot() -> Robot {
        if let connectedRobot {
            return connectedRobot
        }

        return Robot(id: robotID, name: robotName, ipAddress: selectedNetwork?.ssid ?? "", isOnline: false)
    }

    // MARK: - Developer Bypass
    func skipSetupForTesting() {
        self.selectedNetwork = WiFiNetwork(ssid: "Test_Agi", rssi: -50, isSecured: true)
        self.password = "12345"
        self.currentStep = .success
    }

    private func savedPassword(for ssid: String) -> String? {
        let passwords = UserDefaults.standard.dictionary(forKey: savedWiFiPasswordsKey) as? [String: String]
        return passwords?[ssid]
    }

    private func savePassword(_ password: String, for ssid: String) {
        guard !password.isEmpty else { return }
        var passwords = UserDefaults.standard.dictionary(forKey: savedWiFiPasswordsKey) as? [String: String] ?? [:]
        passwords[ssid] = password
        UserDefaults.standard.set(passwords, forKey: savedWiFiPasswordsKey)
    }

    private func registerAndWaitForRobotToComeOnline(_ robotToRegister: Robot) async throws -> Robot {
        let deadline = Date().addingTimeInterval(robotOnlineTimeout)
        var lastError: Error?
        var didRegisterRobot = false

        while Date() < deadline {
            do {
                if !didRegisterRobot {
                    try await DatabaseService.shared.registerRobot(robotToRegister)
                    didRegisterRobot = true
                }

                let robots = try await DatabaseService.shared.fetchRobots()
                if let robot = robots.first(where: { $0.id == robotToRegister.id }), robot.isOnline {
                    return robot
                }
            } catch {
                lastError = error
            }

            try await Task.sleep(nanoseconds: robotOnlinePollInterval)
        }

        if !didRegisterRobot, let lastError {
            throw lastError
        }

        throw SetupError.robotDidNotComeOnline
    }
}

enum SetupError: LocalizedError {
    case robotDidNotComeOnline

    var errorDescription: String? {
        switch self {
        case .robotDidNotComeOnline:
            return "Robot WiFi bilgilerini aldı ancak sunucuya canlı bağlantı sinyali gelmedi. ESP32 seri monitöründe WebSocket bağlantısını kontrol edin."
        }
    }
}

import Foundation

// MARK: - WiFi Network Model

struct WiFiNetwork: Identifiable, Hashable {
    var id: String { ssid }
    let ssid: String
    let rssi: Int          // signal strength (dBm, e.g. -45)
    let isSecured: Bool

    var signalStrength: SignalStrength {
        switch rssi {
        case (-50)...:        return .excellent
        case (-65)..<(-50):   return .good
        case (-75)..<(-65):   return .fair
        default:              return .weak
        }
    }

    var signalIcon: String {
        switch signalStrength {
        case .excellent: return "wifi"
        case .good:      return "wifi"
        case .fair:      return "wifi.exclamationmark"
        case .weak:      return "wifi.slash"
        }
    }

    var signalBars: Int {
        switch signalStrength {
        case .excellent: return 3
        case .good:      return 3
        case .fair:      return 2
        case .weak:      return 1
        }
    }
}

enum SignalStrength {
    case excellent, good, fair, weak
}

// MARK: - Mock Data

extension WiFiNetwork {
    static let mockNetworks: [WiFiNetwork] = [
        WiFiNetwork(ssid: "HomeNetwork",      rssi: -45, isSecured: true),
        WiFiNetwork(ssid: "OfficeWiFi",       rssi: -58, isSecured: true),
        WiFiNetwork(ssid: "CaféGuest",        rssi: -70, isSecured: false),
        WiFiNetwork(ssid: "Neighbors_5G",     rssi: -75, isSecured: true),
        WiFiNetwork(ssid: "AndroidHotspot",   rssi: -80, isSecured: true),
        WiFiNetwork(ssid: "PublicNetwork",    rssi: -88, isSecured: false),
    ]
}

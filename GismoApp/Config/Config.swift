import Foundation

/// Centralized app configuration.
/// After Railway deploys your backend, replace BASE_URL with your Railway domain.
/// Example: "https://gismo-app-backend-production.up.railway.app"
enum Config {

    // MARK: - API

    /// Your Railway backend URL (no trailing slash)
    static let baseURL = "https://gismo-app-backend-production.up.railway.app"

    /// API key — must match the API_KEY env var set in Railway dashboard
    static let apiKey  = "24232423"

    // MARK: - ESP32 Local AP

    /// Default ESP32 access point gateway
    static let espBaseURL = "http://192.168.4.1"

    // MARK: - Timeouts

    static let requestTimeout: TimeInterval = 8
    static let commandThrottle: TimeInterval = 0.08  // min seconds between commands
}

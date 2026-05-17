import SwiftUI

// MARK: - Color Palette

extension Color {
    static let gBg         = Color(hex: "0A0A0F")
    static let gSurface    = Color(hex: "1C1C2E")
    static let gSurface2   = Color(hex: "252540")
    static let gBorder     = Color(hex: "FFFFFF").opacity(0.08)
    static let gAccent     = Color(hex: "7B61FF")
    static let gAccent2    = Color(hex: "5B8FF9")
    static let gSuccess    = Color(hex: "00D4AA")
    static let gDanger     = Color(hex: "FF4560")
    static let gWarning    = Color(hex: "FFB800")
    static let gSubtext    = Color(hex: "8E8EA8")

    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:  (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:  (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:  (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB,
                  red: Double(r) / 255,
                  green: Double(g) / 255,
                  blue: Double(b) / 255,
                  opacity: Double(a) / 255)
    }
}

// MARK: - Gradients

struct AccentGradient: View {
    var startPoint: UnitPoint = .topLeading
    var endPoint: UnitPoint = .bottomTrailing
    var body: some View {
        LinearGradient(colors: [.gAccent, .gAccent2],
                       startPoint: startPoint, endPoint: endPoint)
    }
}

extension LinearGradient {
    static var accent: LinearGradient {
        LinearGradient(colors: [.gAccent, .gAccent2],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var successGradient: LinearGradient {
        LinearGradient(colors: [Color(hex: "00D4AA"), Color(hex: "00A878")],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var dangerGradient: LinearGradient {
        LinearGradient(colors: [Color(hex: "FF4560"), Color(hex: "CC1830")],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Glass Card Modifier

struct GlassCard: ViewModifier {
    var padding: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.gSurface.opacity(0.85))
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.gBorder, lineWidth: 1)
                }
            )
    }
}

extension View {
    func glassCard(padding: CGFloat = 20) -> some View {
        self.modifier(GlassCard(padding: padding))
    }
}

// MARK: - Gismo Primary Button

struct GismoPrimaryButton: View {
    let title: String
    let icon: String?
    let action: () -> Void
    var isLoading: Bool = false
    var isDisabled: Bool = false

    init(_ title: String, icon: String? = nil, isLoading: Bool = false, isDisabled: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
        self.isLoading = isLoading
        self.isDisabled = isDisabled
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.9)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                Group {
                    if isDisabled {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.gSubtext.opacity(0.3))
                    } else {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(LinearGradient.accent)
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
        }
        .disabled(isDisabled || isLoading)
        .buttonStyle(ScaleButtonStyle())
    }
}

// MARK: - Scale Button Style

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    let isOnline: Bool

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                if isOnline {
                    Circle()
                        .stroke(Color.gSuccess.opacity(0.3), lineWidth: 2)
                        .frame(width: 14, height: 14)
                        .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: isOnline)
                }

                Circle()
                    .fill(isOnline ? Color.gSuccess : Color.gSubtext)
                    .frame(width: 7, height: 7)
            }
            .frame(width: 14, height: 14)

            Text(isOnline ? "Çevrimiçi" : "Çevrimdışı")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isOnline ? .gSuccess : .gSubtext)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(isOnline ? Color.gSuccess.opacity(0.12) : Color.gSubtext.opacity(0.1))
        )
    }
}

// MARK: - Background View

struct GismoBackground: View {
    var body: some View {
        ZStack {
            Color.gBg.ignoresSafeArea()
            // Subtle radial glow
            RadialGradient(
                colors: [Color.gAccent.opacity(0.12), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 400
            )
            .ignoresSafeArea()
        }
    }
}

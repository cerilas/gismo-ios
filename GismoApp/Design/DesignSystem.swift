import SwiftUI

// MARK: - Color Palette

extension Color {
    static let gBg         = Color(hex: "07080E")
    static let gSurface    = Color(hex: "141625")
    static let gSurface2   = Color(hex: "1E2238")
    static let gBorder     = Color(hex: "FFFFFF").opacity(0.10)
    static let gAccent     = Color(hex: "7B61FF")
    static let gAccent2    = Color(hex: "38BDF8")
    static let gCyan       = Color(hex: "00F0FF")
    static let gSuccess    = Color(hex: "00E5B0")
    static let gDanger     = Color(hex: "FF4769")
    static let gWarning    = Color(hex: "FFB800")
    static let gSubtext    = Color(hex: "9499B8")

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
    static var cyberCyan: LinearGradient {
        LinearGradient(colors: [.gAccent2, .gSuccess],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var successGradient: LinearGradient {
        LinearGradient(colors: [Color(hex: "00E5B0"), Color(hex: "00A884")],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var dangerGradient: LinearGradient {
        LinearGradient(colors: [Color(hex: "FF4769"), Color(hex: "CC1838")],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var glassBorder: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(0.20),
                Color.white.opacity(0.06),
                Color.gAccent2.opacity(0.12)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Glass Card Modifier

struct GlassCard: ViewModifier {
    var padding: CGFloat = 20
    var cornerRadius: CGFloat = 22

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.gSurface2.opacity(0.75),
                                    Color.gSurface.opacity(0.92)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(LinearGradient.glassBorder, lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(0.32), radius: 18, x: 0, y: 10)
            )
    }
}

extension View {
    func glassCard(padding: CGFloat = 20, cornerRadius: CGFloat = 22) -> some View {
        self.modifier(GlassCard(padding: padding, cornerRadius: cornerRadius))
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
                        .font(.system(size: 16, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .tracking(0.3)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                Group {
                    if isDisabled {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.gSurface2.opacity(0.6))
                    } else {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(LinearGradient.accent)
                            .shadow(color: Color.gAccent.opacity(0.38), radius: 16, x: 0, y: 8)
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(isDisabled ? 0.06 : 0.28), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
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
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.78), value: configuration.isPressed)
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    let isOnline: Bool
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                if isOnline {
                    Circle()
                        .stroke(Color.gSuccess.opacity(0.45), lineWidth: 1.5)
                        .frame(width: 14, height: 14)
                        .scaleEffect(pulse ? 1.25 : 0.85)
                        .opacity(pulse ? 0.0 : 0.9)
                }

                Circle()
                    .fill(isOnline ? Color.gSuccess : Color.gSubtext.opacity(0.6))
                    .frame(width: 7, height: 7)
                    .shadow(color: isOnline ? Color.gSuccess.opacity(0.8) : .clear, radius: 4)
            }
            .frame(width: 14, height: 14)

            Text(isOnline ? "Çevrimiçi" : "Çevrimdışı")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(0.3)
                .foregroundColor(isOnline ? .gSuccess : .gSubtext)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(isOnline ? Color.gSuccess.opacity(0.12) : Color.white.opacity(0.05))
                .overlay(
                    Capsule()
                        .stroke(isOnline ? Color.gSuccess.opacity(0.28) : Color.white.opacity(0.08), lineWidth: 1)
                )
        )
        .onAppear {
            guard isOnline else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

// MARK: - Futuristic Ambient Background View

struct GismoBackground: View {
    var body: some View {
        ZStack {
            Color.gBg.ignoresSafeArea()

            // Top-left electric violet nebula
            RadialGradient(
                colors: [Color.gAccent.opacity(0.18), Color.gAccent.opacity(0.04), .clear],
                center: .topLeading,
                startRadius: 10,
                endRadius: 460
            )
            .ignoresSafeArea()

            // Bottom-right cyber cyan glow
            RadialGradient(
                colors: [Color.gAccent2.opacity(0.14), Color.gSuccess.opacity(0.03), .clear],
                center: .bottomTrailing,
                startRadius: 20,
                endRadius: 480
            )
            .ignoresSafeArea()

            // Subtle cyber-grid dot matrix
            Canvas { context, size in
                let spacing: CGFloat = 28
                let dotSize: CGFloat = 1.4
                let cols = Int(size.width / spacing) + 1
                let rows = Int(size.height / spacing) + 1

                for r in 0..<rows {
                    for c in 0..<cols {
                        let x = CGFloat(c) * spacing
                        let y = CGFloat(r) * spacing
                        let rect = CGRect(x: x, y: y, width: dotSize, height: dotSize)
                        context.fill(Path(ellipseIn: rect), with: .color(Color.white.opacity(0.045)))
                    }
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }
}

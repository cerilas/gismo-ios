import SwiftUI

struct SplashView: View {
    @State private var logoScale: CGFloat = 0.65
    @State private var logoOpacity: Double = 0
    @State private var glowRadius: CGFloat = 8
    @State private var textOpacity: Double = 0
    @State private var ringScale: CGFloat = 0.55
    @State private var ringOpacity: Double = 0
    @State private var orbitRotation: Double = 0
    @State private var eyeBlink: Bool = false
    @State private var bootProgress: CGFloat = 0.08

    var body: some View {
        ZStack {
            GismoBackground()

            // Center ambient core halo
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.gAccent.opacity(0.26), Color.gAccent2.opacity(0.10), .clear],
                        center: .center,
                        startRadius: 10,
                        endRadius: 210
                    )
                )
                .frame(width: 420, height: 420)
                .scaleEffect(ringScale)
                .opacity(ringOpacity)

            // Outer dashed telemetry orbit ring
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [Color.gAccent2.opacity(0.35), Color.gAccent.opacity(0.08), Color.gSuccess.opacity(0.30)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: 1.2, dash: [6, 10])
                )
                .frame(width: 268, height: 268)
                .rotationEffect(.degrees(orbitRotation))
                .scaleEffect(ringScale)
                .opacity(ringOpacity * 0.85)

            // Inner glowing arc ring
            Circle()
                .trim(from: 0.08, to: 0.82)
                .stroke(
                    LinearGradient.accent,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .frame(width: 204, height: 204)
                .rotationEffect(.degrees(-orbitRotation * 1.3))
                .scaleEffect(ringScale)
                .opacity(ringOpacity)

            VStack(spacing: 32) {
                Spacer()

                // Futuristic Gismo Core Emblem
                ZStack {
                    // Pulsing neon aura
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.gAccent.opacity(0.45), Color.gAccent2.opacity(0.35)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 138, height: 138)
                        .blur(radius: glowRadius)

                    // Glassmorphic chassis
                    RoundedRectangle(cornerRadius: 38, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.gSurface2, Color(hex: "0C0E1A")],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 126, height: 126)
                        .overlay(
                            RoundedRectangle(cornerRadius: 38, style: .continuous)
                                .stroke(
                                    LinearGradient(
                                        colors: [Color.gAccent2.opacity(0.9), Color.gAccent.opacity(0.6), Color.white.opacity(0.15)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1.8
                                )
                        )
                        .shadow(color: Color.gAccent.opacity(0.35), radius: 24, x: 0, y: 12)

                    // Gismo Cyber Visor & Eyes
                    VStack(spacing: 12) {
                        HStack(spacing: 18) {
                            gismoEyeCapsule
                            gismoEyeCapsule
                        }

                        // Subtle happy cyber-mouth arc
                        Capsule()
                            .fill(LinearGradient.cyberCyan)
                            .frame(width: 26, height: 4)
                            .shadow(color: Color.gCyan.opacity(0.8), radius: 6)
                    }
                }
                .scaleEffect(logoScale)
                .opacity(logoOpacity)

                // Brand Typography & OS Tag
                VStack(spacing: 12) {
                    Text("GISMO")
                        .font(.system(size: 42, weight: .black, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.white, Color.gAccent2, Color.gAccent],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .tracking(10)
                        .shadow(color: Color.gAccent.opacity(0.35), radius: 14, x: 0, y: 4)

                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.gSuccess)
                            .frame(width: 6, height: 6)
                            .shadow(color: Color.gSuccess, radius: 4)

                        Text("AUTONOMOUS COMPANION OS")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.gSubtext)
                            .tracking(2.2)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.05))
                            .overlay(
                                Capsule()
                                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
                            )
                    )
                }
                .opacity(textOpacity)

                Spacer()

                // Bottom Telemetry Boot Progress
                VStack(spacing: 10) {
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                            .frame(width: 190, height: 5)

                        Capsule()
                            .fill(LinearGradient.cyberCyan)
                            .frame(width: 190 * bootProgress, height: 5)
                            .shadow(color: Color.gAccent2.opacity(0.8), radius: 6)
                    }

                    Text("NÖRAL SES VE GÖRÜŞ SİSTEMLERİ HAZIRLANIYOR")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.gSubtext.opacity(0.75))
                        .tracking(1.4)
                }
                .opacity(textOpacity)
                .padding(.bottom, 48)
            }
        }
        .onAppear { animate() }
    }

    private var gismoEyeCapsule: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color.gCyan, Color.gAccent2],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 24, height: eyeBlink ? 3 : 30)
            .shadow(color: Color.gCyan.opacity(0.85), radius: 8)
            .overlay(
                Circle()
                    .fill(Color.white.opacity(eyeBlink ? 0 : 0.85))
                    .frame(width: 6, height: 6)
                    .offset(x: -4, y: -6)
            )
    }

    private func animate() {
        withAnimation(.spring(response: 0.65, dampingFraction: 0.68).delay(0.08)) {
            logoScale = 1.0
            logoOpacity = 1.0
        }
        withAnimation(.easeOut(duration: 0.9).delay(0.2)) {
            glowRadius = 32
        }
        withAnimation(.easeOut(duration: 0.7).delay(0.28)) {
            textOpacity = 1.0
        }
        withAnimation(.spring(response: 1.1, dampingFraction: 0.75).delay(0.18)) {
            ringScale = 1.0
            ringOpacity = 1.0
        }
        withAnimation(.linear(duration: 14).repeatForever(autoreverses: false)) {
            orbitRotation = 360
        }
        withAnimation(.easeInOut(duration: 2.1).delay(0.2)) {
            bootProgress = 1.0
        }
        // Friendly double blink during splash
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) {
            withAnimation(.easeInOut(duration: 0.10)) { eyeBlink = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
                withAnimation(.easeInOut(duration: 0.12)) { eyeBlink = false }
            }
        }
    }
}

#Preview {
    SplashView()
}

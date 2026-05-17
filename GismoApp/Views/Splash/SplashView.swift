import SwiftUI

struct SplashView: View {
    @State private var logoScale: CGFloat = 0.6
    @State private var logoOpacity: Double = 0
    @State private var glowRadius: CGFloat = 0
    @State private var textOpacity: Double = 0
    @State private var ringScale: CGFloat = 0.5
    @State private var ringOpacity: Double = 0

    var body: some View {
        ZStack {
            GismoBackground()

            // Outer glow ring
            Circle()
                .stroke(
                    LinearGradient.accent.opacity(0.3),
                    lineWidth: 1.5
                )
                .frame(width: 180, height: 180)
                .scaleEffect(ringScale)
                .opacity(ringOpacity)

            Circle()
                .stroke(
                    LinearGradient.accent.opacity(0.15),
                    lineWidth: 1
                )
                .frame(width: 230, height: 230)
                .scaleEffect(ringScale * 0.9)
                .opacity(ringOpacity * 0.7)

            VStack(spacing: 24) {
                // Logo
                ZStack {
                    // Glow
                    Circle()
                        .fill(Color.gAccent.opacity(0.25))
                        .frame(width: 120, height: 120)
                        .blur(radius: glowRadius)

                    // Logo container
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.gSurface2, Color.gSurface],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 110, height: 110)
                        .overlay(
                            Circle()
                                .stroke(LinearGradient.accent, lineWidth: 1.5)
                        )

                    // Robot icon
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(LinearGradient.accent)
                }
                .scaleEffect(logoScale)
                .opacity(logoOpacity)

                // App name
                VStack(spacing: 6) {
                    Text("GISMO")
                        .font(.system(size: 38, weight: .black, design: .rounded))
                        .foregroundStyle(LinearGradient.accent)
                        .tracking(8)

                    Text("Robot Controller")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.gSubtext)
                        .tracking(2)
                }
                .opacity(textOpacity)
            }
        }
        .onAppear { animate() }
    }

    private func animate() {
        withAnimation(.spring(response: 0.7, dampingFraction: 0.65).delay(0.1)) {
            logoScale = 1.0
            logoOpacity = 1.0
        }
        withAnimation(.easeOut(duration: 0.8).delay(0.3)) {
            glowRadius = 30
        }
        withAnimation(.easeOut(duration: 0.8).delay(0.4)) {
            textOpacity = 1.0
        }
        withAnimation(.spring(response: 1.2, dampingFraction: 0.7).delay(0.5)) {
            ringScale = 1.0
            ringOpacity = 1.0
        }
    }
}

#Preview {
    SplashView()
}

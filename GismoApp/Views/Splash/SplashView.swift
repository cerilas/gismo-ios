import SwiftUI

struct SplashView: View {
    @State private var appeared = false
    @State private var isBlinking = true
    @State private var isSmiling = false
    @State private var floatPhase = false
    @State private var lookOffset: CGSize = .zero
    @State private var auraPulse = false

    private let primaryColor   = Color(hex: "00D4AA")
    private let secondaryColor = Color(hex: "72DDF7")

    var body: some View {
        GeometryReader { geometry in
            let baseSize  = min(geometry.size.width, geometry.size.height) * 0.85
            let eyeWidth  = baseSize * 0.34
            let eyeHeight = baseSize * (isSmiling ? 0.21 : 0.25)
            let eyeSpace  = baseSize * 0.13

            ZStack {
                // Saf karanlık robot yüzü arka planı + yumuşak duygu parıltısı
                LinearGradient(
                    colors: [
                        Color(hex: "05050A"),
                        (isSmiling ? primaryColor : secondaryColor).opacity(0.18),
                        Color(hex: "080812")
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                RadialGradient(
                    colors: [
                        (isSmiling ? primaryColor : secondaryColor).opacity(0.32),
                        .clear
                    ],
                    center: .center,
                    startRadius: baseSize * 0.06,
                    endRadius: baseSize * 0.78
                )
                .scaleEffect(auraPulse ? 1.08 : 0.94)
                .ignoresSafeArea()

                // Yalnızca Gismo'nun Animasyonlu Yüzü (Gözler + Ağız)
                VStack(spacing: baseSize * 0.08) {
                    // Gözler
                    HStack(spacing: eyeSpace) {
                        splashEye(width: eyeWidth, height: eyeHeight)
                        splashEye(width: eyeWidth, height: eyeHeight)
                    }
                    .offset(x: lookOffset.width, y: lookOffset.height + (floatPhase ? -6 : 4))

                    // Ağız (Nötr kapsülden mutlu gülümsemeye geçiş)
                    ZStack {
                        if isSmiling {
                            SplashSmileShape(depth: baseSize * 0.11)
                                .stroke(
                                    LinearGradient(
                                        colors: [primaryColor, secondaryColor],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ),
                                    style: StrokeStyle(lineWidth: max(8, baseSize * 0.024), lineCap: .round)
                                )
                                .frame(width: baseSize * 0.28, height: baseSize * 0.14)
                                .shadow(color: primaryColor.opacity(0.75), radius: 14)
                                .transition(.scale(scale: 0.8).combined(with: .opacity))
                        } else {
                            Capsule()
                                .fill(secondaryColor.opacity(0.78))
                                .frame(width: baseSize * 0.20, height: max(7, baseSize * 0.020))
                                .shadow(color: secondaryColor.opacity(0.6), radius: 10)
                                .transition(.opacity)
                        }
                    }
                    .offset(x: lookOffset.width * 0.4, y: floatPhase ? -4 : 3)
                }
                .scaleEffect(appeared ? 1.0 : 0.82)
                .opacity(appeared ? 1.0 : 0.0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .statusBarHidden(true)
        .onAppear {
            runFaceIntroAnimation()
        }
    }

    @ViewBuilder
    private func splashEye(width: CGFloat, height: CGFloat) -> some View {
        let currentPrimary   = isSmiling ? primaryColor : secondaryColor
        let currentSecondary = isSmiling ? Color(hex: "55E6C1") : Color(hex: "A7F3FF")
        let actualHeight     = isBlinking ? max(8, height * 0.08) : height

        RoundedRectangle(cornerRadius: actualHeight * 0.48, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [currentPrimary, currentSecondary],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: width, height: actualHeight)
            .shadow(color: currentPrimary.opacity(0.85), radius: 24, x: 0, y: 0)
            .overlay(alignment: .topLeading) {
                if !isBlinking {
                    Capsule()
                        .fill(Color.white.opacity(0.68))
                        .frame(width: width * 0.22, height: max(5, height * 0.13))
                        .offset(x: width * 0.18, y: height * 0.18)
                }
            }
    }

    private func runFaceIntroAnimation() {
        // 1. Yüz ekranda belirir ve gözlerini açar (uyanma)
        withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) {
            appeared = true
        }
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            floatPhase = true
            auraPulse = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.68)) {
                isBlinking = false
            }
        }

        // 2. Meraklı bir şekilde hafif sola ve sağa bakış
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.75)) {
                lookOffset = CGSize(width: -12, height: -4)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.75)) {
                lookOffset = CGSize(width: 10, height: -2)
            }
        }

        // 3. Merkeze dönüp çift göz kırpma ve mutlu gülümseme
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.30) {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                lookOffset = .zero
            }
            withAnimation(.easeInOut(duration: 0.07)) {
                isBlinking = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.68)) {
                    isBlinking = false
                    isSmiling = true
                }
            }
        }
    }
}

private struct SplashSmileShape: Shape {
    let depth: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY - depth * 0.15))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY - depth * 0.15),
            control: CGPoint(x: rect.midX, y: rect.midY + depth)
        )
        return path
    }
}

#Preview {
    SplashView()
}

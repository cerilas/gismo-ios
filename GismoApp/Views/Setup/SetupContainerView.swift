import SwiftUI

struct SetupContainerView: View {
    @StateObject private var viewModel = SetupViewModel()
    @Environment(\.dismiss) private var dismiss
    var onComplete: (Robot) -> Void

    var body: some View {
        ZStack {
            GismoBackground()

            VStack(spacing: 0) {
                // Top bar
                topBar

                // Step content
                Group {
                    switch viewModel.currentStep {
                    case .connectToESP:
                        Step1ConnectView(viewModel: viewModel)
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)
                            ))
                    case .scanWiFi:
                        Step2WiFiScanView(viewModel: viewModel)
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)
                            ))
                    case .enterPassword:
                        Step3PasswordView(viewModel: viewModel)
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)
                            ))
                    case .success:
                        SetupSuccessView(viewModel: viewModel) {
                            let robot = viewModel.buildRobot()
                            onComplete(robot)
                            dismiss()
                        }
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: viewModel.currentStep)
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 14) {
            // Close / Back
            Button {
                if viewModel.currentStep == .connectToESP {
                    dismiss()
                } else {
                    viewModel.goToPreviousStep()
                }
            } label: {
                Image(systemName: viewModel.currentStep == .connectToESP ? "xmark" : "chevron.left")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 42, height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.gSurface2)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color.gBorder, lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(ScaleButtonStyle())

            // Progress Stepper Pill
            HStack(spacing: 8) {
                ForEach(0..<3) { i in
                    let isActive = i <= viewModel.currentStep.rawValue && viewModel.currentStep != .success
                    Capsule()
                        .fill(isActive ? LinearGradient.cyberCyan : LinearGradient(colors: [Color.gSurface2, Color.gSurface2], startPoint: .leading, endPoint: .trailing))
                        .frame(width: isActive ? 28 : 10, height: 6)
                        .shadow(color: isActive ? Color.gAccent2.opacity(0.5) : .clear, radius: 4)
                        .animation(.spring(response: 0.3), value: viewModel.currentStep)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color.gSurface.opacity(0.8))
                    .overlay(Capsule().stroke(Color.gBorder, lineWidth: 1))
            )

            Spacer()

            Text("KURULUM SİHİRBAZI")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(1.2)
                .foregroundColor(.gSubtext)
        }
        .padding(.horizontal, 20)
        .padding(.top, 56)
        .padding(.bottom, 16)
    }
}

// MARK: - Success View

struct SetupSuccessView: View {
    let viewModel: SetupViewModel
    let onDone: () -> Void
    @State private var appeared = false
    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 36) {
            Spacer()

            ZStack {
                ForEach(0..<3) { i in
                    Circle()
                        .stroke(Color.gSuccess.opacity(0.22 - Double(i) * 0.06), lineWidth: 1.5)
                        .frame(width: CGFloat(140 + i * 52), height: CGFloat(140 + i * 52))
                        .scaleEffect(appeared ? pulseScale : 0.5)
                        .opacity(appeared ? 1 : 0)
                }

                Circle()
                    .fill(LinearGradient.successGradient)
                    .frame(width: 112, height: 112)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.35), lineWidth: 1.5)
                    )
                    .overlay(
                        Image(systemName: "checkmark")
                            .font(.system(size: 44, weight: .black))
                            .foregroundColor(.white)
                    )
                    .shadow(color: Color.gSuccess.opacity(0.45), radius: 24, x: 0, y: 10)
                    .scaleEffect(appeared ? 1 : 0.3)
                    .opacity(appeared ? 1 : 0)
            }

            VStack(spacing: 12) {
                Text("\(viewModel.robotName) Çevrimiçi!")
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundColor(.white)

                if let ssid = viewModel.selectedNetwork?.ssid {
                    Text("\(viewModel.robotName), \(ssid) ağına\nbaşarıyla bağlandı ve kullanıma hazır.")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.gSubtext)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                }
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 20)

            Spacer()

            GismoPrimaryButton("Kontrol Merkezine Geç", icon: "sparkles") {
                onDone()
            }
            .padding(.horizontal, 24)
            .opacity(appeared ? 1 : 0)
            .padding(.bottom, 50)
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.1)) {
                appeared = true
            }
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true).delay(0.8)) {
                pulseScale = 1.08
            }
        }
    }
}

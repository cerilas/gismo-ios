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
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: viewModel.currentStep)
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 16) {
            // Close / Back
            Button {
                if viewModel.currentStep == .connectToESP {
                    dismiss()
                } else {
                    viewModel.goToPreviousStep()
                }
            } label: {
                Image(systemName: viewModel.currentStep == .connectToESP ? "xmark" : "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.gSurface2))
            }

            // Progress dots
            HStack(spacing: 8) {
                ForEach(0..<3) { i in
                    let isActive = i <= viewModel.currentStep.rawValue && viewModel.currentStep != .success
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isActive ? Color.gAccent : Color.gSurface2)
                        .frame(width: isActive ? 24 : 8, height: 6)
                        .animation(.spring(response: 0.3), value: viewModel.currentStep)
                }
            }

            Spacer()

            Text("Robot Ekle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.gSubtext)
        }
        .padding(.horizontal, 20)
        .padding(.top, 60)
        .padding(.bottom, 20)
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
                        .stroke(Color.gSuccess.opacity(0.15 - Double(i) * 0.04), lineWidth: 1)
                        .frame(width: CGFloat(140 + i * 50), height: CGFloat(140 + i * 50))
                        .scaleEffect(appeared ? pulseScale : 0.5)
                        .opacity(appeared ? 1 : 0)
                }

                Circle()
                    .fill(LinearGradient.successGradient)
                    .frame(width: 110, height: 110)
                    .overlay(
                        Image(systemName: "checkmark")
                            .font(.system(size: 44, weight: .bold))
                            .foregroundColor(.white)
                    )
                    .scaleEffect(appeared ? 1 : 0.3)
                    .opacity(appeared ? 1 : 0)
            }

            VStack(spacing: 12) {
                Text("Robot Bağlandı! 🎉")
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundColor(.white)

                if let ssid = viewModel.selectedNetwork?.ssid {
                    Text("\(viewModel.robotName), \(ssid) ağına\nbaşarıyla bağlandı.")
                        .font(.system(size: 16))
                        .foregroundColor(.gSubtext)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                }
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 20)

            Spacer()

            GismoPrimaryButton("Kontrol Etmeye Başla", icon: "gamecontroller.fill") {
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

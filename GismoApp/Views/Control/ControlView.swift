import SwiftUI

struct ControlView: View {
    let robot: Robot
    @StateObject private var viewModel: ControlViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var headerAppeared = false
    @State private var joystickAppeared = false
    @State private var commandPulse = false
    @State private var showAPModeConfirmation = false
    @State private var showFaceMode = false
    @State private var showAIKeyGate = false

    init(robot: Robot) {
        self.robot = robot
        self._viewModel = StateObject(wrappedValue: ControlViewModel(robot: robot))
    }

    var body: some View {
        ZStack {
            GismoBackground()

            VStack(spacing: 0) {
                // Header
                controlHeader

                Spacer(minLength: 10)

                // Status & Command Display
                commandDisplay
                    .padding(.horizontal, 20)
                    .opacity(joystickAppeared ? 1 : 0)

                Spacer()

                // Joystick
                joystickSection

                Spacer()

                // Quick action buttons & Telemetry Log
                quickActions

                Spacer(minLength: 32)
            }
        }
        .fullScreenCover(isPresented: $showFaceMode) {
            GismoFaceView(robot: robot)
        }
        .sheet(isPresented: $showAIKeyGate) {
            AIKeySheet(isGate: true) { showFaceMode = true }
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.08)) {
                headerAppeared = true
            }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.72).delay(0.22)) {
                joystickAppeared = true
            }
        }
        .alert("AP Moduna Al?", isPresented: $showAPModeConfirmation) {
            Button("Vazgeç", role: .cancel) {}
            Button("AP Moduna Al", role: .destructive) {
                viewModel.resetRobotToAPMode()
            }
        } message: {
            Text("Robotun kayıtlı WiFi bilgileri silinecek ve yeniden başlatıldığında GISMO_AP ağı açılacak.")
        }
    }

    // MARK: - Header

    private var controlHeader: some View {
        HStack(spacing: 14) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
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

            VStack(alignment: .leading, spacing: 4) {
                Text(robot.name)
                    .font(.system(size: 20, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                StatusBadge(isOnline: viewModel.isConnected)
            }

            Spacer()

            // Quick switch to Gismo AI Face Mode
            Button {
                // Yüz modu yalnızca Yapay Zeka Anahtarı girilmişse açılır
                if AIKeyStore.hasKey { showFaceMode = true } else { showAIKeyGate = true }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .bold))
                    Text("Yüz Modu")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                }
                .foregroundColor(.black)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(LinearGradient.cyberCyan)
                        .shadow(color: Color.gSuccess.opacity(0.3), radius: 8, x: 0, y: 4)
                )
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.top, 56)
        .padding(.bottom, 12)
        .opacity(headerAppeared ? 1 : 0)
        .offset(y: headerAppeared ? 0 : -20)
    }

    // MARK: - Command Telemetry Display

    private var commandDisplay: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                // Current command card
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(viewModel.currentCommand == .stop ? Color.gSubtext : Color.gCyan)
                            .frame(width: 6, height: 6)
                        Text("AKTİF VEKTÖR")
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .foregroundColor(.gSubtext)
                            .tracking(1)
                    }

                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(
                                    viewModel.currentCommand == .stop
                                        ? Color.white.opacity(0.05)
                                        : Color.gAccent2.opacity(0.18)
                                )
                                .frame(width: 40, height: 40)

                            Image(systemName: viewModel.currentCommand.systemIcon)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(
                                    viewModel.currentCommand == .stop
                                        ? AnyShapeStyle(Color.gSubtext)
                                        : AnyShapeStyle(LinearGradient.cyberCyan)
                                )
                                .scaleEffect(commandPulse ? 1.18 : 1.0)
                                .animation(.spring(response: 0.2), value: commandPulse)
                        }

                        Text(viewModel.currentCommand.displayName)
                            .font(.system(size: 20, weight: .black, design: .rounded))
                            .foregroundColor(viewModel.currentCommand == .stop ? .gSubtext : .white)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(15)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.gSurface.opacity(0.9))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(
                                    viewModel.currentCommand == .stop
                                        ? Color.gBorder
                                        : Color.gCyan.opacity(0.45),
                                    lineWidth: 1.2
                                )
                        )
                )

                // Last command time card
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.gAccent2)
                        Text("SON SİNYAL")
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .foregroundColor(.gSubtext)
                            .tracking(1)
                    }

                    HStack {
                        if let t = viewModel.lastCommandTime {
                            Text(t, style: .relative)
                                .font(.system(size: 15, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                                .lineLimit(1)
                        } else {
                            Text("Bekleniyor...")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundColor(.gSubtext.opacity(0.7))
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: 40)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(15)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.gSurface.opacity(0.9))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(Color.gBorder, lineWidth: 1)
                        )
                )
            }

            if let errorMessage = viewModel.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                    Text(errorMessage)
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.gDanger)
                .padding(.top, 2)
            } else if let commandStatusMessage = viewModel.commandStatusMessage {
                Text(commandStatusMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.gSubtext)
            }
        }
        .onChange(of: viewModel.currentCommand) { _ in
            commandPulse = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { commandPulse = false }
        }
    }

    // MARK: - Joystick

    private var joystickSection: some View {
        VStack(spacing: 16) {
            JoystickView(command: $viewModel.currentCommand) { cmd in
                viewModel.sendCommand(cmd)
            }
            .scaleEffect(joystickAppeared ? 1 : 0.65)
            .opacity(joystickAppeared ? 1 : 0)

            HStack(spacing: 6) {
                Image(systemName: "hand.draw.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.gAccent2)
                Text("Analog çekirdeği sürükleyerek yönlendirin")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.gSubtext)
            }
            .opacity(joystickAppeared ? 1 : 0)
        }
    }

    // MARK: - Quick Actions & Command Log

    private var quickActions: some View {
        HStack(spacing: 12) {
            // Emergency Stop button
            Button {
                viewModel.stopRobot()
                let g = UIImpactFeedbackGenerator(style: .heavy)
                g.impactOccurred()
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "octagon.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                    Text("DURDUR")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(0.8)
                        .foregroundColor(.white)
                }
                .frame(width: 78, height: 74)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(LinearGradient.dangerGradient)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(Color.white.opacity(0.22), lineWidth: 1)
                        )
                        .shadow(color: Color.gDanger.opacity(0.35), radius: 12, x: 0, y: 6)
                )
            }
            .buttonStyle(ScaleButtonStyle())

            // AP Reset button
            Button {
                showAPModeConfirmation = true
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.black)
                    Text("AP MOD")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(0.8)
                        .foregroundColor(.black)
                }
                .frame(width: 78, height: 74)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.gWarning)
                        .shadow(color: Color.gWarning.opacity(0.28), radius: 12, x: 0, y: 6)
                )
            }
            .buttonStyle(ScaleButtonStyle())
            .disabled(!viewModel.isConnected)
            .opacity(viewModel.isConnected ? 1 : 0.45)

            // Command Log
            VStack(alignment: .leading, spacing: 8) {
                Text("KOMUT TELEMETRİSİ")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundColor(.gSubtext)
                    .tracking(1)

                if viewModel.commandLog.isEmpty {
                    Text("Henüz hareket komutu gönderilmedi")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.gSubtext.opacity(0.75))
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(viewModel.commandLog.prefix(8)) { entry in
                                Text(entry.command.rawValue)
                                    .font(.system(size: 12, weight: .black, design: .monospaced))
                                    .foregroundColor(.gCyan)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule()
                                            .fill(Color.gCyan.opacity(0.12))
                                            .overlay(
                                                Capsule()
                                                    .stroke(Color.gCyan.opacity(0.28), lineWidth: 1)
                                            )
                                    )
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 74)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.gSurface.opacity(0.9))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.gBorder, lineWidth: 1)
                    )
            )
        }
        .padding(.horizontal, 20)
        .opacity(joystickAppeared ? 1 : 0)
    }
}

#Preview {
    ControlView(robot: Robot(name: "Gismo", ipAddress: "192.168.1.42", isOnline: true))
}

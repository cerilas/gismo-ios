import SwiftUI

struct ControlView: View {
    let robot: Robot
    @StateObject private var viewModel: ControlViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var headerAppeared = false
    @State private var joystickAppeared = false
    @State private var commandPulse = false
    @State private var showAPModeConfirmation = false

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

                Spacer()

                // Status & Command Display
                commandDisplay
                    .padding(.horizontal, 24)
                    .opacity(joystickAppeared ? 1 : 0)

                Spacer()

                // Joystick
                joystickSection

                Spacer()

                // Quick action buttons
                quickActions

                Spacer(minLength: 40)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1)) {
                headerAppeared = true
            }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.3)) {
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
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.gSurface2))
            }
            .buttonStyle(ScaleButtonStyle())

            VStack(alignment: .leading, spacing: 2) {
                Text(robot.name)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                StatusBadge(isOnline: viewModel.isConnected)
            }

            Spacer()

            // Signal indicator
            VStack(spacing: 2) {
                Image(systemName: "wifi")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(LinearGradient.accent)
                Text("Internet")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.gSubtext)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 60)
        .padding(.bottom, 16)
        .opacity(headerAppeared ? 1 : 0)
        .offset(y: headerAppeared ? 0 : -20)
    }

    // MARK: - Command Display

    private var commandDisplay: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                // Current command
                VStack(spacing: 6) {
                    Text("Komut")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.gSubtext)
                        .tracking(1)

                    HStack(spacing: 8) {
                        Image(systemName: viewModel.currentCommand.systemIcon)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(
                                viewModel.currentCommand == .stop
                                    ? AnyShapeStyle(Color.gSubtext)
                                    : AnyShapeStyle(LinearGradient.accent)
                            )
                            .scaleEffect(commandPulse ? 1.15 : 1.0)
                            .animation(.spring(response: 0.2), value: commandPulse)

                        Text(viewModel.currentCommand.displayName)
                            .font(.system(size: 22, weight: .black, design: .rounded))
                            .foregroundColor(viewModel.currentCommand == .stop ? .gSubtext : .white)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.gSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(
                                    viewModel.currentCommand == .stop ? Color.gBorder : Color.gAccent.opacity(0.4),
                                    lineWidth: 1
                                )
                        )
                )

                Spacer().frame(width: 12)

                // Last command time
                VStack(spacing: 6) {
                    Text("Son Komut")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.gSubtext)
                        .tracking(1)

                    if let t = viewModel.lastCommandTime {
                        Text(t, style: .relative)
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                    } else {
                        Text("—")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.gSubtext)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.gSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.gBorder, lineWidth: 1)
                        )
                )
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.gDanger)
                    .multilineTextAlignment(.center)
            } else if let commandStatusMessage = viewModel.commandStatusMessage {
                Text(commandStatusMessage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.gSubtext)
                    .multilineTextAlignment(.center)
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
            .scaleEffect(joystickAppeared ? 1 : 0.6)
            .opacity(joystickAppeared ? 1 : 0)

            Text("Sürükle ve yönlendir")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.gSubtext)
                .opacity(joystickAppeared ? 1 : 0)
        }
    }

    // MARK: - Quick Actions

    private var quickActions: some View {
        HStack(spacing: 14) {
            // Stop button
            Button {
                viewModel.stopRobot()
                let g = UIImpactFeedbackGenerator(style: .heavy)
                g.impactOccurred()
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                    Text("STOP")
                        .font(.system(size: 11, weight: .black))
                        .tracking(1)
                        .foregroundColor(.white)
                }
                .frame(width: 80, height: 72)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(LinearGradient.dangerGradient)
                        .shadow(color: Color.gDanger.opacity(0.3), radius: 12)
                )
            }
            .buttonStyle(ScaleButtonStyle())

            Button {
                showAPModeConfirmation = true
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                    Text("AP")
                        .font(.system(size: 11, weight: .black))
                        .tracking(1)
                        .foregroundColor(.white)
                }
                .frame(width: 80, height: 72)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.gWarning)
                        .shadow(color: Color.gWarning.opacity(0.25), radius: 12)
                )
            }
            .buttonStyle(ScaleButtonStyle())
            .disabled(!viewModel.isConnected)
            .opacity(viewModel.isConnected ? 1 : 0.45)

            // Command Log
            VStack(alignment: .leading, spacing: 6) {
                Text("Komut Geçmişi")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.gSubtext)
                    .tracking(1)

                if viewModel.commandLog.isEmpty {
                    Text("Henüz komut yok")
                        .font(.system(size: 13))
                        .foregroundColor(.gSubtext)
                } else {
                    HStack(spacing: 6) {
                        ForEach(viewModel.commandLog.prefix(6)) { entry in
                            Text(entry.command.rawValue)
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundColor(.gAccent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(Color.gAccent.opacity(0.12))
                                )
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.gSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.gBorder, lineWidth: 1)
                    )
            )
        }
        .padding(.horizontal, 24)
        .opacity(joystickAppeared ? 1 : 0)
    }
}

#Preview {
    ControlView(robot: Robot.mockRobots[0])
}

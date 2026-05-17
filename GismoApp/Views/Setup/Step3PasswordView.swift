import SwiftUI

struct Step3PasswordView: View {
    @ObservedObject var viewModel: SetupViewModel
    @FocusState private var passwordFocused: Bool
    @State private var showPassword = false
    @State private var appeared = false
    @State private var shake = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 10) {
                Text("WiFi Şifresi")
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundColor(.white)

                if let network = viewModel.selectedNetwork {
                    HStack(spacing: 6) {
                        Image(systemName: "wifi")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.gAccent)
                        Text(network.ssid)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.gAccent)
                    }
                }

                Text("Seçtiğin ağın şifresini gir")
                    .font(.system(size: 15))
                    .foregroundColor(.gSubtext)
            }
            .padding(.top, 10)
            .padding(.bottom, 32)
            .opacity(appeared ? 1 : 0)

            // Selected network card
            if let network = viewModel.selectedNetwork {
                HStack(spacing: 12) {
                    Image(systemName: "wifi")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(LinearGradient.accent)
                    Text(network.ssid)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                    if network.isSecured {
                        Image(systemName: "lock.fill")
                            .foregroundColor(.gSubtext)
                    }
                }
                .glassCard(padding: 18)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
                .opacity(appeared ? 1 : 0)
            }

            // Robot Name Field
            VStack(alignment: .leading, spacing: 8) {
                Text("Robot Adı")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.gSubtext)
                    .padding(.leading, 4)

                HStack(spacing: 12) {
                    Image(systemName: "cpu")
                        .foregroundColor(.gSubtext)
                        .frame(width: 20)

                    TextField("", text: $viewModel.robotName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)
                        .tint(.gAccent)
                        .autocorrectionDisabled()
                }
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.gSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.gBorder, lineWidth: 1)
                        )
                )
            }
            .padding(.horizontal, 24)
            .opacity(appeared ? 1 : 0)

            Spacer().frame(height: 16)

            // Password Field
            VStack(alignment: .leading, spacing: 8) {
                Text("Şifre")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.gSubtext)
                    .padding(.leading, 4)

                HStack(spacing: 12) {
                    Image(systemName: "lock.fill")
                        .foregroundColor(.gSubtext)
                        .frame(width: 20)

                    Group {
                        if showPassword {
                            TextField("••••••••", text: $viewModel.password)
                        } else {
                            SecureField("••••••••", text: $viewModel.password)
                        }
                    }
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
                    .tint(.gAccent)
                    .focused($passwordFocused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .foregroundColor(.gSubtext)
                            .font(.system(size: 16))
                    }
                }
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.gSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(passwordFocused ? Color.gAccent.opacity(0.6) : Color.gBorder, lineWidth: 1)
                        )
                )
                .offset(x: shake ? -6 : 0)
                .animation(.default, value: shake)
            }
            .padding(.horizontal, 24)
            .opacity(appeared ? 1 : 0)

            Spacer()

            // Connect Button
            VStack(spacing: 12) {
                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundColor(.gDanger)
                        .multilineTextAlignment(.center)
                } else if let status = viewModel.connectionStatusMessage {
                    Text(status)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.gSubtext)
                        .multilineTextAlignment(.center)
                }

                GismoPrimaryButton(
                    "Robotu Bağla",
                    icon: "bolt.fill",
                    isLoading: viewModel.isConnecting,
                    isDisabled: viewModel.password.isEmpty && viewModel.selectedNetwork?.isSecured == true
                ) {
                    withAnimation { passwordFocused = false }
                    viewModel.connectRobot()
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 50)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.4)) { appeared = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                passwordFocused = true
            }
        }
    }
}

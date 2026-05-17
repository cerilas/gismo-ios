import SwiftUI

struct Step1ConnectView: View {
    @ObservedObject var viewModel: SetupViewModel
    @State private var appeared = false
    @State private var wifiIconBounce = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Illustration
            ZStack {
                // Animated rings
                ForEach(0..<3) { i in
                    Circle()
                        .stroke(
                            LinearGradient.accent.opacity(0.2 - Double(i) * 0.05),
                            lineWidth: 1.5
                        )
                        .frame(width: CGFloat(130 + i * 55), height: CGFloat(130 + i * 55))
                        .scaleEffect(wifiIconBounce ? 1 + CGFloat(i) * 0.03 : 1)
                        .animation(
                            .easeInOut(duration: 1.4 + Double(i) * 0.3)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.2),
                            value: wifiIconBounce
                        )
                }

                Circle()
                    .fill(Color.gSurface2)
                    .frame(width: 110, height: 110)
                    .overlay(
                        Circle()
                            .stroke(LinearGradient.accent, lineWidth: 1.5)
                    )
                    .overlay(
                        Image(systemName: "wifi")
                            .font(.system(size: 44, weight: .bold))
                            .foregroundStyle(LinearGradient.accent)
                    )
                    .scaleEffect(wifiIconBounce ? 1.04 : 1.0)
                    .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: wifiIconBounce)
            }
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.7)

            Spacer().frame(height: 40)

            // Title & Description
            VStack(spacing: 14) {
                Text("Robota Bağlan")
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundColor(.white)

                Text("Önce iPhone'unun WiFi ayarlarına gidip\nrobotun ağına (GISMO_AP) bağlanmanız gerekiyor.")
                    .font(.system(size: 16))
                    .foregroundColor(.gSubtext)
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 20)

            Spacer().frame(height: 36)

            // Steps
            VStack(spacing: 12) {
                instructionRow(number: "1", text: "iPhone Ayarlar → WiFi menüsüne git")
                instructionRow(number: "2", text: "\"GISMO_AP\" ağını seç ve bağlan")
                instructionRow(number: "3", text: "Bu uygulamaya geri dön")
            }
            .glassCard()
            .padding(.horizontal, 24)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 30)

            Spacer()

            // Buttons
            VStack(spacing: 12) {
                // Open WiFi Settings
                Button {
                    if let url = URL(string: "App-Prefs:root=WIFI") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "gear")
                            .font(.system(size: 16, weight: .semibold))
                        Text("WiFi Ayarlarını Aç")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundColor(.gAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.gAccent.opacity(0.12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color.gAccent.opacity(0.3), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(ScaleButtonStyle())

                GismoPrimaryButton("Bağlandım, Devam Et", icon: "checkmark.circle.fill") {
                    viewModel.goToNextStep()
                }

                // Geliştirici Bypass Butonu
                Button {
                    viewModel.skipSetupForTesting()
                } label: {
                    Text("Donanımı Atla (Sadece DB Testi)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.gSubtext.opacity(0.8))
                        .underline()
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 30)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.1)) {
                appeared = true
            }
            wifiIconBounce = true
        }
    }

    private func instructionRow(number: String, text: String) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(LinearGradient.accent)
                    .frame(width: 28, height: 28)
                Text(number)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
            }
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
            Spacer()
        }
    }
}

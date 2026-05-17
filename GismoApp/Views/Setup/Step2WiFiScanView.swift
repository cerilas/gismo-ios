import SwiftUI

struct Step2WiFiScanView: View {
    @ObservedObject var viewModel: SetupViewModel
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 10) {
                Text("WiFi Ağı Seç")
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundColor(.white)

                Text("Robotu bağlamak istediğin ağı seç")
                    .font(.system(size: 15))
                    .foregroundColor(.gSubtext)
            }
            .padding(.top, 10)
            .padding(.bottom, 24)
            .opacity(appeared ? 1 : 0)

            // Scan button / Loading
            if viewModel.isScanning {
                scanningIndicator
            } else if viewModel.networks.isEmpty {
                emptyOrInitial
            } else {
                networkList
            }

            Spacer()
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.4)) { appeared = true }
            if viewModel.networks.isEmpty {
                viewModel.scanNetworks()
            }
        }
    }

    // MARK: - Scanning Indicator

    private var scanningIndicator: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                ForEach(0..<3) { i in
                    Circle()
                        .stroke(Color.gAccent.opacity(0.3 - Double(i) * 0.08), lineWidth: 2)
                        .frame(width: CGFloat(70 + i * 45), height: CGFloat(70 + i * 45))
                        .scaleEffect(viewModel.isScanning ? 1.1 : 1.0)
                        .animation(
                            .easeInOut(duration: 1.0 + Double(i) * 0.3)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.25),
                            value: viewModel.isScanning
                        )
                }

                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .gAccent))
                    .scaleEffect(1.4)
            }

            Text("WiFi ağları taranıyor...")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.gSubtext)

            Spacer()
        }
    }

    // MARK: - Empty / Initial

    private var emptyOrInitial: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "wifi.slash")
                .font(.system(size: 44))
                .foregroundColor(.gSubtext)

            Text("Ağ bulunamadı")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)

            GismoPrimaryButton("Tekrar Tara", icon: "arrow.clockwise") {
                viewModel.scanNetworks()
            }
            .padding(.horizontal, 60)
            Spacer()
        }
    }

    // MARK: - Network List

    private var networkList: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 10) {
                // Refresh button
                HStack {
                    Text("\(viewModel.networks.count) ağ bulundu")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.gSubtext)
                    Spacer()
                    Button {
                        viewModel.scanNetworks()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Yenile")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundColor(.gAccent)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 4)

                ForEach(Array(viewModel.networks.enumerated()), id: \.element.id) { index, network in
                    WiFiNetworkRow(network: network)
                        .onTapGesture {
                            viewModel.selectNetwork(network)
                        }
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 15)
                        .animation(.spring(response: 0.4).delay(Double(index) * 0.05), value: appeared)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
    }
}

// MARK: - WiFi Network Row

struct WiFiNetworkRow: View {
    let network: WiFiNetwork
    @State private var pressed = false

    var body: some View {
        HStack(spacing: 14) {
            // Signal Icon
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.gSurface2)
                    .frame(width: 46, height: 46)

                signalBarsView(bars: network.signalBars)
            }

            // Name
            VStack(alignment: .leading, spacing: 3) {
                Text(network.ssid)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)

                HStack(spacing: 6) {
                    if network.isSecured {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.gSubtext)
                        Text("Şifreli")
                            .font(.system(size: 12))
                            .foregroundColor(.gSubtext)
                    } else {
                        Image(systemName: "lock.open.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.gSuccess)
                        Text("Açık")
                            .font(.system(size: 12))
                            .foregroundColor(.gSuccess)
                    }
                    Text("•")
                        .foregroundColor(.gSubtext)
                        .font(.system(size: 10))
                    Text("\(network.rssi) dBm")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.gSubtext)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.gSubtext)
        }
        .glassCard(padding: 14)
        .scaleEffect(pressed ? 0.97 : 1.0)
        .animation(.spring(response: 0.2), value: pressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
    }

    @ViewBuilder
    private func signalBarsView(bars: Int) -> some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(1...3, id: \.self) { bar in
                RoundedRectangle(cornerRadius: 2)
                    .fill(bar <= bars ? Color.gAccent : Color.gSubtext.opacity(0.3))
                    .frame(width: 5, height: CGFloat(bar * 6))
            }
        }
    }
}

import SwiftUI

// MARK: - Telefon (Varsayılan) Entegrasyon Kartı
// Entegrasyonlar ekranında: iPhone'un kendi yetenekleri (izin durumu + aç/kapat)

struct PhoneIntegrationsCard: View {
    @ObservedObject private var service = PhoneIntegrationService.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var isExpanded = true
    @State private var isRequestingAll = false
    @State private var showLimits = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(PhoneCapability.allCases) { cap in
                        row(cap)
                        if cap != PhoneCapability.allCases.last {
                            Divider().background(Color.white.opacity(0.06)).padding(.leading, 52)
                        }
                    }
                }
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.black.opacity(0.22))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
                )

                limitsNote
            }
        }
        .glassCard(padding: 18, cornerRadius: 24)
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(service.activeCount > 0 ? Color.gSuccess.opacity(0.45) : Color.clear, lineWidth: 1.2)
        )
        .onAppear { service.refreshStates() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { service.refreshStates() }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 15) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.25, green: 0.85, blue: 0.45), Color(red: 0.10, green: 0.60, blue: 0.95)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 54, height: 54)
                        .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("Telefon")
                            .font(.system(size: 18, weight: .black, design: .rounded))
                            .foregroundColor(.white)
                        Text("VARSAYILAN")
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                            .tracking(1)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Capsule().fill(Color.gCyan.opacity(0.18)))
                            .foregroundColor(.gCyan)
                    }
                    HStack(spacing: 6) {
                        Circle()
                            .fill(service.activeCount > 0 ? Color.gSuccess : Color.gSubtext)
                            .frame(width: 7, height: 7)
                        Text("\(service.activeCount)/\(PhoneCapability.allCases.count) yetenek aktif")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(service.activeCount > 0 ? .gSuccess : .gSubtext)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.white.opacity(0.06)))
                }
                .buttonStyle(ScaleButtonStyle())
            }

            Text("Robotun; kameran, rehberin, takvimin, alarmların, sağlık ve aktivite verilerin, konumun ve telefonunla ilgili soruları yanıtlayabilir ve senin için işlem yapabilir.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(.gSubtext)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            if hasPendingPermissions {
                Button {
                    requestAll()
                } label: {
                    HStack(spacing: 6) {
                        if isRequestingAll {
                            ProgressView().tint(.white).scaleEffect(0.8)
                        } else {
                            Image(systemName: "checkmark.shield.fill").font(.system(size: 13, weight: .bold))
                        }
                        Text("Tüm İzinleri Ver")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(LinearGradient.accent))
                    .foregroundColor(.white)
                    .shadow(color: Color.gAccent.opacity(0.35), radius: 8, x: 0, y: 4)
                }
                .buttonStyle(ScaleButtonStyle())
                .disabled(isRequestingAll)
            }
        }
    }

    private var hasPendingPermissions: Bool {
        PhoneCapability.allCases.contains { service.isEnabled($0) && service.states[$0] == .notDetermined }
    }

    // MARK: Row

    private func row(_ cap: PhoneCapability) -> some View {
        let enabled = service.isEnabled(cap)
        let state = service.states[cap] ?? .notDetermined
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(cap.tint.opacity(enabled ? 1 : 0.35))
                    .frame(width: 34, height: 34)
                Image(systemName: cap.icon)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(cap.title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(enabled ? 1 : 0.5))
                Text(cap.detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.gSubtext)
                    .lineLimit(2)
            }

            Spacer(minLength: 6)

            if enabled {
                statusButton(cap, state)
            }

            Toggle("", isOn: Binding(
                get: { service.isEnabled(cap) },
                set: { newValue in
                    withAnimation { service.setEnabled(cap, newValue) }
                    if newValue && state == .notDetermined {
                        Task { await service.requestAccess(cap) }
                    }
                }
            ))
            .labelsHidden()
            .tint(.gSuccess)
            .scaleEffect(0.8)
            .frame(width: 44)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private func statusButton(_ cap: PhoneCapability, _ state: PhonePermissionState) -> some View {
        switch state {
        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 17))
                .foregroundColor(.gSuccess)
        case .notDetermined:
            Button {
                Task { await service.requestAccess(cap) }
            } label: {
                Text("İzin Ver")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Color.gAccent.opacity(0.25)))
                    .overlay(Capsule().stroke(Color.gAccent.opacity(0.5), lineWidth: 1))
                    .foregroundColor(.white)
            }
            .buttonStyle(ScaleButtonStyle())
        case .denied:
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Ayarlar")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Color.gDanger.opacity(0.18)))
                    .overlay(Capsule().stroke(Color.gDanger.opacity(0.4), lineWidth: 1))
                    .foregroundColor(.gDanger)
            }
            .buttonStyle(ScaleButtonStyle())
        case .unavailable:
            Text(cap == .health ? "Kurulum gerekli" : "Yok")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.gSubtext)
        }
    }

    // MARK: iOS kısıtları

    private var limitsNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showLimits.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 12, weight: .bold))
                    Text("iOS'un izin vermedikleri")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                    Spacer()
                    Image(systemName: showLimits ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundColor(.gWarning)
            }
            .buttonStyle(.plain)

            if showLimits {
                Text("""
                Apple güvenlik politikası gereği hiçbir uygulama şunları yapamaz:
                • Gelen SMS / iMessage içeriklerini okumak
                • Arama geçmişini (gelen / cevapsız aramalar) görmek
                • Saat uygulamasındaki mevcut alarmları görmek
                • Onaysız arama başlatmak / onaysız SMS göndermek

                Robotun bunların yerine: anlık arama durumunu görür, aramayı tek onayla başlatır, mesaj taslağını hazırlar (SMS, iMessage, WhatsApp; arka planda göndermek için Netgsm), kendi kurduğu alarmları görür ve yönetir (iOS 26+'da gerçek alarm olarak çalar).
                """)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(.gSubtext)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.gWarning.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.gWarning.opacity(0.2), lineWidth: 1))
        )
    }

    private func requestAll() {
        isRequestingAll = true
        Task {
            for cap in PhoneCapability.allCases where service.isEnabled(cap) && service.states[cap] == .notDetermined {
                await service.requestAccess(cap)
                try? await Task.sleep(for: .milliseconds(350))
            }
            isRequestingAll = false
        }
    }
}

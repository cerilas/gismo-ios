import SwiftUI

struct RobotListView: View {
    @StateObject private var viewModel = RobotListViewModel()
    @ObservedObject private var authService = GoogleAuthService.shared
    @State private var showSetup = false
    @State private var selectedRobot: Robot?
    @State private var headerAppeared = false
    @State private var robotPendingDeletion: Robot?
    @State private var robotPendingModeSelection: Robot?
    @State private var selectedFaceRobot: Robot?
    @State private var showIntegrations = false

    // Test Mode Properties
    @State private var logoTapCount = 0
    @State private var showPasswordPrompt = false
    @State private var testPassword = ""
    @AppStorage("isTestModeEnabled") private var isTestModeEnabled = false

    var body: some View {
        ZStack {
            GismoBackground()

            VStack(spacing: 0) {
                // MARK: Header
                headerView

                // MARK: Quick System Status Strip
                systemStatusStrip
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                    .opacity(headerAppeared ? 1 : 0)
                    .offset(y: headerAppeared ? 0 : -10)

                // MARK: Content
                refreshableContent
            }

            if let robot = robotPendingModeSelection {
                modeSelectionOverlay(for: robot)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .zIndex(10)
            }
        }
        .fullScreenCover(isPresented: $showSetup) {
            SetupContainerView { newRobot in
                viewModel.addRobot(newRobot)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.selectedRobot = newRobot
                }
            }
        }
        .fullScreenCover(item: $selectedRobot) { robot in
            ControlView(robot: robot)
        }
        .fullScreenCover(item: $selectedFaceRobot) { robot in
            GismoFaceView(robot: robot)
        }
        .sheet(isPresented: $showIntegrations) {
            IntegrationsView()
        }
        .alert("Robotu Sil?", isPresented: deleteAlertBinding, presenting: robotPendingDeletion) { robot in
            Button("Vazgeç", role: .cancel) {
                robotPendingDeletion = nil
            }
            Button("Sil", role: .destructive) {
                viewModel.deleteRobot(robot)
                robotPendingDeletion = nil
            }
        } message: { robot in
            Text("\(robot.name) listesinden ve veritabanından silinecek.")
        }
        .alert("Geliştirici Modu", isPresented: $showPasswordPrompt) {
            SecureField("Şifre", text: $testPassword)
            Button("İptal", role: .cancel) { testPassword = "" }
            Button("Onayla") {
                if testPassword == "2423" {
                    withAnimation { isTestModeEnabled.toggle() }
                }
                testPassword = ""
            }
        } message: {
            Text("Lütfen test modu şifresini girin.")
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(alignment: .center, spacing: 14) {
            // Brand Emblem + Title (tappable for developer test mode)
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.gSurface2, Color.gSurface],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 46, height: 46)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(LinearGradient.accent, lineWidth: 1.4)
                        )
                        .shadow(color: Color.gAccent.opacity(0.28), radius: 10, x: 0, y: 4)

                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.gCyan)
                            .frame(width: 7, height: 11)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.gCyan)
                            .frame(width: 7, height: 11)
                    }
                    .shadow(color: Color.gCyan.opacity(0.8), radius: 4)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("GISMO")
                            .font(.system(size: 26, weight: .black, design: .rounded))
                            .tracking(2)
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.white, Color.gAccent2],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )

                        if isTestModeEnabled {
                            Text("DEV")
                                .font(.system(size: 9, weight: .black, design: .monospaced))
                                .foregroundColor(.black)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.gWarning))
                        }
                    }

                    Text(subtextForHeader)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(isTestModeEnabled ? .gWarning : .gSubtext)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                handleLogoTap()
            }

            Spacer()

            // Integrations button with live connection dot
            Button {
                showIntegrations = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(Color.gSurface2.opacity(0.85))
                            .frame(width: 46, height: 46)
                            .overlay(
                                RoundedRectangle(cornerRadius: 15, style: .continuous)
                                    .stroke(
                                        authService.isConnected ? Color.gSuccess.opacity(0.45) : Color.gBorder,
                                        lineWidth: 1
                                    )
                            )

                        Image(systemName: "sparkles.rectangle.stack.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                    }

                    Circle()
                        .fill(authService.isConnected ? Color.gSuccess : Color.gSubtext.opacity(0.5))
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Color.gBg, lineWidth: 2))
                        .offset(x: 2, y: -2)
                }
            }
            .buttonStyle(ScaleButtonStyle())

            // Add robot button
            Button {
                showSetup = true
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(LinearGradient.accent)
                        .frame(width: 46, height: 46)
                        .overlay(
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .stroke(Color.white.opacity(0.25), lineWidth: 1)
                        )
                        .shadow(color: Color.gAccent.opacity(0.4), radius: 12, x: 0, y: 6)

                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.top, 56)
        .padding(.bottom, 18)
        .opacity(headerAppeared ? 1 : 0)
        .offset(y: headerAppeared ? 0 : -20)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1)) {
                headerAppeared = true
            }
        }
        .task {
            await viewModel.loadRobots()
        }
    }

    // MARK: - System Status Strip

    private var systemStatusStrip: some View {
        let onlineCount = viewModel.robots.filter { $0.isOnline }.count
        return HStack(spacing: 10) {
            statusPill(
                icon: "cpu.fill",
                title: "ROBOTLAR",
                value: "\(onlineCount)/\(viewModel.robots.count) Aktif",
                tint: onlineCount > 0 ? .gSuccess : .gAccent2
            )

            Button {
                showIntegrations = true
            } label: {
                statusPill(
                    icon: authService.isConnected ? "checkmark.icloud.fill" : "icloud.slash.fill",
                    title: "GOOGLE CLOUD",
                    value: authService.isConnected ? "Drive • Photos • Mail" : "Bağlamak İçin Dokun",
                    tint: authService.isConnected ? .gSuccess : .gWarning
                )
            }
            .buttonStyle(ScaleButtonStyle())
        }
    }

    private func statusPill(icon: String, title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(0.14))
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(tint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundColor(.gSubtext)
                    .tracking(0.8)
                Text(value)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.gSurface.opacity(0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private var subtextForHeader: String {
        if isTestModeEnabled { return "Geliştirici Test Modu Aktif" }
        if logoTapCount >= 3 { return "Test moduna \(5 - logoTapCount) adım..." }
        return "Otonom Robot Kontrol Merkezi"
    }

    private func handleLogoTap() {
        logoTapCount += 1

        if logoTapCount >= 5 {
            showPasswordPrompt = true
            logoTapCount = 0
        } else {
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if !showPasswordPrompt {
                    logoTapCount = 0
                }
            }
        }
    }

    // MARK: - Robot List

    @ViewBuilder
    private var refreshableContent: some View {
        if viewModel.robots.isEmpty {
            ScrollView(showsIndicators: false) {
                if viewModel.isLoading {
                    loadingStateView
                } else if let errorMessage = viewModel.errorMessage {
                    errorStateView(message: errorMessage)
                } else {
                    emptyStateView
                }
            }
            .refreshable {
                await viewModel.loadRobots()
            }
        } else {
            robotListContent
                .refreshable {
                    await viewModel.loadRobots()
                }
        }
    }

    private var robotListContent: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                inlineErrorView(message: errorMessage)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 12, trailing: 20))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            ForEach(viewModel.robots) { robot in
                RobotCard(
                    robot: robot,
                    isInteractive: robot.isOnline || isTestModeEnabled,
                    onSelectFace: {
                        selectedFaceRobot = robot
                    },
                    onSelectControl: {
                        selectedRobot = robot
                    },
                    onCardTap: {
                        if robot.isOnline || isTestModeEnabled {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                                robotPendingModeSelection = robot
                            }
                        }
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .opacity
                ))
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        robotPendingDeletion = robot
                    } label: {
                        Label("Sil", systemImage: "trash")
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { robotPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    robotPendingDeletion = nil
                }
            }
        )
    }

    // MARK: - Mode Selection Modal

    private func modeSelectionOverlay(for robot: Robot) -> some View {
        ZStack {
            Color.black.opacity(0.68)
                .ignoresSafeArea()
                .onTapGesture {
                    dismissModeSelection()
                }

            VStack(spacing: 20) {
                HStack(alignment: .center, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(LinearGradient.accent)
                            .frame(width: 58, height: 58)
                            .shadow(color: Color.gAccent.opacity(0.4), radius: 12, x: 0, y: 6)

                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.white)
                                .frame(width: 8, height: 14)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.white)
                                .frame(width: 8, height: 14)
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text(robot.name)
                            .font(.system(size: 22, weight: .black, design: .rounded))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        Text("Çalışma modunu seçin")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.gSubtext)

                        StatusBadge(isOnline: robot.isOnline)
                    }

                    Spacer(minLength: 0)

                    Button {
                        dismissModeSelection()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.gSubtext)
                            .frame(width: 36, height: 36)
                            .background(
                                Circle()
                                    .fill(Color.gSurface2)
                                    .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 1))
                            )
                    }
                    .buttonStyle(ScaleButtonStyle())
                }

                VStack(spacing: 12) {
                    modeOptionButton(
                        title: "Gismo AI Yüz & Sesli Asistan",
                        subtitle: "Canlı konuşma, yüz takibi, kamera ve Google asistanı",
                        icon: "sparkles",
                        badge: "ÖNERİLEN",
                        tint: .gSuccess
                    ) {
                        dismissModeSelection()
                        selectedFaceRobot = robot
                    }

                    modeOptionButton(
                        title: "Manuel Sürüş & Telemetri Kokpiti",
                        subtitle: "Taktiksel joystick ile ileri, geri, sağ, sol ve AP kontrolü",
                        icon: "gamecontroller.fill",
                        badge: nil,
                        tint: .gAccent2
                    ) {
                        dismissModeSelection()
                        selectedRobot = robot
                    }
                }
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.gSurface2.opacity(0.96), Color.gSurface.opacity(0.98)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(LinearGradient.glassBorder, lineWidth: 1.2)
            )
            .shadow(color: .black.opacity(0.5), radius: 32, x: 0, y: 18)
            .padding(.horizontal, 22)
        }
    }

    private func modeOptionButton(
        title: String,
        subtitle: String,
        icon: String,
        badge: String?,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(tint.opacity(0.16))
                        .frame(width: 50, height: 50)
                        .overlay(
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .stroke(tint.opacity(0.35), lineWidth: 1)
                        )

                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(tint)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        if let badge {
                            Text(badge)
                                .font(.system(size: 8, weight: .black, design: .monospaced))
                                .foregroundColor(.black)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(tint))
                        }
                    }

                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.gSubtext)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(tint)
            }
            .padding(15)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.black.opacity(0.28))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(tint.opacity(0.22), lineWidth: 1)
            )
        }
        .buttonStyle(ScaleButtonStyle())
    }

    private func dismissModeSelection() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            robotPendingModeSelection = nil
        }
    }

    // MARK: - Empty / Loading / Error States

    private func inlineErrorView(message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.gWarning)

            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.gSubtext)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.gSurface.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.gWarning.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var loadingStateView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(Color.gAccent.opacity(0.2), lineWidth: 1.5)
                    .frame(width: 84, height: 84)
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .gAccent2))
                    .scaleEffect(1.3)
            }

            VStack(spacing: 6) {
                Text("Robotlar Taranıyor")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("Ağ üzerindeki Gismo üniteleri kontrol ediliyor...")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.gSubtext)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 420)
    }

    private func errorStateView(message: String) -> some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.gDanger.opacity(0.12))
                    .frame(width: 116, height: 116)
                    .overlay(
                        Circle()
                            .stroke(Color.gDanger.opacity(0.3), lineWidth: 1)
                    )
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundColor(.gDanger)
            }

            VStack(spacing: 10) {
                Text("Bağlantı Kurulamadı")
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                Text(message)
                    .font(.system(size: 14))
                    .foregroundColor(.gSubtext)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
            }

            GismoPrimaryButton("Yeniden Dene", icon: "arrow.clockwise", isLoading: viewModel.isLoading) {
                Task {
                    await viewModel.loadRobots()
                }
            }
            .padding(.horizontal, 56)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 480)
    }

    private var emptyStateView: some View {
        VStack(spacing: 26) {
            ZStack {
                Circle()
                    .stroke(Color.gAccent.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [5, 7]))
                    .frame(width: 156, height: 156)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.gAccent.opacity(0.20), Color.gSurface2.opacity(0.6)],
                            center: .center,
                            startRadius: 10,
                            endRadius: 65
                        )
                    )
                    .frame(width: 118, height: 118)
                    .overlay(
                        Circle()
                            .stroke(LinearGradient.accent, lineWidth: 1.5)
                    )

                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(LinearGradient.cyberCyan)
            }

            VStack(spacing: 10) {
                Text("Henüz Robot Eklenmedi")
                    .font(.system(size: 23, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                Text("Yeni bir Gismo ünitesini WiFi ağına bağlamak için\naşağıdaki kurulum sihirbazını başlatın.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.gSubtext)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 32)
            }

            GismoPrimaryButton("Yeni Robot Kurulumu", icon: "plus.circle.fill") {
                showSetup = true
            }
            .padding(.horizontal, 48)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 480)
    }
}

// MARK: - Upgraded Robot Card

struct RobotCard: View {
    let robot: Robot
    var isInteractive: Bool = true
    var onSelectFace: (() -> Void)? = nil
    var onSelectControl: (() -> Void)? = nil
    var onCardTap: (() -> Void)? = nil

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 14) {
            // Top Row: Avatar + Info + Status
            HStack(spacing: 15) {
                // Gismo Mini Visor Emblem
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            robot.isOnline
                                ? LinearGradient(
                                    colors: [Color(hex: "19223C"), Color(hex: "0E1324")],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                : LinearGradient(
                                    colors: [Color.gSurface2.opacity(0.6), Color.gSurface.opacity(0.6)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                        )
                        .frame(width: 60, height: 60)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(
                                    robot.isOnline
                                        ? LinearGradient.cyberCyan
                                        : LinearGradient(colors: [Color.white.opacity(0.08), Color.clear], startPoint: .top, endPoint: .bottom),
                                    lineWidth: 1.4
                                )
                        )
                        .shadow(color: robot.isOnline ? Color.gCyan.opacity(0.22) : .clear, radius: 10, x: 0, y: 4)

                    // Mini robot eyes & mouth
                    VStack(spacing: 6) {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                .fill(robot.isOnline ? Color.gCyan : Color.gSubtext.opacity(0.4))
                                .frame(width: 10, height: 14)
                                .shadow(color: robot.isOnline ? Color.gCyan.opacity(0.8) : .clear, radius: 4)

                            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                .fill(robot.isOnline ? Color.gCyan : Color.gSubtext.opacity(0.4))
                                .frame(width: 10, height: 14)
                                .shadow(color: robot.isOnline ? Color.gCyan.opacity(0.8) : .clear, radius: 4)
                        }

                        Capsule()
                            .fill(robot.isOnline ? Color.gSuccess : Color.gSubtext.opacity(0.3))
                            .frame(width: 14, height: 2.5)
                    }
                }

                // Robot Metadata
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(robot.name)
                            .font(.system(size: 19, weight: .black, design: .rounded))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        StatusBadge(isOnline: robot.isOnline)
                    }

                    Text(robot.isOnline ? "Kişisel Robot Arkadaşın • Hazır" : "Şu an çevrimdışı")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundColor(.gSubtext)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onCardTap?()
            }

            // Quick Launch Action Bar (when online or test mode active)
            if isInteractive {
                Divider()
                    .background(Color.white.opacity(0.08))

                HStack(spacing: 10) {
                    Button {
                        onSelectFace?()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 13, weight: .bold))
                            Text("AI Yüz Modu")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(LinearGradient.cyberCyan)
                                .shadow(color: Color.gSuccess.opacity(0.25), radius: 8, x: 0, y: 4)
                        )
                    }
                    .buttonStyle(ScaleButtonStyle())

                    Button {
                        onSelectControl?()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "gamecontroller.fill")
                                .font(.system(size: 13, weight: .bold))
                            Text("Manuel Sürüş")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(Color.white.opacity(0.07))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(ScaleButtonStyle())
                }
            }
        }
        .glassCard(padding: 16, cornerRadius: 24)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 18)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82).delay(0.05)) {
                appeared = true
            }
        }
    }
}

#Preview {
    RobotListView()
}

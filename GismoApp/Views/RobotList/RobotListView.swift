import SwiftUI

struct RobotListView: View {
    @StateObject private var viewModel = RobotListViewModel()
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

                // MARK: Content
                refreshableContent
            }

            if let robot = robotPendingModeSelection {
                modeSelectionOverlay(for: robot)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(10)
            }
        }
        .fullScreenCover(isPresented: $showSetup) {
            SetupContainerView { newRobot in
                viewModel.addRobot(newRobot)
                // Hemen kontrol ekranını aç:
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
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Gismo")
                    .font(.system(size: 32, weight: .black, design: .rounded))
                    .foregroundStyle(LinearGradient.accent)
                    .onTapGesture {
                        handleLogoTap()
                    }
                
                Text(subtextForHeader)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isTestModeEnabled ? .gAccent : .gSubtext)
            }
            Spacer()
            // Integrations button
            Button {
                showIntegrations = true
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 46, height: 46)
                    Image(systemName: "link")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(ScaleButtonStyle())
            
            // Add robot button
            Button {
                showSetup = true
            } label: {
                ZStack {
                    Circle()
                        .fill(LinearGradient.accent)
                        .frame(width: 46, height: 46)
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .padding(.horizontal, 24)
        .padding(.top, 60)
        .padding(.bottom, 24)
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
    
    private var subtextForHeader: String {
        if isTestModeEnabled { return "Test Modu Aktif" }
        if logoTapCount >= 3 { return "Test moduna \(5 - logoTapCount) adım..." }
        return "Robotlarım"
    }
    
    private func handleLogoTap() {
        logoTapCount += 1
        
        if logoTapCount >= 5 {
            showPasswordPrompt = true
            logoTapCount = 0
        } else {
            // Tap sayacını sıfırlamak için gecikmeli bir task
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 saniye
                // Sadece süre içinde yeni tıklama olmadıysa sıfırla
                // Bu basit bir yaklaşım, çok hızlı tıklamaları yakalar
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
                RobotCard(robot: robot)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity
                    ))
                    .onTapGesture {
                        if robot.isOnline || isTestModeEnabled {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                                robotPendingModeSelection = robot
                            }
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            robotPendingDeletion = robot
                        } label: {
                            Label("Sil", systemImage: "trash")
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 7, leading: 20, bottom: 7, trailing: 20))
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

    // MARK: - Mode Selection

    private func modeSelectionOverlay(for robot: Robot) -> some View {
        ZStack {
            Color.black.opacity(0.56)
                .ignoresSafeArea()
                .onTapGesture {
                    dismissModeSelection()
                }

            VStack(spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(LinearGradient.accent)
                            .frame(width: 58, height: 58)

                        Image(systemName: "cpu")
                            .font(.system(size: 25, weight: .semibold))
                            .foregroundColor(.white)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(robot.name)
                            .font(.system(size: 22, weight: .black, design: .rounded))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        Text("Gismo ile ne yapmak istiyorsun?")
                            .font(.system(size: 14, weight: .medium))
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
                            .frame(width: 34, height: 34)
                            .background(
                                Circle()
                                    .fill(Color.gSurface2.opacity(0.9))
                            )
                    }
                    .buttonStyle(ScaleButtonStyle())
                }

                VStack(spacing: 12) {
                    modeOptionButton(
                        title: "Gismo'yu manuel kontrol et",
                        subtitle: "İleri, geri, sağ, sol ve dur komutları",
                        icon: "gamecontroller.fill",
                        tint: .gAccent
                    ) {
                        dismissModeSelection()
                        selectedRobot = robot
                    }

                    modeOptionButton(
                        title: "Gismo'nun kendisini istiyorum",
                        subtitle: "Telefon ekranını Gismo'nun yüzü yap",
                        icon: "sparkles",
                        tint: .gSuccess
                    ) {
                        dismissModeSelection()
                        selectedFaceRobot = robot
                    }
                }
            }
            .padding(22)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.gSurface.opacity(0.98))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 26, x: 0, y: 18)
            .padding(.horizontal, 22)
        }
    }

    private func modeOptionButton(
        title: String,
        subtitle: String,
        icon: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(tint.opacity(0.16))
                        .frame(width: 48, height: 48)

                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(tint)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.gSubtext)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.gSubtext)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.gSurface2.opacity(0.82))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
            )
        }
        .buttonStyle(ScaleButtonStyle())
    }

    private func dismissModeSelection() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            robotPendingModeSelection = nil
        }
    }

    // MARK: - Empty State

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
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.gSurface.opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.gWarning.opacity(0.25), lineWidth: 1)
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var loadingStateView: some View {
        VStack(spacing: 18) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .gAccent))
                .scaleEffect(1.2)

            Text("Robotlar yükleniyor")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.gSubtext)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 420)
    }

    private func errorStateView(message: String) -> some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(Color.gDanger.opacity(0.12))
                    .frame(width: 120, height: 120)
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 44, weight: .light))
                    .foregroundColor(.gDanger)
            }

            VStack(spacing: 10) {
                Text("Robotlar Yüklenemedi")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                Text(message)
                    .font(.system(size: 14))
                    .foregroundColor(.gSubtext)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
            }

            GismoPrimaryButton("Tekrar Dene", icon: "arrow.clockwise", isLoading: viewModel.isLoading) {
                Task {
                    await viewModel.loadRobots()
                }
            }
            .padding(.horizontal, 60)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 520)
    }

    private var emptyStateView: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.gAccent.opacity(0.1))
                    .frame(width: 120, height: 120)
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 48, weight: .light))
                    .foregroundColor(.gSubtext)
            }

            VStack(spacing: 10) {
                Text("Robot Bulunamadı")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                Text("Yeni bir robot eklemek için\n+ butonuna dokun")
                    .font(.system(size: 15))
                    .foregroundColor(.gSubtext)
                    .multilineTextAlignment(.center)
            }

            GismoPrimaryButton("Robot Ekle", icon: "plus") {
                showSetup = true
            }
            .padding(.horizontal, 60)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 520)
    }
}

// MARK: - Robot Card

struct RobotCard: View {
    let robot: Robot
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 16) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        robot.isOnline
                            ? LinearGradient.accent
                            : LinearGradient(colors: [Color.gSurface2, Color.gSurface2],
                                            startPoint: .top, endPoint: .bottom)
                    )
                    .frame(width: 56, height: 56)

                Image(systemName: "cpu")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(robot.isOnline ? .white : .gSubtext)
            }

            // Info
            VStack(alignment: .leading, spacing: 5) {
                Text(robot.name)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)

                if let ip = robot.ipAddress {
                    Text(ip)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.gSubtext)
                }

                StatusBadge(isOnline: robot.isOnline)
            }

            Spacer()

            // Chevron (only if online)
            if robot.isOnline {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.gAccent)
            }
        }
        .glassCard(padding: 16)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 20)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.05)) {
                appeared = true
            }
        }
    }
}

#Preview {
    RobotListView()
}

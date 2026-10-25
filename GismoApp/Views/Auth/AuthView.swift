import SwiftUI

// MARK: - AuthView (Login & Register with Google or Email/Phone + Cerilas SMS OTP)

struct AuthView: View {
    @ObservedObject private var auth = AuthService.shared

    enum AuthTab: String, CaseIterable {
        case login    = "Giriş Yap"
        case register = "Kayıt Ol"
    }

    enum LoginMethod: String, CaseIterable {
        case password = "Şifre ile"
        case smsOtp   = "SMS Kodu ile"
    }

    @State private var selectedTab: AuthTab = .login
    @State private var loginMethod: LoginMethod = .password

    // Login Fields
    @State private var loginIdentifier: String = ""
    @State private var loginPassword: String = ""
    @State private var showLoginPassword: Bool = false

    // SMS Login Fields
    @State private var smsLoginPhone: String = ""
    @State private var smsLoginOtpSent: Bool = false
    @State private var smsLoginOtpCode: String = ""

    // Register Fields
    @State private var regFullName: String = ""
    @State private var regEmail: String = ""
    @State private var regPhone: String = ""
    @State private var regPassword: String = ""
    @State private var showRegPassword: Bool = false
    @State private var regOtpSent: Bool = false
    @State private var regOtpCode: String = ""

    // Countdown & Status
    @State private var resendSecondsRemaining: Int = 0
    @State private var infoBannerMessage: String?
    @State private var localErrorMessage: String?

    private let countdownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            GismoBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    // MARK: - Brand Header
                    brandHeader
                        .padding(.top, 24)

                    // MARK: - Main Card
                    VStack(spacing: 20) {
                        // Google Sign-In / Sign-Up Button
                        googleAuthButton

                        // Divider
                        HStack(spacing: 12) {
                            Rectangle()
                                .fill(Color.gBorder)
                                .frame(height: 1)
                            Text("VEYA")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .tracking(1.4)
                                .foregroundColor(.gSubtext)
                            Rectangle()
                                .fill(Color.gBorder)
                                .frame(height: 1)
                        }

                        // Tab Switcher (Giriş Yap / Kayıt Ol)
                        tabSelector

                        // Error / Info Feedback
                        if let errorText = localErrorMessage ?? auth.errorMessage {
                            feedbackBanner(text: errorText, isError: true)
                        } else if let infoText = infoBannerMessage {
                            feedbackBanner(text: infoText, isError: false)
                        }

                        // Active Form
                        if selectedTab == .login {
                            loginSection
                        } else {
                            registerSection
                        }
                    }
                    .padding(22)
                    .background(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(Color.gSurface.opacity(0.92))
                            .overlay(
                                RoundedRectangle(cornerRadius: 26, style: .continuous)
                                    .stroke(Color.gBorder, lineWidth: 1)
                            )
                            .shadow(color: Color.black.opacity(0.45), radius: 24, x: 0, y: 12)
                    )
                    .padding(.horizontal, 20)

                    // Footer note
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.gCyan)
                        Text("Cerilas SMS Doğrulama & Güvenli Bulut Hesabı")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundColor(.gSubtext)
                    }
                    .padding(.bottom, 32)
                }
            }
        }
        .onReceive(countdownTimer) { _ in
            if resendSecondsRemaining > 0 {
                resendSecondsRemaining -= 1
            }
        }
    }

    // MARK: - Brand Header

    private var brandHeader: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.gAccent.opacity(0.32), Color.clear],
                            center: .center,
                            startRadius: 8,
                            endRadius: 56
                        )
                    )
                    .frame(width: 110, height: 110)

                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.gSurface2, Color.gSurface],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 72, height: 72)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(LinearGradient.accent, lineWidth: 1.8)
                    )
                    .shadow(color: Color.gAccent.opacity(0.35), radius: 14, x: 0, y: 6)

                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gCyan)
                        .frame(width: 11, height: 18)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gCyan)
                        .frame(width: 11, height: 18)
                }
                .shadow(color: Color.gCyan.opacity(0.9), radius: 6)
            }

            VStack(spacing: 4) {
                Text("GISMO")
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .tracking(3)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white, Color.gAccent2],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                Text("Devam etmek için giriş yapın veya hesap oluşturun")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(.gSubtext)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Google Sign-In / Sign-Up Button

    private var googleAuthButton: some View {
        Button {
            clearMessages()
            Task {
                try? await auth.signInWithGoogle()
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 28, height: 28)
                    Text("G")
                        .font(.system(size: 16, weight: .black, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.26, green: 0.52, blue: 0.96),
                                    Color(red: 0.92, green: 0.26, blue: 0.21),
                                    Color(red: 0.98, green: 0.74, blue: 0.02),
                                    Color(red: 0.20, green: 0.66, blue: 0.33)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                Text("Google ile Giriş Yap / Kayıt Ol")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.gSubtext)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.gSurface2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
            )
        }
        .disabled(auth.isLoading)
    }

    // MARK: - Tab Selector

    private var tabSelector: some View {
        HStack(spacing: 6) {
            ForEach(AuthTab.allCases, id: \.self) { tab in
                let isSelected = selectedTab == tab
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        selectedTab = tab
                        clearMessages()
                    }
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(isSelected ? .white : .gSubtext)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(
                                    isSelected
                                        ? AnyShapeStyle(LinearGradient.accent)
                                        : AnyShapeStyle(Color.clear)
                                )
                        )
                }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.gBg.opacity(0.75))
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(Color.gBorder, lineWidth: 1)
                )
        )
    }

    // MARK: - Login Section

    private var loginSection: some View {
        VStack(spacing: 16) {
            // Sub-method toggle: Şifre ile vs SMS Kodu ile
            HStack(spacing: 8) {
                ForEach(LoginMethod.allCases, id: \.self) { method in
                    let active = loginMethod == method
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            loginMethod = method
                            clearMessages()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: method == .password ? "key.fill" : "message.badge.filled.fill")
                                .font(.system(size: 12, weight: .semibold))
                            Text(method.rawValue)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(active ? .gCyan : .gSubtext)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(active ? Color.gCyan.opacity(0.14) : Color.gSurface2.opacity(0.5))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(active ? Color.gCyan.opacity(0.45) : Color.clear, lineWidth: 1)
                                )
                        )
                    }
                }
            }

            if loginMethod == .password {
                // Email or Phone + Password
                authInputField(
                    title: "E-POSTA VEYA TELEFON",
                    icon: "person.crop.circle.fill",
                    placeholder: "ornek@mail.com veya 05XX XXX XX XX",
                    text: $loginIdentifier,
                    keyboardType: .emailAddress
                )

                authPasswordField(
                    title: "ŞİFRE",
                    placeholder: "Şifrenizi girin",
                    text: $loginPassword,
                    isVisible: $showLoginPassword
                )

                primaryActionButton(
                    title: "Giriş Yap",
                    icon: "arrow.right.circle.fill"
                ) {
                    handlePasswordLogin()
                }
            } else {
                // Phone + Cerilas SMS OTP Login
                authInputField(
                    title: "CEP TELEFONU NUMARASI",
                    icon: "phone.fill",
                    placeholder: "05XX XXX XX XX",
                    text: $smsLoginPhone,
                    keyboardType: .phonePad
                )
                .disabled(smsLoginOtpSent)

                if smsLoginOtpSent {
                    otpVerificationCard(
                        phone: smsLoginPhone,
                        otpCode: $smsLoginOtpCode,
                        onVerify: {
                            handleOtpLoginVerify()
                        },
                        onResend: {
                            handleSendLoginOtp()
                        },
                        onChangePhone: {
                            withAnimation {
                                smsLoginOtpSent = false
                                smsLoginOtpCode = ""
                                clearMessages()
                            }
                        }
                    )
                } else {
                    primaryActionButton(
                        title: "SMS Doğrulama Kodu Gönder",
                        icon: "paperplane.fill"
                    ) {
                        handleSendLoginOtp()
                    }
                }
            }
        }
    }

    // MARK: - Register Section (Email + Phone + Password -> Cerilas SMS OTP)

    private var registerSection: some View {
        VStack(spacing: 15) {
            if !regOtpSent {
                authInputField(
                    title: "AD SOYAD",
                    icon: "person.fill",
                    placeholder: "Adınız Soyadınız",
                    text: $regFullName,
                    keyboardType: .default,
                    autocapitalization: .words
                )

                authInputField(
                    title: "E-POSTA ADRESİ (DOĞRULAMA GEREKMEZ)",
                    icon: "envelope.fill",
                    placeholder: "ornek@mail.com",
                    text: $regEmail,
                    keyboardType: .emailAddress
                )

                authInputField(
                    title: "CEP TELEFONU (CERİLAS SMS DOĞRULAMALI)",
                    icon: "phone.badge.checkmark.fill",
                    placeholder: "05XX XXX XX XX",
                    text: $regPhone,
                    keyboardType: .phonePad
                )

                authPasswordField(
                    title: "ŞİFRE (EN AZ 6 KARAKTER)",
                    placeholder: "Şifre belirleyin",
                    text: $regPassword,
                    isVisible: $showRegPassword
                )

                primaryActionButton(
                    title: "SMS Doğrulama Kodu Gönder",
                    icon: "message.badge.filled.fill"
                ) {
                    handleSendRegisterOtp()
                }
            } else {
                otpVerificationCard(
                    phone: regPhone,
                    otpCode: $regOtpCode,
                    onVerify: {
                        handleCompleteRegistration()
                    },
                    onResend: {
                        handleSendRegisterOtp()
                    },
                    onChangePhone: {
                        withAnimation {
                            regOtpSent = false
                            regOtpCode = ""
                            clearMessages()
                        }
                    }
                )
            }
        }
    }

    // MARK: - OTP Verification Card

    private func otpVerificationCard(
        phone: String,
        otpCode: Binding<String>,
        onVerify: @escaping () -> Void,
        onResend: @escaping () -> Void,
        onChangePhone: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.message.fill")
                        .foregroundColor(.gCyan)
                    Text("SMS Doğrulama Kodu Gönderildi")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }

                Text("\(phone) numarasına Cerilas SMS servisi ile gönderilen 6 haneli kodu girin.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.gSubtext)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 4)

            // 6-Digit Code Field
            TextField("000000", text: otpCode)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .multilineTextAlignment(.center)
                .font(.system(size: 28, weight: .black, design: .monospaced))
                .tracking(10)
                .foregroundColor(.gCyan)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.gBg)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.gCyan.opacity(0.55), lineWidth: 1.5)
                        )
                )
                .onChange(of: otpCode.wrappedValue) { newValue in
                    let filtered = newValue.filter(\.isNumber)
                    if filtered.count > 6 {
                        otpCode.wrappedValue = String(filtered.prefix(6))
                    } else if filtered != newValue {
                        otpCode.wrappedValue = filtered
                    }
                }

            primaryActionButton(
                title: selectedTab == .register ? "Doğrula ve Kayıt Ol" : "Doğrula ve Giriş Yap",
                icon: "checkmark.seal.fill"
            ) {
                onVerify()
            }

            HStack {
                Button {
                    onChangePhone()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Bilgileri Düzenle")
                    }
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.gSubtext)
                }

                Spacer()

                Button {
                    onResend()
                } label: {
                    if resendSecondsRemaining > 0 {
                        Text("Tekrar Gönder (\(resendSecondsRemaining)s)")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundColor(.gSubtext.opacity(0.6))
                    } else {
                        Text("Kodu Tekrar Gönder")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(.gCyan)
                    }
                }
                .disabled(resendSecondsRemaining > 0 || auth.isLoading)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.gSurface2.opacity(0.75))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.gCyan.opacity(0.28), lineWidth: 1)
                )
        )
    }

    // MARK: - Reusable Input Components

    private func authInputField(
        title: String,
        icon: String,
        placeholder: String,
        text: Binding<String>,
        keyboardType: UIKeyboardType = .default,
        autocapitalization: TextInputAutocapitalization = .never
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundColor(.gSubtext)

            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.gAccent2)
                    .frame(width: 22)

                TextField(placeholder, text: text)
                    .keyboardType(keyboardType)
                    .textInputAutocapitalization(autocapitalization)
                    .autocorrectionDisabled(true)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.gBg.opacity(0.85))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.gBorder, lineWidth: 1)
                    )
            )
        }
    }

    private func authPasswordField(
        title: String,
        placeholder: String,
        text: Binding<String>,
        isVisible: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundColor(.gSubtext)

            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.gAccent2)
                    .frame(width: 22)

                Group {
                    if isVisible.wrappedValue {
                        TextField(placeholder, text: text)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                    } else {
                        SecureField(placeholder, text: text)
                            .textInputAutocapitalization(.never)
                    }
                }
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundColor(.white)

                Button {
                    isVisible.wrappedValue.toggle()
                } label: {
                    Image(systemName: isVisible.wrappedValue ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.gSubtext)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.gBg.opacity(0.85))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.gBorder, lineWidth: 1)
                    )
            )
        }
    }

    private func primaryActionButton(
        title: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if auth.isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .bold))
                    Text(title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                }
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(LinearGradient.accent)
                    .shadow(color: Color.gAccent.opacity(0.4), radius: 12, x: 0, y: 6)
            )
        }
        .disabled(auth.isLoading)
    }

    private func feedbackBanner(text: String, isError: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundColor(isError ? .gDanger : .gSuccess)
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill((isError ? Color.gDanger : Color.gSuccess).opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke((isError ? Color.gDanger : Color.gSuccess).opacity(0.45), lineWidth: 1)
                )
        )
    }

    // MARK: - Actions

    private func clearMessages() {
        localErrorMessage = nil
        infoBannerMessage = nil
        auth.errorMessage = nil
    }

    private func handlePasswordLogin() {
        clearMessages()
        let id = loginIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !loginPassword.isEmpty else {
            localErrorMessage = "Lütfen e-posta/telefon ve şifrenizi girin."
            return
        }
        Task {
            try? await auth.loginWithPassword(identifier: id, password: loginPassword)
        }
    }

    private func handleSendLoginOtp() {
        clearMessages()
        let phone = smsLoginPhone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phone.isEmpty else {
            localErrorMessage = "Lütfen cep telefonu numaranızı girin."
            return
        }
        Task {
            do {
                let message = try await auth.sendOTP(phone: phone, purpose: "login")
                withAnimation {
                    smsLoginOtpSent = true
                    resendSecondsRemaining = 60
                    infoBannerMessage = message
                }
            } catch {
                localErrorMessage = error.localizedDescription
            }
        }
    }

    private func handleOtpLoginVerify() {
        clearMessages()
        guard smsLoginOtpCode.count == 6 else {
            localErrorMessage = "Lütfen 6 haneli SMS doğrulama kodunu girin."
            return
        }
        Task {
            try? await auth.loginWithOTP(phone: smsLoginPhone, otpCode: smsLoginOtpCode)
        }
    }

    private func handleSendRegisterOtp() {
        clearMessages()
        let name  = regFullName.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = regEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let phone = regPhone.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty else {
            localErrorMessage = "Lütfen adınızı ve soyadınızı girin."
            return
        }
        guard email.contains("@") && email.contains(".") else {
            localErrorMessage = "Lütfen geçerli bir e-posta adresi girin."
            return
        }
        guard !phone.isEmpty else {
            localErrorMessage = "Lütfen cep telefonu numaranızı girin."
            return
        }
        guard regPassword.count >= 6 else {
            localErrorMessage = "Şifreniz en az 6 karakter olmalıdır."
            return
        }

        Task {
            do {
                let message = try await auth.sendOTP(phone: phone, email: email, purpose: "register")
                withAnimation {
                    regOtpSent = true
                    resendSecondsRemaining = 60
                    infoBannerMessage = message
                }
            } catch {
                localErrorMessage = error.localizedDescription
            }
        }
    }

    private func handleCompleteRegistration() {
        clearMessages()
        guard regOtpCode.count == 6 else {
            localErrorMessage = "Lütfen telefonunuza gelen 6 haneli SMS doğrulama kodunu girin."
            return
        }
        Task {
            try? await auth.register(
                fullName: regFullName,
                email: regEmail,
                phone: regPhone,
                password: regPassword,
                otpCode: regOtpCode
            )
        }
    }
}

// MARK: - UserProfileSheet (Account Details & Sign Out)

struct UserProfileSheet: View {
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirm = false

    var body: some View {
        NavigationStack {
            ZStack {
                GismoBackground()

                VStack(spacing: 22) {
                    if let user = auth.currentUser {
                        // Avatar
                        ZStack {
                            Circle()
                                .fill(LinearGradient.accent)
                                .frame(width: 78, height: 78)
                                .shadow(color: Color.gAccent.opacity(0.4), radius: 14, x: 0, y: 6)

                            Text(user.initials)
                                .font(.system(size: 28, weight: .black, design: .rounded))
                                .foregroundColor(.white)
                        }
                        .padding(.top, 16)

                        VStack(spacing: 6) {
                            Text(user.fullName)
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundColor(.white)

                            HStack(spacing: 8) {
                                if user.phoneVerified {
                                    Label("Cerilas SMS Doğrulandı", systemImage: "checkmark.seal.fill")
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .foregroundColor(.gSuccess)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(Capsule().fill(Color.gSuccess.opacity(0.15)))
                                }
                                if user.isGoogleConnected {
                                    Label("Google Bağlı", systemImage: "globe")
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .foregroundColor(.gCyan)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(Capsule().fill(Color.gCyan.opacity(0.15)))
                                }
                            }
                        }

                        // Details Card
                        VStack(spacing: 14) {
                            if !user.email.isEmpty {
                                profileRow(icon: "envelope.fill", label: "E-posta", value: user.email)
                            }
                            if !user.phone.isEmpty {
                                profileRow(icon: "phone.fill", label: "Telefon", value: user.phone)
                            }
                            profileRow(
                                icon: "server.rack",
                                label: "Giriş Yöntemi",
                                value: user.authProvider == "google" ? "Google Hesabı" : "E-posta / Telefon & SMS"
                            )
                        }
                        .padding(18)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Color.gSurface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .stroke(Color.gBorder, lineWidth: 1)
                                )
                        )
                        .padding(.horizontal, 20)
                    }

                    Spacer()

                    // Sign Out & Delete Account Buttons
                    VStack(spacing: 12) {
                        Button {
                            dismiss()
                            auth.signOut()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "rectangle.portrait.and.arrow.right")
                                Text("Çıkış Yap")
                            }
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 15, style: .continuous)
                                    .fill(Color.gSurface2)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                                            .stroke(Color.gBorder, lineWidth: 1)
                                    )
                            )
                        }

                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Text("Hesabımı Sil")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundColor(.gDanger)
                                .padding(.vertical, 6)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Hesabım")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Kapat") {
                        dismiss()
                    }
                    .foregroundColor(.gAccent2)
                }
            }
            .alert("Hesabı Sil?", isPresented: $showDeleteConfirm) {
                Button("Vazgeç", role: .cancel) {}
                Button("Hesabı Sil", role: .destructive) {
                    Task {
                        try? await auth.deleteAccount()
                        dismiss()
                    }
                }
            } message: {
                Text("Hesabınız kalıcı olarak veritabanından silinecek. Bu işlem geri alınamaz.")
            }
        }
        .preferredColorScheme(.dark)
    }

    private func profileRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.gAccent2)
                .frame(width: 24)
            Text(label)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(.gSubtext)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        }
    }
}

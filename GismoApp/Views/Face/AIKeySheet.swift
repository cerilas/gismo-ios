import SwiftUI

// MARK: - Yapay Zeka Anahtarı
// Yüz / yapay zeka modu, kullanıcı kendi Yapay Zeka Anahtarını (Google AI Studio - Gemini API anahtarı)
// girmeden AÇILMAZ. Anahtar UserDefaults'ta "customGeminiApiKey" altında tutulur.

enum AIKeyStore {
    static let storageKey = "customGeminiApiKey"

    static var key: String {
        (UserDefaults.standard.string(forKey: storageKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var hasKey: Bool { !key.isEmpty }

    /// Anahtarı Google'a küçük bir istekle doğrular. nil = geçerli, aksi halde hata mesajı.
    static func validate(_ candidate: String) async -> String? {
        let k = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard k.count >= 30, !k.contains(" ") else {
            return "Anahtar biçimi hatalı görünüyor. AI Studio'dan kopyaladığın anahtarın tamamını yapıştır."
        }
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1&key=\(k)") else {
            return "Anahtar geçersiz karakter içeriyor."
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(code) { return nil }
            if code == 400 || code == 401 || code == 403 {
                return "Bu anahtar Google tarafından kabul edilmedi. Doğru anahtarı girdiğinden emin ol."
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            return "Anahtar doğrulanamadı (HTTP \(code)). \(body.prefix(120))"
        } catch {
            return "İnternet bağlantısı yok gibi görünüyor; anahtar doğrulanamadı."
        }
    }
}

// MARK: - Anahtar Giriş Ekranı

struct AIKeySheet: View {
    /// true: yüz modunu açmaya çalışırken gösterildi (başlık/metin buna göre)
    var isGate: Bool = false
    var onSaved: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage(AIKeyStore.storageKey) private var storedKey: String = ""
    @State private var input: String = ""
    @State private var isChecking = false
    @State private var errorText: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationView {
            ZStack {
                GismoBackground()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 22) {
                        // İkon + başlık
                        VStack(alignment: .leading, spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(LinearGradient.accent)
                                    .frame(width: 62, height: 62)
                                    .shadow(color: Color.gAccent.opacity(0.4), radius: 12, x: 0, y: 6)
                                Image(systemName: isGate ? "lock.fill" : "key.fill")
                                    .font(.system(size: 26, weight: .bold))
                                    .foregroundColor(.white)
                            }
                            Text(isGate ? "Yapay Zeka Anahtarı Gerekli" : "Yapay Zeka Anahtarı")
                                .font(.system(size: 26, weight: .black, design: .rounded))
                                .foregroundColor(.white)
                            Text(isGate
                                 ? "Gismo'nun yüz ve sesli asistan modunu kullanabilmek için önce kendi Yapay Zeka Anahtarını girmelisin."
                                 : "Gismo'nun konuşabilmesi, görebilmesi ve senin adına işlem yapabilmesi için Yapay Zeka Anahtarı kullanılır.")
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundColor(.gSubtext)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        // Giriş alanı
                        VStack(alignment: .leading, spacing: 10) {
                            Text("ANAHTAR")
                                .font(.system(size: 10, weight: .black, design: .monospaced))
                                .tracking(1.4)
                                .foregroundColor(.gCyan)
                            HStack(spacing: 10) {
                                Image(systemName: "key.horizontal.fill")
                                    .foregroundColor(.gAccent2)
                                SecureField("AIza...", text: $input)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.white)
                                    .focused($focused)
                                    .submitLabel(.done)
                                    .onSubmit { save() }
                                if !input.isEmpty {
                                    Button { input = "" } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundColor(.white.opacity(0.35))
                                    }
                                }
                                Button {
                                    if let s = UIPasteboard.general.string { input = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                                } label: {
                                    Text("Yapıştır")
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(Capsule().fill(Color.white.opacity(0.08)))
                                        .foregroundColor(.white)
                                }
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.black.opacity(0.3))
                                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(errorText == nil ? Color.white.opacity(0.1) : Color.gDanger.opacity(0.6), lineWidth: 1))
                            )

                            if let errorText {
                                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundColor(.gDanger)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else if !storedKey.isEmpty {
                                Label("Kayıtlı anahtar: •••• \(String(storedKey.suffix(4)))", systemImage: "checkmark.seal.fill")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundColor(.gSuccess)
                            }
                        }
                        .glassCard(padding: 16, cornerRadius: 22)

                        // Kaydet
                        Button { save() } label: {
                            HStack(spacing: 8) {
                                if isChecking {
                                    ProgressView().tint(.white)
                                } else {
                                    Image(systemName: isGate ? "sparkles" : "checkmark.circle.fill")
                                }
                                Text(isChecking ? "Doğrulanıyor..." : (isGate ? "Kaydet ve Yüz Modunu Aç" : "Kaydet"))
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(Capsule().fill(LinearGradient.accent))
                            .foregroundColor(.white)
                            .shadow(color: Color.gAccent.opacity(0.35), radius: 10, x: 0, y: 5)
                            .opacity(input.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
                        }
                        .buttonStyle(ScaleButtonStyle())
                        .disabled(isChecking || input.trimmingCharacters(in: .whitespaces).isEmpty)

                        // Nasıl alınır
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Anahtarı nasıl alırım?")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                            step(1, "aistudio.google.com adresine Google hesabınla gir.")
                            step(2, "\"Get API key\" → \"Create API key\" seçeneğine dokun.")
                            step(3, "Oluşan anahtarı kopyala, buraya yapıştır ve kaydet.")
                            Button {
                                if let url = URL(string: "https://aistudio.google.com/app/apikey") { openURL(url) }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.up.right.square")
                                    Text("Google AI Studio'yu Aç")
                                }
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(Capsule().fill(Color.white.opacity(0.06)))
                                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
                                .foregroundColor(.gAccent2)
                            }
                            .buttonStyle(ScaleButtonStyle())
                            .padding(.top, 4)
                        }
                        .glassCard(padding: 16, cornerRadius: 22)

                        if !storedKey.isEmpty && !isGate {
                            Button(role: .destructive) {
                                storedKey = ""
                                input = ""
                            } label: {
                                Text("Kayıtlı Anahtarı Sil")
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Capsule().fill(Color.gDanger.opacity(0.14)))
                                    .overlay(Capsule().stroke(Color.gDanger.opacity(0.35), lineWidth: 1))
                                    .foregroundColor(.gDanger)
                            }
                            .buttonStyle(ScaleButtonStyle())
                        }
                    }
                    .padding(22)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.white.opacity(0.6))
                            .font(.system(size: 24))
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { if isGate { focused = true } }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.system(size: 12, weight: .black, design: .rounded))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.gAccent.opacity(0.25)))
                .foregroundColor(.white)
            Text(text)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(.gSubtext)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func save() {
        let candidate = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !isChecking else { return }
        isChecking = true
        errorText = nil
        Task {
            let error = await AIKeyStore.validate(candidate)
            isChecking = false
            if let error {
                errorText = error
                return
            }
            storedKey = candidate
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
            if let onSaved {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { onSaved() }
            }
        }
    }
}

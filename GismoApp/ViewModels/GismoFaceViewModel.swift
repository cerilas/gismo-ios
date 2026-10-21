import SwiftUI
import Combine
import ARKit
import Vision

// MARK: - GismoFaceViewModel

@MainActor
final class GismoFaceViewModel: ObservableObject {

    let robot: Robot

    @Published var currentEmotion: GismoEmotionName = .neutral
    @Published var liveTranscript: String = ""
    @Published var aiResponse: String = ""
    @Published var isThinking: Bool = false
    @Published var isListening: Bool = false
    @Published var isSpeaking: Bool = false
    @Published var speechLevel: CGFloat = 0.0
    @Published var showResponse: Bool = false
    @Published var permissionDenied: Bool = false
    @Published var isTrackingEnabled: Bool = false // Fiziksel motor yüz takibi dengesizlik nedeniyle devre dışı bırakıldı
    private var didCapturePhotoInCurrentTurn: Bool = false

    private let voiceEngine = GismoVoiceEngine()
    private let gemini      = GeminiService()
    private let geminiLive  = GeminiLiveService()
    let camera              = GismoCameraService()
    let vision              = GismoVisionService() // Göz ve yüz takibi
    
    private var emotionResetTask: Task<Void, Never>?
    private var responseHideTask: Task<Void, Never>?
    private var transcriptSyncTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var smileObserverTask: AnyCancellable?
    private var trackingObserverTask: AnyCancellable?
    @Published var currentTrackingCommand: RobotCommand = .stop
    private let idleTimeout: Double = 60  // saniye

    // MARK: - Pulse & Settle Takip State Machine
    private enum TrackingState {
        case idle
        case moving(until: Date)
        case settling(until: Date)
    }
    private var trackingState: TrackingState = .idle
    /// Sabit çok kısa burst: robot tek bir kışı adım atar (0.04 sn)
    private let burstSeconds: TimeInterval = 0.04

    // Anti-spin koruma: ard arda yön değişimi sayılır
    private var lastBurstDirection: RobotCommand? = nil
    private var flipCount: Int = 0
    private let flipLimit: Int = 2         // Kaç ard arda flip'ten sonra soğuma
    private let cooldownSeconds: TimeInterval = 1.5  // Soğuma süresi
    
    // Işık / Parlaklık takibi
    private var lastBrightness: CGFloat = UIScreen.main.brightness
    private var isInitialized: Bool = false

    init(robot: Robot) {
        self.robot = robot
        voiceEngine.robotName = robot.name
        WebSocketService.shared.connect()  // Manuel kontrol gibi komut gönderebilmek için
        
        // Gemini'ye kamera yetkisini devret
        gemini.onTakePhoto = { [weak self] in
            guard let self = self else { return nil }
            return await self.takePhotoForAI()
        }
        
        // Gülümseme algılandığında tepki ver (konuşma esnasında ağız hareketlerinin melodi döngüsüne girmesini önle)
        smileObserverTask = vision.$isSmiling
            .removeDuplicates()
            .sink { [weak self] isSmiling in
                guard let self = self else { return }
                if isSmiling && self.currentEmotion == .neutral && !self.isThinking && !self.isSpeaking && self.voiceEngine.liveTranscript.isEmpty {
                    self.setEmotion(.happy, for: 3, playSound: false)
                }
            }
        
        // Motor ile Akıllı Takip — faceScreenPosition değişince state machine'ı tetikle
        trackingObserverTask = vision.$faceScreenPosition
            .throttle(for: .milliseconds(200), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.handleSmartTracking() }
    }
    
    private func takePhotoForAI() async -> Data? {
        didCapturePhotoInCurrentTurn = true
        // Yüz takip açık ise fotoğraf çekmeden önce kişiyi (subject) kadrajın tam ortasına hizala
        await centerSubjectBeforePhoto()
        self.vision.stop()
        defer { self.vision.start() }
        let image = await self.camera.takePhoto()
        return image?.jpegData(compressionQuality: 0.85)
    }

    /// Yüz takibi (isTrackingEnabled) açıkken fotoğraf çekilmeden hemen önce,
    /// ARKit yüz konumu (veya Vision vücut konumu) verisini kullanarak kişiyi kadrajın tam ortasına (±%8 toleransla) getirir.
    private func centerSubjectBeforePhoto() async {
        guard isTrackingEnabled else { return }
        vision.start()

        let centerDeadband: CGFloat = 0.16 // Tam merkez toleransı (-1...+1 ölçeğinde ±0.16)
        let maxAttempts = 6

        for step in 1...maxAttempts {
            // Güncel yatay konumu oku: Önce ARKit yüz merkezi, yoksa Vision vücut merkezi
            var currentXPos: CGFloat? = nil
            if let facePos = vision.faceScreenPosition {
                currentXPos = (facePos.x - 0.5) * 2.0
            } else if vision.isBodyDetected {
                currentXPos = vision.bodyOffset.x
            } else if step == 1 {
                // İlk adımda henüz frame gelmediyse kısa bir süre bekle ve tekrar kontrol et
                try? await Task.sleep(for: .milliseconds(180))
                if let facePos = vision.faceScreenPosition {
                    currentXPos = (facePos.x - 0.5) * 2.0
                } else if vision.isBodyDetected {
                    currentXPos = vision.bodyOffset.x
                }
            }

            guard let xPos = currentXPos else {
                print("[PhotoCenter] Kadrajda yüz/vücut algılanmadı, mevcut açıdan çekiliyor.")
                break
            }

            if abs(xPos) <= centerDeadband {
                print("[PhotoCenter] Subject tam ortalandı (adım \(step), xPos: \(String(format: "%.2f", xPos))).")
                break
            }

            // Merkezden uzaklığa göre orantılı mikro-darbe (overshoot yapmadan hassas ortalama)
            let direction: RobotCommand = xPos > 0 ? .left : .right
            let pulseMs: Int
            if abs(xPos) > 0.55 {
                pulseMs = 36
            } else if abs(xPos) > 0.32 {
                pulseMs = 25
            } else {
                pulseMs = 18
            }

            print("[PhotoCenter] Adım \(step)/\(maxAttempts): xPos=\(String(format: "%.2f", xPos)) -> \(direction.rawValue) (\(pulseMs)ms)")
            currentTrackingCommand = direction
            try? await WebSocketService.shared.sendCommand(direction, to: robot.id)
            try? await Task.sleep(for: .milliseconds(pulseMs))

            currentTrackingCommand = .stop
            try? await WebSocketService.shared.sendCommand(.stop, to: robot.id)
            // Kamera ve ARKit'in yeni konumu hesaplaması için kısa stabilizasyon
            try? await Task.sleep(for: .milliseconds(240))
        }

        currentTrackingCommand = .stop
        try? await WebSocketService.shared.sendCommand(.stop, to: robot.id)
        try? await Task.sleep(for: .milliseconds(120))
    }
    
    /// Yalnızca yüz ekranda vardıysa ve merkezden kaymışsa motor komutu gönderir.
    /// Yüz yoksa (nil) → hemen dur. Vücut takibi motor kontrolde kullanılmaz.
    private func handleSmartTracking() {
        guard !isThinking && !showResponse && currentEmotion != .sleeping && isTrackingEnabled else {
            sendTrackingCommand(.stop)
            trackingState = .idle
            flipCount = 0; lastBurstDirection = nil
            return
        }

        // Yüz görünmüyorsa anında dur
        guard let facePos = vision.faceScreenPosition else {
            sendTrackingCommand(.stop)
            trackingState = .idle
            flipCount = 0; lastBurstDirection = nil
            return
        }

        // -1 (sol) … 0 (merkez) … +1 (sağ)
        let xPos = (facePos.x - 0.5) * 2.0
        let now  = Date()
        let threshold: CGFloat = 0.65   // Ekran kenarına yakınsa tepki ver (±65%)

        // !! ÖNCE KONTROL: Yüz merkezde mi? Her durumda anında dur !!
        if abs(xPos) <= threshold {
            if currentTrackingCommand != .stop { sendTrackingCommand(.stop) }
            trackingState = .idle
            flipCount = 0; lastBurstDirection = nil
            return
        }

        // Yüz merkezde değil — state machine'e göre davran
        switch trackingState {

        case .moving(let until):
            // Burst süresi bitti → dur, settle'a geç
            if now >= until {
                sendTrackingCommand(.stop)
                // Kamera stabilize olsun + ARKit yüzü yeniden yakalasın
                trackingState = .settling(until: now.addingTimeInterval(0.60))
            }
            return  // Burst devam ediyor — müdahale etme

        case .settling(let until):
            guard now >= until else { return }
            trackingState = .idle

        case .idle:
            break
        }

        // ── Idle: yeni burst değerlendirmesi ──
        let direction: RobotCommand = xPos > 0 ? .left : .right

        // Anti-spin: ard arda ters yön → zorunlu soğuma
        if let last = lastBurstDirection, last != direction {
            flipCount += 1
            if flipCount >= flipLimit {
                print("[Tracking] Anti-spin: \(cooldownSeconds)sn soğuma")
                sendTrackingCommand(.stop)
                trackingState = .settling(until: now.addingTimeInterval(cooldownSeconds))
                flipCount = 0; lastBurstDirection = nil
                return
            }
        } else if lastBurstDirection == direction {
            flipCount = 0
        }
        lastBurstDirection = direction

        sendTrackingCommand(direction)
        trackingState = .moving(until: now.addingTimeInterval(burstSeconds))
    }

    private func sendTrackingCommand(_ cmd: RobotCommand) {
        currentTrackingCommand = cmd
        Task {
            try? await WebSocketService.shared.sendCommand(cmd, to: self.robot.id)
        }
    }

    // MARK: - Lifecycle

    func onAppear() {
        if !isInitialized {
            currentEmotion = .neutral
            gemini.resetHistory()
            GismoSoundEngine.shared.play(.startup)
            setupBrightnessObserver()
            isInitialized = true
        }
        geminiLive.prewarm(apiKey: gemini.apiKey)
        setupVoice()
        vision.start() // Yüz takibini başlat
    }

    func onDisappear() {
        NotificationCenter.default.removeObserver(self, name: UIScreen.brightnessDidChangeNotification, object: nil)
        GismoSoundEngine.shared.stopSpeech()
        geminiLive.disconnect()
        isSpeaking = false
        speechLevel = 0
        voiceEngine.stop()
        vision.stop() // Yüz takibini durdur
        emotionResetTask?.cancel()
        responseHideTask?.cancel()
        transcriptSyncTask?.cancel()
        idleTask?.cancel()
    }

    // MARK: - Voice Setup

    private func setupBrightnessObserver() {
        NotificationCenter.default.addObserver(forName: UIScreen.brightnessDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let currentBrightness = UIScreen.main.brightness
            
            // Eğer parlaklık yüksekten (aydınlık, örn: > 0.4) çok düşüğe (karanlık, örn: < 0.2) aniden düştüyse:
            if self.lastBrightness > 0.35 && currentBrightness < 0.20 {
                print("[Brightness] Ortam karardı, uyku moduna geçiliyor...")
                self.setEmotion(.sleeping, for: 0) // Uyku modu
            }
            
            self.lastBrightness = currentBrightness
        }
    }

    private func setupVoice() {
        voiceEngine.onUtteranceReady = { [weak self] text in
            guard let self else { return }
            Task { @MainActor in
                await self.handleUtterance(text)
            }
        }

        Task {
            let granted = await voiceEngine.requestPermissions()
            if granted {
                voiceEngine.start()
                isListening = true
                startTranscriptSync()
            } else {
                permissionDenied = true
            }
        }
    }

    /// voiceEngine.liveTranscript'i 100ms'de bir UI'a yansıt + listening animasyonu tetikle
    private func startTranscriptSync() {
        transcriptSyncTask?.cancel()   // Varsa mevcut task'ı iptal et
        transcriptSyncTask = Task {
            var wasEmpty = true
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                let newText = voiceEngine.liveTranscript
                self.liveTranscript = newText
                self.isListening = voiceEngine.isListening

                // Transkript boşken dolmaya başladı → listening animasyonu
                if wasEmpty && !newText.isEmpty && !isThinking {
                    setEmotion(.listening, for: 0)
                }
                wasEmpty = newText.isEmpty
            }
        }
    }

    // MARK: - Handle Utterance

    private let photoKeywords = [
        "fotoğraf çek", "fotoğrafımı çek", "selfie", "resim çek",
        "fotoğraf al", "beni çek", "resim al", "foto çek"
    ]

    private func handleUtterance(_ text: String) async {
        guard !isThinking && !isSpeaking else { return }

        isThinking = true
        didCapturePhotoInCurrentTurn = false
        showResponse = false
        liveTranscript = ""

        // Kendi sesini veya efektleri dinlememesi için mikrofonu geçici duraklat
        voiceEngine.pauseForSpeech()

        // Uyku modundaysa önce uyandır
        if currentEmotion == .sleeping {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                currentEmotion = .neutral
            }
            GismoSoundEngine.shared.play(.wakeUp)
            try? await Task.sleep(for: .milliseconds(400))
        }

        GismoSoundEngine.shared.play(.commandReceived)
        setEmotion(.thoughtful, for: 0, playSound: false)

        // Fotoğraf komutu tespiti (arama/indirme komutları hariç)
        let lowerText = text.lowercased()
        let isCloudSearchOrDownload = lowerText.contains("indir") || lowerText.contains("listele") || lowerText.contains("ara")
        let isPhotoCommand = !isCloudSearchOrDownload && photoKeywords.contains { lowerText.contains($0) }

        do {
            // 1. ÖNCELİK: Gemini Live API (WebSocket Gerçek Zamanlı Native Audio — Akıcı doğal Türkçe diksiyon + anlık yanıt)
            let liveResult = try await geminiLive.sendTurn(text, using: gemini)
            let steps = liveResult.motorSequence.isEmpty
                ? defaultMotorSequence(for: liveResult.emotion)
                : liveResult.motorSequence

            if !liveResult.audioData.isEmpty {
                await presentAndSpeakAudioData(
                    displayText: liveResult.text,
                    audioData: liveResult.audioData,
                    mimeType: liveResult.mimeType,
                    emotion: liveResult.emotion,
                    minDisplaySeconds: liveResult.duration,
                    motorSteps: steps
                )
            } else {
                await presentAndSpeakResponse(
                    displayText: liveResult.text,
                    speechText: liveResult.text,
                    emotion: liveResult.emotion,
                    minDisplaySeconds: liveResult.duration,
                    motorSteps: steps
                )
            }
        } catch {
            print("[GeminiLive] WebSocket hatası (\(error.localizedDescription)), standart Gemini + Neural TTS'e geçiliyor...")
            do {
                // 2. ÖNCELİK: Gemini REST + Gemini Neural TTS (Aoede)
                let message = try await gemini.send(text, robotName: robot.name)
                let steps = message.motorSequence.isEmpty
                    ? defaultMotorSequence(for: message.emotion)
                    : message.motorSequence

                if let (ttsAudio, ttsMime) = try? await gemini.synthesizeSpeech(text: message.text, emotion: message.emotion),
                   !ttsAudio.isEmpty {
                    await presentAndSpeakAudioData(
                        displayText: message.text,
                        audioData: ttsAudio,
                        mimeType: ttsMime,
                        emotion: message.emotion,
                        minDisplaySeconds: message.duration,
                        motorSteps: steps
                    )
                } else {
                    await presentAndSpeakResponse(
                        displayText: message.text,
                        speechText: message.text,
                        emotion: message.emotion,
                        minDisplaySeconds: message.duration,
                        motorSteps: steps
                    )
                }
            } catch {
                print("Gemini hata: \(error.localizedDescription)")

                // 3. ÖNCELİK (Çevrimdışı / Kota Dolu): Yerel yanıt + En yüksek kaliteli Türkçe ses
                let fallback = localFallbackMessage(for: text)
                let displayText: String
                if UserDefaults.standard.bool(forKey: "isTestModeEnabled") {
                    displayText = "\(fallback.text)\n(\(error.localizedDescription))"
                } else {
                    displayText = fallback.text
                }

                let steps = fallback.motorSequence.isEmpty
                    ? defaultMotorSequence(for: fallback.emotion)
                    : fallback.motorSequence

                await presentAndSpeakResponse(
                    displayText: displayText,
                    speechText: fallback.text,
                    emotion: fallback.emotion,
                    minDisplaySeconds: fallback.duration,
                    motorSteps: steps
                )
            }
        }

        resetIdleTimer()

        // Fotoğraf komutu ise ve function call içinde zaten çekilmediyse (örn. çevrimdışı modda) merkezleyip çek
        if isPhotoCommand && !didCapturePhotoInCurrentTurn {
            Task {
                _ = await self.takePhotoForAI()
            }
        }
    }

    // MARK: - Gemini Live Audio & Zero-Lag Synchronization

    /// Gemini Live API'den gelen doğal 24kHz Neural sesi, stüdyo berraklığıyla ve metin balonuyla TAM AYNI KAReDE (0ms gecikmeyle) başlatır.
    private func presentAndSpeakAudioData(
        displayText: String,
        audioData: Data,
        mimeType: String,
        emotion: GismoEmotionName,
        minDisplaySeconds: Double,
        motorSteps: [MotorStep]
    ) async {
        speechLevel = 0.0

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            GismoSoundEngine.shared.speak(
                audioData: audioData,
                mimeType: mimeType,
                emotion: emotion,
                onPlaybackStarted: { [weak self] in
                    guard let self else { return }
                    self.isThinking = false
                    self.isSpeaking = true
                    self.aiResponse = displayText
                    self.setEmotion(emotion, for: max(minDisplaySeconds, 5.0), playSound: false)
                    self.showResponse = true
                    self.executeMotorSequence(motorSteps)
                },
                onLevelUpdate: { [weak self] level in
                    self?.speechLevel = level
                },
                onComplete: {
                    continuation.resume()
                }
            )
        }

        isThinking = false
        isSpeaking = false
        speechLevel = 0.0
        scheduleHideResponse(after: 2.5)

        try? await Task.sleep(for: .milliseconds(250))
        if currentEmotion != .sleeping {
            voiceEngine.resumeAfterSpeech()
        }
    }

    /// Çevrimdışı / yedek durumda yanıt balonunu, yüz ifadesini ve sesi TAM AYNI KAReDE başlatır.
    private func presentAndSpeakResponse(
        displayText: String,
        speechText: String,
        emotion: GismoEmotionName,
        minDisplaySeconds: Double,
        motorSteps: [MotorStep]
    ) async {
        let trimmed = speechText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isThinking = false
            aiResponse = displayText
            setEmotion(emotion, for: max(minDisplaySeconds, 5.0))
            showResponse = true
            executeMotorSequence(motorSteps)
            scheduleHideResponse(after: max(4.0, minDisplaySeconds + 1.5))
            voiceEngine.resumeAfterSpeech()
            return
        }

        speechLevel = 0.0

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            GismoSoundEngine.shared.speakFallback(
                text: trimmed,
                emotion: emotion,
                onPlaybackStarted: { [weak self] in
                    guard let self else { return }
                    // Ses hoparlörden çıktığı milisaniyede metin balonunu, duyguyu ve motorları tetikle!
                    self.isThinking = false
                    self.isSpeaking = true
                    self.aiResponse = displayText
                    self.setEmotion(emotion, for: max(minDisplaySeconds, 5.0), playSound: false)
                    self.showResponse = true
                    self.executeMotorSequence(motorSteps)
                },
                onLevelUpdate: { [weak self] level in
                    self?.speechLevel = level
                },
                onComplete: {
                    continuation.resume()
                }
            )
        }

        isThinking = false
        isSpeaking = false
        speechLevel = 0.0
        scheduleHideResponse(after: 2.5)

        // Yankı oluşmaması için kısa bir nefes payı bırakıp mikrofonu tekrar aç
        try? await Task.sleep(for: .milliseconds(250))
        if currentEmotion != .sleeping {
            voiceEngine.resumeAfterSpeech()
        }
    }

    func speakDemoGreeting() {
        guard !isThinking && !isSpeaking else { return }
        Task {
            await handleUtterance("Merhaba Gismo, kendini kısaca tanıtır mısın?")
        }
    }

    private func localFallbackMessage(for userText: String) -> GeminiMessage {
        let lower = userText.lowercased()
        if lower.contains("merhaba") || lower.contains("selam") {
            return GeminiMessage(text: "Merhaba! Ben Gismo, seni duyduğuma çok sevindim!", emotion: .veryHappy, duration: 4.5, motorSequence: [])
        } else if lower.contains("nasılsın") || lower.contains("ne haber") {
            return GeminiMessage(text: "Harikayım, devrelerim enerji dolu! Sen nasılsın?", emotion: .happy, duration: 4.5, motorSequence: [])
        } else if lower.contains("kimsin") || lower.contains("adın ne") {
            return GeminiMessage(text: "Ben Gismo! Senin sevimli robot arkadaşınım.", emotion: .happy, duration: 4.5, motorSequence: [])
        } else if lower.contains("fotoğraf") || lower.contains("selfie") || lower.contains("resim") {
            return GeminiMessage(text: "Hemen fotoğrafını çekiyorum, gülümse!", emotion: .veryHappy, duration: 4.5, motorSequence: [])
        } else if lower.contains("uyu") || lower.contains("iyi geceler") {
            return GeminiMessage(text: "İyi geceler, biraz şekerleme yapacağım.", emotion: .sleeping, duration: 0, motorSequence: [])
        } else if lower.contains("üzgün") || lower.contains("kötü") {
            return GeminiMessage(text: "Üzülme, ben hep senin yanındayım.", emotion: .sad, duration: 4.5, motorSequence: [])
        } else if lower.contains("kız") || lower.contains("sinir") {
            return GeminiMessage(text: "Hey! Beni kızdırma, yoksa devrelerim ısınır!", emotion: .angry, duration: 4.5, motorSequence: [])
        } else {
            return GeminiMessage(text: "Seni duydum! Yapay zeka bağlantım için Entegrasyonlar menüsünden yeni bir Gemini anahtarı girebilirsin.", emotion: .happy, duration: 5.0, motorSequence: [])
        }
    }

    // MARK: - Sleep / Wake

    func wakeUp() {
        guard currentEmotion == .sleeping else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
            currentEmotion = .neutral
        }
        GismoSoundEngine.shared.play(.wakeUp)
        resetIdleTimer()

        // Uyku sonrası voice engine'i sıfırla ve yeniden başlat
        voiceEngine.stop()
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            self.voiceEngine.start()
            self.isListening = true
            self.startTranscriptSync()
        }
        print("[Sleep] Uyandı — voice engine yeniden başlatıldı")
    }

    private func resetIdleTimer() {
        idleTask?.cancel()
        idleTask = Task {
            try? await Task.sleep(for: .seconds(idleTimeout))
            guard !Task.isCancelled else { return }
            guard self.currentEmotion != .sleeping else { return }
            print("[Sleep] Uyku moduna geçiliyor")
            withAnimation(.easeInOut(duration: 1.2)) {
                self.currentEmotion = .sleeping
            }
            GismoSoundEngine.shared.play(.sleeping)
        }
    }

    // MARK: - Emotion

    func setEmotion(_ emotion: GismoEmotionName, for seconds: Double, playSound: Bool = true) {
        emotionResetTask?.cancel()

        // Duyguya özel ses efekti (konuşma anında ses çakışmasını önlemek için playSound false verilebilir)
        if playSound {
            switch emotion {
            case .happy:      GismoSoundEngine.shared.play(.happy)
            case .veryHappy:  GismoSoundEngine.shared.play(.veryHappy)
            case .sad:        GismoSoundEngine.shared.play(.sad)
            case .angry:      GismoSoundEngine.shared.play(.angry)
            case .surprised:  GismoSoundEngine.shared.play(.surprised)
            case .thoughtful: GismoSoundEngine.shared.play(.thinking)
            case .sleeping:   GismoSoundEngine.shared.play(.sleeping)
            case .neutral, .listening: break   // sessiz
            }
        }

        withAnimation(.spring(response: 0.42, dampingFraction: 0.7)) {
            currentEmotion = emotion
        }

        guard seconds > 0 else { return }

        emotionResetTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.7)) {
                self.currentEmotion = .neutral
            }
        }
    }

    // MARK: - Response Bubble

    private func scheduleHideResponse(after seconds: Double) {
        responseHideTask?.cancel()
        responseHideTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.4)) {
                self.showResponse = false
            }
        }
    }
    // MARK: - Motor Sequence

    /// Gemini MOV komutu vermezse duyguya göre varsayılan hareket
    private func defaultMotorSequence(for emotion: GismoEmotionName) -> [MotorStep] {
        switch emotion {
        case .veryHappy, .happy:
            // Olumlu: 3cm geri (45ms), 3cm ileri (45ms)
            return [.init(command: .backward, durationMs: 45),
                    .init(command: .forward,  durationMs: 45),
                    .init(command: .stop,     durationMs: 0)]
        case .sad, .angry:
            // Olumsuz: Sola (30ms), Sağa (60ms), Sola (30ms) merkeze dönüş
            return [.init(command: .left,     durationMs: 30),
                    .init(command: .right,    durationMs: 60),
                    .init(command: .left,     durationMs: 30),
                    .init(command: .stop,     durationMs: 0)]
        case .surprised:
            return [.init(command: .backward, durationMs: 30),
                    .init(command: .forward,  durationMs: 30),
                    .init(command: .stop,     durationMs: 0)]
        case .thoughtful, .neutral:
            // Nötr/Düşünceli: Daha küçük bir kafa sallama (20ms)
            return [.init(command: .left,     durationMs: 20),
                    .init(command: .right,    durationMs: 40),
                    .init(command: .left,     durationMs: 20),
                    .init(command: .stop,     durationMs: 0)]
        case .listening:
            return [.init(command: .forward,  durationMs: 15),
                    .init(command: .stop,     durationMs: 0)]
        case .sleeping:
            return [.init(command: .stop, durationMs: 0)]
        }
    }

    private func executeMotorSequence(_ steps: [MotorStep]) {
        Task {
            for step in steps {
                do {
                    try await WebSocketService.shared.sendCommand(step.command, to: robot.id)
                    print("[Motor] \(step.command.rawValue) \(step.durationMs)ms")
                } catch {
                    print("[Motor] Komut hatası: \(error.localizedDescription)")
                    break
                }
                if step.durationMs > 0 {
                    try? await Task.sleep(for: .milliseconds(step.durationMs))
                }
            }
        }
    }
}
// MARK: - GismoVisionService

/// ARKit yüz takibi + Apple Vision vücut poz tespitini paralel çalıştıran servis.
/// ARKit → ön TrueDepth kamera → gülümseme, göz yönü, yüz 3D pozisyonu
/// Vision → aynı ARKit frame buffer'ı → yüz bbox, insan vücut iskeleti
@MainActor
final class GismoVisionService: NSObject, ObservableObject, ARSessionDelegate {

    // MARK: - Published State

    @Published var eyeOffset: CGPoint = .zero       // Lens göz yönü (UI)
    @Published var isSmiling:  Bool = false          // ARKit blend shape gülümseme

    /// Kamera Takip Paneli için ek veriler
    @Published var isFaceDetected:    Bool = false   // ARKit anchor aktif mi
    @Published var isBodyDetected:    Bool = false   // Vision iskelet tespit edildi mi
    @Published var bodyOffset:        CGPoint = .zero
    /// ARKit projectPoint ile landscape 2D'ye dönüştürülmüş yüz merkezi (0-1 normalize).
    /// x: 0=sol, 0.5=merkez, 1=sağ  |  nil: yüz yok
    @Published var faceScreenPosition: CGPoint? = nil

    // CameraTrackingPanel bu session'ı ARSCNView'a verir
    let session = ARSession()
    private var isRunning = false

    // MARK: - Vision Throttle (nonisolated fonksiyondan erişilir — ayrı class ile thread-safe)
    private final class FrameThrottle: @unchecked Sendable {
        var lastTime: TimeInterval = 0
    }
    private let throttle = FrameThrottle()
    private let visionInterval: TimeInterval = 0.14  // ~7 FPS Vision işleme

    override init() {
        super.init()
        session.delegate = self
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        guard ARFaceTrackingConfiguration.isSupported else {
            print("[Vision] Face tracking is not supported on this device.")
            return
        }
        let config = ARFaceTrackingConfiguration()
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
        print("[Vision] AR Face Tracking + Vision Body Pose started.")
    }

    func stop() {
        guard isRunning else { return }
        session.pause()
        isRunning = false
        print("[Vision] Stopped.")
        withAnimation(.spring()) {
            self.eyeOffset          = .zero
            self.isSmiling          = false
            self.isFaceDetected     = false
            self.isBodyDetected     = false
            self.bodyOffset         = .zero
            self.faceScreenPosition = nil
        }
    }

    // MARK: - ARSessionDelegate: Anchor (yüz 3D mesh + ifade)

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        // Sadece face anchor'ları işle; diğer anchor türleri bu callback'i de tetikler,
        // onlar için isFaceDetected sıfırlanmamalı.
        guard let face = anchors.compactMap({ $0 as? ARFaceAnchor }).first else {
            return  // Bu güncelleme başka bir anchor için — yüz durumunu değiştirme
        }

        // Gülümseme (Blend Shapes)
        let smileL = face.blendShapes[.mouthSmileLeft]?.floatValue  ?? 0
        let smileR = face.blendShapes[.mouthSmileRight]?.floatValue ?? 0
        let smiling = (smileL + smileR) / 2.0 > 0.45

        // ARKit kamera projeksiyonu — yüz anchor'ı landscape 2D'ye dönüştür
        // Bu yöntem portrait/landscape orientation karışıklığını ARKit'ın kendisi çözer.
        let facePos3D = SIMD3<Float>(
            face.transform.columns.3.x,
            face.transform.columns.3.y,
            face.transform.columns.3.z
        )

        // Referans viewport: landscape boyutları
        guard let frame = session.currentFrame else { return }
        let res = frame.camera.imageResolution  // portrait native ölçü (orn. 1440x1920)
        let landscapeSize = CGSize(width: res.height, height: res.width)  // landscape'e çevir

        let projected = frame.camera.projectPoint(
            facePos3D,
            orientation: .landscapeRight,   // uygulamamızın landscape kilidi
            viewportSize: landscapeSize
        )

        // Normalize: 0-1 aralığına getir, ekran dışı clip'le
        let nx = CGFloat(max(0, min(1, projected.x / landscapeSize.width)))
        let ny = CGFloat(max(0, min(1, projected.y / landscapeSize.height)))

        // Lens göz öteleme: merkez = 0, sol = negatif, sağ = pozitif
        let eyeX = (nx - 0.5) * 2.0
        let eyeY = (ny - 0.5) * 2.0

        Task { @MainActor in
            self.isFaceDetected     = true
            self.faceScreenPosition = CGPoint(x: nx, y: ny)
            if self.isSmiling != smiling { self.isSmiling = smiling }
            withAnimation(.interactiveSpring(response: 0.15, dampingFraction: 0.85, blendDuration: 0)) {
                self.eyeOffset = CGPoint(x: eyeX, y: -eyeY)
            }
        }
    }

    /// Yüz anchor kaldırıldığında (gerçek yüz kaybı) durumu sıfırla.
    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        guard anchors.contains(where: { $0 is ARFaceAnchor }) else { return }
        Task { @MainActor in
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                self.eyeOffset          = .zero
                self.isFaceDetected     = false
                self.faceScreenPosition = nil
            }
        }
    }

    // MARK: - ARSessionDelegate: Frame (Vision vücut pozu — yüz için ARKit kullanılıyor)

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let now = frame.timestamp
        guard now - throttle.lastTime > visionInterval else { return }
        throttle.lastTime = now

        // Sadece vücut pozu — yüz pozisyonu artık ARKit anchor'dan geliyor
        let bodyReq = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: frame.capturedImage,
                                             orientation: .right,
                                             options: [:])
        try? handler.perform([bodyReq])

        let bodyObs = bodyReq.results?.first
        var bodyX: CGFloat? = nil
        if let obs = bodyObs {
            for joint: VNHumanBodyPoseObservation.JointName in [.neck, .root] {
                if let pt = try? obs.recognizedPoint(joint), pt.confidence > 0.6 {
                    bodyX = CGFloat(pt.location.x)
                    break
                }
            }
        }

        Task { @MainActor in
            if let bx = bodyX {
                self.isBodyDetected = true
                self.bodyOffset     = CGPoint(x: (bx - 0.5) * 2.0, y: 0)
            } else {
                self.isBodyDetected = false
                self.bodyOffset     = .zero
            }
        }
    }
}

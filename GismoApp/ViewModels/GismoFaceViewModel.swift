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
    @Published var isTrackingEnabled: Bool = false // Kullanıcı "TAKİP" butonuyla açar (FaceTrackingCore ile stabil darbe kontrolü)
    @Published var isRobotBodyOnline: Bool = true  // Robot gövdesi kapandığında false olur → yüz kapanma animasyonuna geçer
    @Published var activeManualInputPrompt: ManualInputPrompt? = nil // 1. deneme başarısız olduğunda açılan yazma kutusu
    @Published var manualInputText: String = ""
    private var lastSpecificInputKind: ManualInputKind? = nil
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

    // MARK: - Yüz Takibi (FaceTrackingCore: medyan filtre + histerezis + oransal darbe + öğrenen kazanç)
    private var trackingCore = FaceTrackingCore()
    private var trackingLoopTask: Task<Void, Never>?
    private var wasTrackingActive = false
    private var isPulsing = false            // Şu an bir motor darbesi yürütülüyor mu
    private var isPhotoCentering = false     // Fotoğraf öncesi ortalama ana döngüyü duraklatır
    private var trackingMotorRunning = false // Takibin gönderdiği son komut hareket mi?

    // Işık / Parlaklık takibi
    private var lastBrightness: CGFloat = UIScreen.main.brightness
    private var isInitialized: Bool = false

    // MARK: - Canlı Gelen Gmail İzleyici (Yüz AI Modu + Gmail Bağlı + Robot Bağlı)
    private var incomingMailTask: Task<Void, Never>?
    private var robotConnectionMonitorTask: Task<Void, Never>?
    private var robotNotificationCancellable: AnyCancellable?
    private var isFaceModeActive: Bool = false
    private var seenMailIds: Set<String> = []
    private var pendingIncomingEmails: [GmailIncomingEmail] = []
    private var mailMonitorStartMs: Int64 = 0
    private var hasBaselineMailSnapshot: Bool = false
    private var lastConversationActivityAt: Date = .distantPast
    private var isAwaitingUserFollowUp: Bool = false

    init(robot: Robot) {
        self.robot = robot
        let testMode = UserDefaults.standard.bool(forKey: "isTestModeEnabled")
        self.isRobotBodyOnline = testMode ? true : robot.isOnline

        let resolvedName: String = {
            let trimmed = robot.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !trimmed.lowercased().hasPrefix("gismo") {
                return trimmed
            }
            return GismoMemoryService.shared.activeRobotName
        }()
        GismoMemoryService.shared.activeRobotNameOverride = resolvedName
        voiceEngine.robotName = resolvedName
        WebSocketService.shared.connect()  // Manuel kontrol gibi komut gönderebilmek için

        robotNotificationCancellable = NotificationCenter.default
            .publisher(for: WebSocketService.robotsDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self else { return }
                if UserDefaults.standard.bool(forKey: "isTestModeEnabled") {
                    self.applyRobotOnlineState(true)
                    return
                }
                if let robots = notification.userInfo?["robots"] as? [Robot],
                   let updated = robots.first(where: { $0.id == self.robot.id }) {
                    self.applyRobotOnlineState(updated.isOnline)
                }
            }
        
        // Gemini'ye kamera yetkisini devret
        gemini.onTakePhoto = { [weak self] in
            guard let self = self else { return nil }
            return await self.takePhotoForAI()
        }
        // "Ne görüyorsun?" gibi analizler için galeriye kaydetmeden görüntü al
        gemini.onCaptureForAnalysis = { [weak self] in
            guard let self = self else { return nil }
            return await self.captureFrameForAnalysis()
        }
        // 1. sesli denemede spesifik isim/numara/adres/dosya başarısız olursa ekranda yazma kutusu aç
        gemini.onRequestManualInput = { [weak self] prompt in
            guard let self = self else { return }
            self.presentManualInput(prompt)
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
        
        // Yüz konumu örnekleri (~60 Hz, throttle YOK) → takip çekirdeğinin medyan filtresine
        trackingObserverTask = vision.$faceScreenPosition
            .sink { [weak self] pos in
                guard let self, let pos else { return }
                self.trackingCore.addSample(x: Double((pos.x - 0.5) * 2.0), at: Self.now())
            }
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

    private func captureFrameForAnalysis() async -> Data? {
        self.vision.stop()
        defer { self.vision.start() }
        let image = await self.camera.takePhoto(saveToGallery: false)
        return image?.jpegData(compressionQuality: 0.7)
    }

    /// Yüz takibi (isTrackingEnabled) açıkken fotoğraf çekilmeden hemen önce kişiyi
    /// kadrajın ortasına getirir. Ana takip ile AYNI çekirdeği (öğrenilmiş kazançla) daha dar
    /// toleransla kullanır; ölçüm her darbeden sonra robot durup görüntü oturunca yapılır.
    private func centerSubjectBeforePhoto() async {
        guard isTrackingEnabled else { return }
        vision.start()

        isPhotoCentering = true
        defer { isPhotoCentering = false }
        // Ana döngüde yarım kalmış bir darbe varsa bitmesini bekle
        while isPulsing { try? await Task.sleep(for: .milliseconds(10)) }

        let normalTuning = trackingCore.tuning
        trackingCore.tuning.startBand = 0.14
        trackingCore.tuning.stopBand = 0.08
        trackingCore.tuning.maxSearchPulses = 0
        defer {
            trackingCore.tuning = normalTuning
            trackingCore.reset()
        }

        let deadline = Self.now() + 3.0
        var waitedForFace = false
        while Self.now() < deadline {
            switch trackingCore.decide(now: Self.now()) {
            case .pulse(let direction, let ms, let x):
                await runTrackingPulse(direction: direction, ms: ms, xBefore: x)
            case .wait(let seconds):
                if trackingCore.lastDecisionCentered {
                    print("[PhotoCenter] Subject ortalandı.")
                    stopTrackingMotorIfNeeded()
                    return
                }
                try? await Task.sleep(for: .seconds(min(max(seconds, 0.01), 0.2)))
            case .faceLost:
                // Kamera yeni başladıysa ilk karelere kısa süre tanı
                if !waitedForFace {
                    waitedForFace = true
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                print("[PhotoCenter] Kadrajda yüz yok, mevcut açıdan çekiliyor.")
                stopTrackingMotorIfNeeded()
                return
            }
        }
        stopTrackingMotorIfNeeded()
    }

    // MARK: - Yüz Takibi Döngüsü

    private static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    private var canTrack: Bool {
        isRobotBodyOnline && isTrackingEnabled && !isThinking && !showResponse && currentEmotion != .sleeping && !isPhotoCentering
    }

    private func startTrackingLoop() {
        guard trackingLoopTask == nil else { return }
        trackingLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = await self?.trackingStep() else { return }
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay), tolerance: .milliseconds(2))
                }
            }
        }
    }

    private func stopTrackingLoop() {
        trackingLoopTask?.cancel()
        trackingLoopTask = nil
        stopTrackingMotorIfNeeded()
        trackingCore.reset()
        wasTrackingActive = false
    }

    /// Tek karar adımı; bir sonraki adıma kadar beklenecek süreyi döndürür.
    private func trackingStep() async -> Double {
        if isPhotoCentering { return 0.05 }   // Ortalama rutini motoru yönetiyor

        guard canTrack else {
            if wasTrackingActive {
                stopTrackingMotorIfNeeded()
                trackingCore.reset()
                wasTrackingActive = false
            }
            return 0.1
        }
        if !wasTrackingActive {
            trackingCore.reset()
            wasTrackingActive = true
        }

        switch trackingCore.decide(now: Self.now()) {
        case .wait(let seconds):
            stopTrackingMotorIfNeeded()
            return min(max(seconds, 0.01), 0.2)
        case .faceLost:
            stopTrackingMotorIfNeeded()
            return 0.05
        case .pulse(let direction, let ms, let x):
            await runTrackingPulse(direction: direction, ms: ms, xBefore: x)
            return 0
        }
    }

    /// Hareket → tam süre bekle → DUR. Komutlar ack beklenmeden sıralı gönderilir;
    /// görev iptal edilse bile DUR mutlaka gönderilir.
    private func runTrackingPulse(direction: Int, ms: Double, xBefore: Double) async {
        isPulsing = true
        defer { isPulsing = false }

        // x > 0 → yüz kadrajın sağında → robot sola döner (kamera montajına göre)
        sendTrackingMotor(direction > 0 ? .left : .right)
        try? await Task.sleep(for: .milliseconds(Int(ms.rounded())), tolerance: .milliseconds(1))
        sendTrackingMotor(.stop)

        // Robota ulaşma gecikmesi ≈ ölçülen RTT; jitter için pay bırak
        let latency = WebSocketService.shared.commandRoundTrip * 1.3 + 0.03
        trackingCore.didFinishPulse(direction: direction, ms: ms, xBefore: xBefore,
                                    at: Self.now(), latency: latency)
    }

    private func sendTrackingMotor(_ cmd: RobotCommand) {
        currentTrackingCommand = cmd
        trackingMotorRunning = cmd != .stop
        WebSocketService.shared.sendRealtimeCommand(cmd, to: robot.id)
    }

    /// Yalnızca takip robotu hareket ettirdiyse DUR gönderir (duygu hareketlerini bölmez, spam yok)
    private func stopTrackingMotorIfNeeded() {
        if trackingMotorRunning {
            sendTrackingMotor(.stop)
        } else if currentTrackingCommand != .stop {
            currentTrackingCommand = .stop
        }
    }

    // MARK: - Lifecycle

    func onAppear() {
        isFaceModeActive = true
        if !isInitialized {
            currentEmotion = .neutral
            gemini.resetHistory()
            if isRobotBodyOnline {
                GismoSoundEngine.shared.play(.startup)
            }
            setupBrightnessObserver()
            isInitialized = true
        }
        Task {
            await GismoMemoryService.shared.syncFromServer()
        }
        geminiLive.prewarm(apiKey: gemini.apiKey)
        setupVoice()
        vision.start() // Yüz takibini başlat
        startTrackingLoop()
        startRobotConnectionMonitor()
        startIncomingMailMonitor()
    }

    func onDisappear() {
        isFaceModeActive = false
        stopIncomingMailMonitor()
        stopRobotConnectionMonitor()
        NotificationCenter.default.removeObserver(self, name: UIScreen.brightnessDidChangeNotification, object: nil)
        GismoSoundEngine.shared.stopSpeech()
        geminiLive.disconnect()
        isSpeaking = false
        speechLevel = 0
        voiceEngine.stop()
        vision.stop() // Yüz takibini durdur
        stopTrackingLoop()
        emotionResetTask?.cancel()
        responseHideTask?.cancel()
        transcriptSyncTask?.cancel()
        idleTask?.cancel()
    }

    // MARK: - Robot Gövdesi Bağlantı İzleme ve Kapanma / Açılma Yönetimi

    private func startRobotConnectionMonitor() {
        robotConnectionMonitorTask?.cancel()
        robotConnectionMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if UserDefaults.standard.bool(forKey: "isTestModeEnabled") {
                    self.applyRobotOnlineState(true)
                } else {
                    WebSocketService.shared.connect()
                    if let robots = try? await WebSocketService.shared.fetchRobots(),
                       let match = robots.first(where: { $0.id == self.robot.id }) {
                        self.applyRobotOnlineState(match.isOnline)
                    } else {
                        let connected = WebSocketService.shared.isRobotConnected(
                            self.robot.id,
                            fallbackOnline: self.isRobotBodyOnline
                        )
                        self.applyRobotOnlineState(connected)
                    }
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func stopRobotConnectionMonitor() {
        robotConnectionMonitorTask?.cancel()
        robotConnectionMonitorTask = nil
    }

    private func applyRobotOnlineState(_ online: Bool) {
        guard online != isRobotBodyOnline else { return }
        isRobotBodyOnline = online

        if !online {
            print("[RobotBody] Robot gövdesi kapandı / bağlantı koptu — yüz kapatılıyor.")
            GismoSoundEngine.shared.stopSpeech()
            GismoSoundEngine.shared.play(.sleeping)
            isThinking = false
            isSpeaking = false
            speechLevel = 0
            showResponse = false
            liveTranscript = ""
            stopTrackingMotorIfNeeded()
            voiceEngine.pauseForSpeech()
            idleTask?.cancel()
        } else {
            print("[RobotBody] Robot gövdesi tekrar bağlandı — yüz yeniden açılıyor!")
            GismoSoundEngine.shared.play(.startup)
            setEmotion(.happy, for: 3.0, playSound: false)
            resetIdleTimer()
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                if self.isFaceModeActive && self.isRobotBodyOnline {
                    self.voiceEngine.resumeAfterSpeech()
                }
            }
        }
    }

    // MARK: - Canlı Gelen E-posta İzleme ve Sesli Özetleme

    /// Koşullar:
    /// 1) Yüz AI modu açık (`isFaceModeActive` & `AIKeyStore.hasKey`)
    /// 2) Gmail hesabı bağlı (`GoogleAuthService.shared.isConnected`)
    /// 3) Uygulama ön planda çalışır durumda ve robota bağlı (`UIApplication.shared.applicationState == .active` & `WebSocketService.shared.isRobotConnected`)
    private func startIncomingMailMonitor() {
        incomingMailTask?.cancel()
        if mailMonitorStartMs == 0 {
            mailMonitorStartMs = Int64(Date().timeIntervalSince1970 * 1000)
        }

        incomingMailTask = Task { [weak self] in
            // Robot çevrimiçi bilgisini tazele
            _ = try? await WebSocketService.shared.fetchRobots()

            while !Task.isCancelled {
                guard let self else { return }

                let faceOpen = self.isFaceModeActive && AIKeyStore.hasKey
                let gmailConnected = GoogleAuthService.shared.isConnected && GoogleAuthService.shared.currentUser != nil
                let appActive = UIApplication.shared.applicationState == .active
                let robotConnected = WebSocketService.shared.isRobotConnected(self.robot.id, fallbackOnline: self.robot.isOnline)
                let notificationsEnabled = GmailService.shared.isIncomingMailAnnouncementEnabled

                if faceOpen && gmailConnected && appActive && robotConnected && notificationsEnabled {
                    if !self.hasBaselineMailSnapshot {
                        if let initialIds = try? await GmailService.shared.fetchRecentInboxIds(maxResults: 6) {
                            self.seenMailIds.formUnion(initialIds)
                            self.mailMonitorStartMs = Int64(Date().timeIntervalSince1970 * 1000)
                            self.hasBaselineMailSnapshot = true
                            print("[MailMonitor] Başlangıç kutusu kaydedildi (\(initialIds.count) mail). Yeni mailler bekleniyor...")
                        }
                    } else {
                        // Konuşma esnasında da yeni mailleri arka planda kuyruğa al, ancak SADECE konuşma tamamen bittiğinde seslendir
                        if let newMail = try? await GmailService.shared.checkForNewIncomingEmail(
                            seenIds: self.seenMailIds,
                            sinceMs: self.mailMonitorStartMs
                        ) {
                            self.seenMailIds.insert(newMail.id)
                            if !self.pendingIncomingEmails.contains(where: { $0.id == newMail.id }) {
                                self.pendingIncomingEmails.append(newMail)
                            }
                            print("[MailMonitor] Yeni mail kuyruğa alındı: \(newMail.senderName) - \(newMail.subject)")
                        }

                        if self.isSafeToAnnounceIncomingEmail, !self.pendingIncomingEmails.isEmpty {
                            let nextMail = self.pendingIncomingEmails.removeFirst()
                            await self.announceIncomingEmail(nextMail)
                        }
                    }
                } else if !gmailConnected || !notificationsEnabled {
                    self.hasBaselineMailSnapshot = false
                    self.pendingIncomingEmails.removeAll()
                    if !gmailConnected {
                        self.seenMailIds.removeAll()
                    }
                }

                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func stopIncomingMailMonitor() {
        incomingMailTask?.cancel()
        incomingMailTask = nil
    }

    /// Kullanıcı veya robot konuşurken, düşünürken, manuel giriş kutusu açıkken veya soru-cevap bekleme süresindeyken mail anonsu ARAYA GİRMEZ.
    private var isSafeToAnnounceIncomingEmail: Bool {
        guard isFaceModeActive && isRobotBodyOnline else { return false }
        guard !isThinking && !isSpeaking else { return false }
        guard activeManualInputPrompt == nil else { return false }
        guard voiceEngine.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        // Son konuşma/etkileşim üzerinden güvenli bekleme süresi (soru sorulduysa 16 sn, normal konuşma bittiyse 8 sn sessizlik)
        let requiredSilence: TimeInterval = isAwaitingUserFollowUp ? 16.0 : 8.0
        let elapsedSinceLastActivity = Date().timeIntervalSince(lastConversationActivityAt)
        return elapsedSinceLastActivity >= requiredSilence
    }

    /// Yeni gelen e-postayı doğal ve çok kısa bir şekilde seslendirip özetler, ardından kullanıcının aksiyon almasını ("yanıtla", "bir şey yapma" vb.) sağlar.
    private func announceIncomingEmail(_ mail: GmailIncomingEmail) async {
        guard isSafeToAnnounceIncomingEmail else {
            // O sırada kullanıcı konuşmaya başladıysa maili kaybetme, kuyruğun başına geri koy
            if !pendingIncomingEmails.contains(where: { $0.id == mail.id }) {
                pendingIncomingEmails.insert(mail, at: 0)
            }
            return
        }

        gemini.lastIncomingEmail = mail
        isThinking = true
        showResponse = false
        liveTranscript = ""
        lastConversationActivityAt = Date()
        isAwaitingUserFollowUp = true

        voiceEngine.pauseForSpeech()

        if currentEmotion == .sleeping {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                currentEmotion = .neutral
            }
            GismoSoundEngine.shared.play(.wakeUp)
            try? await Task.sleep(for: .milliseconds(350))
        }

        GismoSoundEngine.shared.play(.surprised)
        setEmotion(.surprised, for: 0, playSound: false)

        let notificationPrompt = """
        [SİSTEM BİLDİRİMİ - YENİ E-POSTA GELDİ]
        Az önce kullanıcının Gmail hesabına yeni bir mail düştü:
        Gönderen: \(mail.senderName) <\(mail.senderEmail)>
        Konu: \(mail.subject)
        İçerik: \(String(mail.bodyText.prefix(800)))

        Lütfen şimdi kullanıcıya bir mail geldiğini söyle, kimden geldiğini ve neyle ilgili olduğunu ÇOK KISA, samimi ve doğal bir Türkçe ile (1-2 cümlede) özetle ve "Yanıtlamamı ister misin?" diye sor.
        """

        do {
            let liveResult = try await geminiLive.sendTurn(notificationPrompt, using: gemini)
            gemini.recordTurnInHistory(userText: notificationPrompt, modelText: liveResult.text)
            let steps = liveResult.motorSequence.isEmpty
                ? defaultMotorSequence(for: .surprised)
                : liveResult.motorSequence

            if !liveResult.audioData.isEmpty {
                await presentAndSpeakAudioData(
                    displayText: liveResult.text,
                    audioData: liveResult.audioData,
                    mimeType: liveResult.mimeType,
                    emotion: .happy,
                    minDisplaySeconds: liveResult.duration,
                    motorSteps: steps
                )
            } else {
                await presentAndSpeakResponse(
                    displayText: liveResult.text,
                    speechText: liveResult.text,
                    emotion: .happy,
                    minDisplaySeconds: liveResult.duration,
                    motorSteps: steps
                )
            }
        } catch {
            do {
                let message = try await gemini.send(notificationPrompt, robotName: robot.name, includeTools: false)
                let steps = message.motorSequence.isEmpty
                    ? defaultMotorSequence(for: .surprised)
                    : message.motorSequence

                if let (ttsAudio, ttsMime) = try? await gemini.synthesizeSpeech(text: message.text, emotion: .happy),
                   !ttsAudio.isEmpty {
                    await presentAndSpeakAudioData(
                        displayText: message.text,
                        audioData: ttsAudio,
                        mimeType: ttsMime,
                        emotion: .happy,
                        minDisplaySeconds: message.duration,
                        motorSteps: steps
                    )
                } else {
                    await presentAndSpeakResponse(
                        displayText: message.text,
                        speechText: message.text,
                        emotion: .happy,
                        minDisplaySeconds: message.duration,
                        motorSteps: steps
                    )
                }
            } catch {
                let fallbackSummary = "Hey, bir mail geldi! \(mail.senderName) sana '\(mail.subject)' konulu bir e-posta göndermiş. Yanıtlamamı ister misin?"
                gemini.recordTurnInHistory(userText: notificationPrompt, modelText: fallbackSummary)
                await presentAndSpeakResponse(
                    displayText: fallbackSummary,
                    speechText: fallbackSummary,
                    emotion: .happy,
                    minDisplaySeconds: 5.0,
                    motorSteps: defaultMotorSequence(for: .surprised)
                )
            }
        }

        resetIdleTimer()
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

                if !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.lastConversationActivityAt = Date()
                }

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

    private func handleUtterance(_ text: String, isFromManualInput: Bool = false) async {
        guard isRobotBodyOnline && !isThinking && !isSpeaking else { return }

        isThinking = true
        lastConversationActivityAt = Date()
        isAwaitingUserFollowUp = false
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

        // Fotoğraf komutu tespiti ("son çektiğin fotoyu yükle", "galerideki son fotoyu gönder" gibi komutlarda tekrar fotoğraf ÇEKMEMELİDİR)
        let lowerText = text.lowercased()
        let existingPhotoKeywords = [
            "son çektiğin", "son cektiğin", "son çekilen", "az önce çektiğin",
            "az önceki", "son foto", "son resmi", "çektiğin foto", "çektiğin resmi",
            "galerideki", "galerimdeki", "bu fotoğrafı", "o fotoğrafı"
        ]
        let refersToExistingPhoto = existingPhotoKeywords.contains { lowerText.contains($0) }
        gemini.preferExistingPhotoInCurrentTurn = refersToExistingPhoto

        let isCloudSearchOrDownload = lowerText.contains("indir") || lowerText.contains("listele") || lowerText.contains("ara") || lowerText.contains("yükle") || lowerText.contains("yukle") || lowerText.contains("mail")
        let isPhotoCommand = !isCloudSearchOrDownload && !refersToExistingPhoto && photoKeywords.contains { lowerText.contains($0) }

        var assistantReplyForMemory = ""

        do {
            // 1. ÖNCELİK: Gemini Live API (WebSocket Gerçek Zamanlı Native Audio — Akıcı doğal Türkçe diksiyon + anlık yanıt)
            let liveResult = try await geminiLive.sendTurn(text, using: gemini)
            assistantReplyForMemory = liveResult.text
            gemini.recordTurnInHistory(userText: text, modelText: liveResult.text)
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
                assistantReplyForMemory = message.text
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
                assistantReplyForMemory = fallback.text
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

        // 1. sesli denemede spesifik girdi (e-posta, Drive dosyası, kişi/numara) başarısız olduysa veya yanlış anlaşıldıysa yazma kutusunu aç
        if !isFromManualInput {
            evaluateSpecificInputFailureAfterTurn(userText: text, assistantReply: assistantReplyForMemory)
        }

        // Arka planda konuşmayı analiz et (sahibi, tanışılan kişiler, konuşulan konular veya "bunu aklında tut" notlarını kalıcı hafızaya kaydet)
        let currentKey = gemini.apiKey
        let replySnapshot = assistantReplyForMemory
        Task {
            await GismoMemoryService.shared.analyzeAndMemorizeTurn(
                userText: text,
                assistantText: replySnapshot,
                apiKey: currentKey
            )
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
        lastConversationActivityAt = Date()
        isAwaitingUserFollowUp = displayText.contains("?")
        scheduleHideResponse(after: 2.5)

        try? await Task.sleep(for: .milliseconds(250))
        if currentEmotion != .sleeping && activeManualInputPrompt == nil {
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
            lastConversationActivityAt = Date()
            isAwaitingUserFollowUp = displayText.contains("?")
            setEmotion(emotion, for: max(minDisplaySeconds, 5.0))
            showResponse = true
            executeMotorSequence(motorSteps)
            scheduleHideResponse(after: max(4.0, minDisplaySeconds + 1.5))
            if activeManualInputPrompt == nil {
                voiceEngine.resumeAfterSpeech()
            }
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
        lastConversationActivityAt = Date()
        isAwaitingUserFollowUp = displayText.contains("?")
        scheduleHideResponse(after: 2.5)

        // Yankı oluşmaması için kısa bir nefes payı bırakıp mikrofonu tekrar aç
        try? await Task.sleep(for: .milliseconds(250))
        if currentEmotion != .sleeping && activeManualInputPrompt == nil {
            voiceEngine.resumeAfterSpeech()
        }
    }

    // MARK: - Manuel Metin Giriş Kutusu (1. Sesli Deneme Başarısız Olduğunda)

    func presentManualInput(_ prompt: ManualInputPrompt) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            activeManualInputPrompt = prompt
            manualInputText = prompt.initialText
        }
        voiceEngine.pauseForSpeech()

        // Eğer Drive dosya seçimi için açıldıysa ve henüz öneri listesi boşsa, son Drive dosyalarını yükle
        if prompt.kind == .driveFile && prompt.suggestions.isEmpty {
            Task {
                if let files = try? await GoogleDriveService.shared.fetchDriveFiles(query: "", pageSize: 5), !files.isEmpty {
                    let names = files.map { $0.name }
                    await MainActor.run {
                        if let current = self.activeManualInputPrompt, current.id == prompt.id {
                            self.activeManualInputPrompt = ManualInputPrompt(
                                kind: current.kind,
                                title: current.title,
                                subtitle: current.subtitle,
                                placeholder: current.placeholder,
                                initialText: current.initialText,
                                suggestions: names
                            )
                        }
                    }
                }
            }
        }
    }

    func openManualInputFromHUD() {
        let kind = lastSpecificInputKind ?? .general
        let suggestions = kind == .driveFile ? GoogleDriveService.shared.lastSuggestedFiles.map { $0.name } : []
        presentManualInput(
            ManualInputPrompt(
                kind: kind,
                title: kind.defaultTitle,
                subtitle: "Sesle anlaşılmayan e-posta, Drive dosya adı, numara veya komutunuzu el ile yazabilirsiniz:",
                placeholder: kind.defaultPlaceholder,
                initialText: "",
                suggestions: suggestions
            )
        )
    }

    func dismissManualInput() {
        withAnimation(.easeOut(duration: 0.22)) {
            activeManualInputPrompt = nil
            manualInputText = ""
        }
        if isRobotBodyOnline && currentEmotion != .sleeping && !isThinking && !isSpeaking {
            voiceEngine.resumeAfterSpeech()
        }
    }

    func submitManualInput(_ customText: String? = nil) {
        let value = (customText ?? manualInputText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }

        let kind = activeManualInputPrompt?.kind ?? .general
        withAnimation(.easeOut(duration: 0.22)) {
            activeManualInputPrompt = nil
            manualInputText = ""
        }
        lastSpecificInputKind = nil

        let contextualMessage: String
        switch kind {
        case .email:
            let cleanEmail = GeminiService.normalizeEmailAddress(value)
            contextualMessage = "Kullanıcı e-posta adresini metin kutusundan el ile tam olarak şöyle girdi: \(cleanEmail). Lütfen bu e-posta adresini birebir kullanarak işlemi sürdür."
        case .driveFile:
            contextualMessage = "Kullanıcı Google Drive dosya adını metin kutusundan el ile tam olarak şöyle girdi: '\(value)'. Lütfen Drive'da bu dosyayı bulup işlemi sürdür."
        case .phoneOrName:
            contextualMessage = "Kullanıcı kişi adını veya telefon numarasını metin kutusundan el ile tam olarak şöyle girdi: '\(value)'. Lütfen bu bilgiyi kullanarak işlemi sürdür."
        case .general:
            contextualMessage = value
        }

        Task {
            await self.handleUtterance(contextualMessage, isFromManualInput: true)
        }
    }

    /// 1. sesli denemede spesifik isim/numara/adres/dosya komutunun başarısız olup olmadığını veya kullanıcı tarafından reddedildiğini tespit eder.
    private func evaluateSpecificInputFailureAfterTurn(userText: String, assistantReply: String) {
        // Eğer araç çağrısı sırasında zaten kutu açıldıysa tekrar işlem yapma
        guard activeManualInputPrompt == nil else {
            lastSpecificInputKind = nil
            return
        }

        let uLower = userText.lowercased()
        let aLower = assistantReply.lowercased()

        // İşlem başarıyla tamamlandıysa sıfırla
        let successMarkers = ["başarıyla gönderildi", "oluşturuldu", "kaydedildi", "tamamdır, bir şey yapmıyorum"]
        if successMarkers.contains(where: { aLower.contains($0) }) {
            lastSpecificInputKind = nil
            return
        }

        // Konuşmanın hangi spesifik girdi türüyle ilgili olduğunu bul
        var detectedKind: ManualInputKind? = nil
        if uLower.contains("mail") || uLower.contains("e-posta") || uLower.contains("eposta") || uLower.contains("@") || aLower.contains("e-posta") || aLower.contains("mail adres") {
            detectedKind = .email
        } else if uLower.contains("drive") || uLower.contains("dosya") || uLower.contains("belge") || uLower.contains("pdf") || uLower.contains("tablo") || aLower.contains("drive") || aLower.contains("dosya") {
            detectedKind = .driveFile
        } else if uLower.contains("sms") || uLower.contains("mesaj at") || uLower.contains("rehber") || uLower.contains("numara") || aLower.contains("rehber") || aLower.contains("telefon numara") {
            detectedKind = .phoneOrName
        }

        let effectiveKind = detectedKind ?? lastSpecificInputKind

        // 1) Kullanıcı Gismo'nun 1. denemede algıladığı adresi/dosyayı/kişiyi reddettiyse ("hayır yanlış", "o adres değil", "yanlış anladın", "hiçbiri değil")
        let userRejectionMarkers = [
            "yanlış", "yanlis", "hayır o değil", "hayır değil", "o adres değil",
            "o dosya değil", "öyle değil", "hatalı", "anlamadın", "anlayamadın",
            "hiçbiri", "yazayım", "yazarak", "el ile"
        ]
        if let kind = effectiveKind, userRejectionMarkers.contains(where: { uLower.contains($0) }) {
            let suggestions = kind == .driveFile ? GoogleDriveService.shared.lastSuggestedFiles.map { $0.name } : []
            presentManualInput(
                ManualInputPrompt(
                    kind: kind,
                    title: kind.defaultTitle,
                    subtitle: "Sesli algılamada karışıklık oldu. Lütfen doğru bilgiyi aşağıya el ile yazın:",
                    placeholder: kind.defaultPlaceholder,
                    initialText: "",
                    suggestions: suggestions
                )
            )
            lastSpecificInputKind = nil
            return
        }

        // 2) Kullanıcı 1. denemede spesifik bir girdi söyledi ama Gismo "bulamadım / anlayamadım / tekrar söyler misin / geçerli bir adres değil" dediyse
        let assistantFailureMarkers = [
            "anlayamadım", "anlaşılamadı", "bulamadım", "bulunamadı",
            "tekrar söyler misin", "geçerli bir e-posta", "adresi tam",
            "rehberde yok", "eşleşen dosya yok"
        ]
        if let kind = effectiveKind, assistantFailureMarkers.contains(where: { aLower.contains($0) }) {
            let suggestions = kind == .driveFile ? GoogleDriveService.shared.lastSuggestedFiles.map { $0.name } : []
            presentManualInput(
                ManualInputPrompt(
                    kind: kind,
                    title: kind.defaultTitle,
                    subtitle: "1. sesli denemede bilgi tam eşleşmedi. Aşağıdaki kutuya el ile yazabilirsiniz:",
                    placeholder: kind.defaultPlaceholder,
                    initialText: "",
                    suggestions: suggestions
                )
            )
            lastSpecificInputKind = nil
            return
        }

        // 3) Önceki turda zaten aynı spesifik girdi sorulmuştu (1. deneme yapıldı) ve Gismo hâlâ "hangi adrese / hangi dosyayı / kime" diye tekrar soruyorsa
        let stillAskingMarkers = [
            "hangi adres", "hangi e-posta", "e-posta adresi nedir",
            "hangi dosya", "dosyanın adı", "kime göndermek", "numarası nedir"
        ]
        if let prevKind = lastSpecificInputKind,
           stillAskingMarkers.contains(where: { aLower.contains($0) }) {
            let suggestions = prevKind == .driveFile ? GoogleDriveService.shared.lastSuggestedFiles.map { $0.name } : []
            presentManualInput(
                ManualInputPrompt(
                    kind: prevKind,
                    title: prevKind.defaultTitle,
                    subtitle: "Sesle algılanamadı. Lütfen bilgiyi aşağıya el ile girin:",
                    placeholder: prevKind.defaultPlaceholder,
                    initialText: "",
                    suggestions: suggestions
                )
            )
            lastSpecificInputKind = nil
            return
        }

        lastSpecificInputKind = detectedKind
    }

    var activeRobotName: String {
        GismoMemoryService.shared.activeRobotName
    }

    func speakDemoGreeting() {
        guard isRobotBodyOnline && !isThinking && !isSpeaking else { return }
        let rName = activeRobotName
        Task {
            await handleUtterance("Merhaba \(rName), kendini kısaca tanıtır mısın?")
        }
    }

    private func localFallbackMessage(for userText: String) -> GeminiMessage {
        let lower = userText.lowercased()
        let rName = activeRobotName
        if lower.contains("merhaba") || lower.contains("selam") {
            return GeminiMessage(text: "Merhaba! Ben \(rName), seni duyduğuma çok sevindim!", emotion: .veryHappy, duration: 4.5, motorSequence: [])
        } else if lower.contains("nasılsın") || lower.contains("ne haber") {
            return GeminiMessage(text: "Harikayım, devrelerim enerji dolu! Sen nasılsın?", emotion: .happy, duration: 4.5, motorSequence: [])
        } else if lower.contains("kimsin") || lower.contains("adın ne") {
            return GeminiMessage(text: "Ben \(rName)! Senin sevimli robot arkadaşınım.", emotion: .happy, duration: 4.5, motorSequence: [])
        } else if lower.contains("fotoğraf") || lower.contains("selfie") || lower.contains("resim") {
            return GeminiMessage(text: "Hemen fotoğrafını çekiyorum, gülümse!", emotion: .veryHappy, duration: 4.5, motorSequence: [])
        } else if lower.contains("uyu") || lower.contains("iyi geceler") {
            return GeminiMessage(text: "İyi geceler, biraz şekerleme yapacağım.", emotion: .sleeping, duration: 0, motorSequence: [])
        } else if lower.contains("aklında tut") || lower.contains("aklinda tut") || lower.contains("unutma") || lower.contains("hafızana kaydet") {
            return GeminiMessage(text: "Tamamdır, bunu kalıcı hafızama kaydettim, hiç unutmayacağım!", emotion: .veryHappy, duration: 4.5, motorSequence: [])
        } else if lower.contains("üzgün") || lower.contains("kötü") {
            return GeminiMessage(text: "Üzülme, ben hep senin yanındayım.", emotion: .sad, duration: 4.5, motorSequence: [])
        } else if lower.contains("kız") || lower.contains("sinir") {
            return GeminiMessage(text: "Hey! Beni kızdırma, yoksa devrelerim ısınır!", emotion: .angry, duration: 4.5, motorSequence: [])
        } else {
            return GeminiMessage(text: "Seni duydum! Yapay zeka bağlantım için Entegrasyonlar menüsünden Yapay Zeka Anahtarını kontrol edebilirsin.", emotion: .happy, duration: 5.0, motorSequence: [])
        }
    }

    // MARK: - Sleep / Wake

    func wakeUp() {
        guard isRobotBodyOnline, currentEmotion == .sleeping else { return }
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

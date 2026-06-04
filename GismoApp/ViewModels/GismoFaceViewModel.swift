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
    @Published var showResponse: Bool = false
    @Published var permissionDenied: Bool = false
    @Published var isTrackingEnabled: Bool = false // Fiziksel motor yüz takibi dengesizlik nedeniyle devre dışı bırakıldı

    private let voiceEngine = GismoVoiceEngine()
    private let gemini      = GeminiService()
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
        
        // Gülümseme algılandığında tepki ver
        smileObserverTask = vision.$isSmiling.sink { [weak self] isSmiling in
            guard let self = self else { return }
            if isSmiling && self.currentEmotion != .veryHappy && !self.isThinking {
                self.setEmotion(.happy, for: 3)
            }
        }
        
        // Motor ile Akıllı Takip — faceScreenPosition değişince state machine'ı tetikle
        trackingObserverTask = vision.$faceScreenPosition
            .throttle(for: .milliseconds(200), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.handleSmartTracking() }
    }
    
    private func takePhotoForAI() async -> Data? {
        self.vision.stop()
        defer { self.vision.start() }
        let image = await self.camera.takePhoto()
        return image?.jpegData(compressionQuality: 0.8)
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
        setupVoice()
        vision.start() // Yüz takibini başlat
    }

    func onDisappear() {
        NotificationCenter.default.removeObserver(self, name: UIScreen.brightnessDidChangeNotification, object: nil)
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
        guard !isThinking else { return }

        isThinking = true
        showResponse = false
        liveTranscript = ""

        // Uyku modundaysa önce uyandır
        if currentEmotion == .sleeping {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                currentEmotion = .neutral
            }
            GismoSoundEngine.shared.play(.wakeUp)
            try? await Task.sleep(for: .milliseconds(400))
        }

        GismoSoundEngine.shared.play(.commandReceived)
        setEmotion(.thoughtful, for: 0)

        // Fotoğraf komutu tespiti
        let lowerText = text.lowercased()
        let isPhotoCommand = photoKeywords.contains { lowerText.contains($0) }

        do {
            let message = try await gemini.send(text, robotName: robot.name)
            aiResponse = message.text
            setEmotion(message.emotion, for: message.duration)
            showResponse = true
            scheduleHideResponse(after: max(4.0, message.duration + 1.5))
            let steps = message.motorSequence.isEmpty
                ? defaultMotorSequence(for: message.emotion)
                : message.motorSequence
            print("[Motor] Sekans (\(steps.count) adım): \(steps.map { "\($0.command.rawValue),\($0.durationMs)" }.joined(separator: ";"))")
            executeMotorSequence(steps)
        } catch {
            print("Gemini hata: \(error.localizedDescription)")
            setEmotion(.neutral, for: 0)
            
            // Test modundaysak hatayı ekrana yazdır
            if UserDefaults.standard.bool(forKey: "isTestModeEnabled") {
                aiResponse = "TEST MODU HATASI: \(error.localizedDescription)"
                showResponse = true
                scheduleHideResponse(after: 6.0)
            }
        }

        isThinking = false
        resetIdleTimer()

        // Fotoğraf komutu ise Gemini'den yanıt geldikten sonra çek
        if isPhotoCommand {
            Task {
                try? await Task.sleep(for: .milliseconds(800))
                self.vision.stop() // Kamerayı AVCapture'a bırak
                await self.camera.takePhoto()
                self.vision.start() // Göz temasını geri başlat
            }
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

    func setEmotion(_ emotion: GismoEmotionName, for seconds: Double) {
        emotionResetTask?.cancel()

        // Duyguya özel ses efekti (neutral ve listening sessiz — çok sık tetikleniyor)
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

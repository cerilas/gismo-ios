import SwiftUI
import Combine
import ARKit

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
    private var currentTrackingCommand: RobotCommand = .stop
    private let idleTimeout: Double = 60  // saniye
    
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
        
        // Motor ile Yüz Takibi (Sessizlik anlarında)
        trackingObserverTask = vision.$eyeOffset
            // Saniyede ~6 kere kontrol et (aşırı mesaj göndermemek için)
            .throttle(for: .milliseconds(150), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] offset in
                self?.handleFaceTracking(offset: offset)
            }
    }
    
    private func takePhotoForAI() async -> Data? {
        self.vision.stop()
        defer { self.vision.start() }
        let image = await self.camera.takePhoto()
        return image?.jpegData(compressionQuality: 0.8)
    }
    
    private func handleFaceTracking(offset: CGPoint) {
        // Sadece AI düşünmüyorsa, yanıt göstermiyorsa ve takip modu açıksa izleme yap
        guard !isThinking && !showResponse && currentEmotion != .sleeping && isTrackingEnabled else {
            if currentTrackingCommand != .stop {
                sendTrackingCommand(.stop)
            }
            return
        }
        
        let xPos = offset.x // -1.0 (sol) to 1.0 (sağ)
        let deadzone: CGFloat = 0.20 // Yüzün ortada sayılacağı eşik
        
        var desiredCommand: RobotCommand = .stop
        
        if xPos > deadzone {
            desiredCommand = .right
        } else if xPos < -deadzone {
            desiredCommand = .left
        }
        
        if currentTrackingCommand != desiredCommand {
            sendTrackingCommand(desiredCommand)
        }
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

@MainActor
final class GismoVisionService: NSObject, ObservableObject, ARSessionDelegate {
    
    @Published var eyeOffset: CGPoint = .zero
    @Published var isSmiling: Bool = false
    
    private let session = ARSession()
    private var isRunning = false
    
    override init() {
        super.init()
        session.delegate = self
    }
    
    // MARK: - Public
    
    func start() {
        guard !isRunning else { return }
        guard ARFaceTrackingConfiguration.isSupported else {
            print("[Vision] Face tracking is not supported on this device.")
            return
        }
        
        let config = ARFaceTrackingConfiguration()
        // We only care about tracking the user's face, we don't need high res video
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
        print("[Vision] AR Face Tracking started.")
    }
    
    func stop() {
        guard isRunning else { return }
        session.pause()
        isRunning = false
        print("[Vision] AR Face Tracking stopped.")
        
        // Reset gözleri ortaya al
        withAnimation(.spring()) {
            self.eyeOffset = .zero
            self.isSmiling = false
        }
    }
    
    // MARK: - ARSessionDelegate
    
    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let faceAnchor = anchors.compactMap({ $0 as? ARFaceAnchor }).first else {
            // Yüz görünmüyorsa gözleri ortaya al
            Task { @MainActor in
                if self.eyeOffset != .zero {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                        self.eyeOffset = .zero
                    }
                }
            }
            return
        }
        
        // 1. Gülümseme Tespiti (Blend Shapes)
        let smileLeft = faceAnchor.blendShapes[.mouthSmileLeft]?.floatValue ?? 0
        let smileRight = faceAnchor.blendShapes[.mouthSmileRight]?.floatValue ?? 0
        let currentSmile = (smileLeft + smileRight) / 2.0
        let isSmilingNow = currentSmile > 0.45 // Eşik değeri
        
        // 2. Göz Takibi / Kafa Yönü (Head Translation)
        // Kullanıcının kafası ekranda nereye gidiyorsa, Gismo'nun gözleri de ona bakmalı
        let transform = faceAnchor.transform
        let xPos = transform.columns.3.x // - (sol) to + (sağ) metre cinsinden
        let yPos = transform.columns.3.y // - (aşağı) to + (yukarı) metre cinsinden
        
        // Değerleri normalize et: X ve Y eksenlerinde ne kadar kayacak (-1.0 ile 1.0 arası)
        // Genelde xPos -0.15 ile +0.15 arasında değişir (kamera karşısındayken)
        let normalizedX = CGFloat(max(-1, min(1, xPos * 6.0)))
        let normalizedY = CGFloat(max(-1, min(1, yPos * 6.0)))
        
        Task { @MainActor in
            // Gülümseme durumu değiştiyse güncelle
            if self.isSmiling != isSmilingNow {
                self.isSmiling = isSmilingNow
            }
            
            // Göz bebeklerinin hedef konumu
            // Kullanıcı sağa giderse (xPos +), Gismo da sağa (x +) bakmalı
            // Kullanıcı yukarı çıkarsa (yPos +), Gismo da yukarı (y - UI koordinatlarında) bakmalı
            let targetOffset = CGPoint(x: normalizedX, y: -normalizedY)
            
            // Yumuşak bir geçişle gözleri takip ettir
            withAnimation(.interactiveSpring(response: 0.15, dampingFraction: 0.85, blendDuration: 0)) {
                self.eyeOffset = targetOffset
            }
        }
    }
}

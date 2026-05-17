import Speech
import AVFoundation

@MainActor
final class GismoVoiceEngine: ObservableObject {

    @Published var isListening = false
    @Published var liveTranscript = ""

    var robotName: String = "gismo"
    var onUtteranceReady: ((String) -> Void)?

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "tr-TR"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var silenceTimer: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var isAudioEngineRunning = false
    private let silenceSeconds: Double = 1.5

    // MARK: - Permissions

    func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        let mic = await withCheckedContinuation { cont in
            AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
        }
        return speech && mic
    }

    // MARK: - Public

    func start() {
        guard !isListening else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("[Voice] AVAudioSession hatası: \(error)")
            return
        }
        
        startAudioEngineAndRecognition()
    }

    func stop() {
        restartTask?.cancel()
        restartTask = nil
        teardownAll()
        try? AVAudioSession.sharedInstance().setActive(false,
                                                       options: .notifyOthersOnDeactivation)
    }

    // MARK: - Recognition Core

    private func startAudioEngineAndRecognition() {
        teardownAll()

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            print("[Voice] Recognizer kullanılamıyor")
            return
        }

        let node = audioEngine.inputNode
        let recordingFormat = node.outputFormat(forBus: 0)
        
        // Tap kurmadan önce temizle
        node.removeTap(onBus: 0)
        
        node.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }
        
        do {
            if !audioEngine.isRunning {
                audioEngine.prepare()
                try audioEngine.start()
            }
            isAudioEngineRunning = true
            isListening = true
            
            startRecognitionTask()
            
        } catch {
            print("[Voice] AudioEngine hatası: \(error)")
            node.removeTap(onBus: 0)
            isAudioEngineRunning = false
            return
        }
    }
    
    private var currentTaskID = UUID()

    private func startRecognitionTask() {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else { return }
        
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request
        
        let taskID = UUID()
        self.currentTaskID = taskID
        
        let currentTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            // Yalnızca aktif task ise işlem yap (eski taskların sonsuz döngü yaratmasını engeller)
            guard self.currentTaskID == taskID else { return }
            
            if let result {
                let text = result.bestTranscription.formattedString
                Task { @MainActor in
                    self.liveTranscript = text
                    self.armSilenceTimer()
                }
            }
            
            if error != nil || result?.isFinal == true {
                guard self.isListening else { return }
                
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(200))
                    if self.isListening {
                        self.startAudioEngineAndRecognition()
                    }
                }
            }
        }
        recognitionTask = currentTask
        
        // 55 sn limiti aşmamak için düzenli yenile
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(50))
            guard let self, !Task.isCancelled, self.isListening else { return }
            self.startAudioEngineAndRecognition()
        }
    }

    private func teardownAll() {
        silenceTimer?.cancel()
        silenceTimer = nil
        restartTask?.cancel()
        restartTask = nil
        
        if isAudioEngineRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            isAudioEngineRunning = false
        }
        
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isListening = false
    }

    // MARK: - Silence Detection

    private func armSilenceTimer() {
        silenceTimer?.cancel()
        silenceTimer = Task {
            try? await Task.sleep(for: .seconds(self.silenceSeconds))
            guard !Task.isCancelled else { return }
            let text = self.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            
            self.liveTranscript = ""
            print("[Voice] Utterance: \(text)")
            self.onUtteranceReady?(text)
            
            // Konuşma algılandıktan sonra tam bir şekilde yenile
            self.startAudioEngineAndRecognition()
        }
    }
}

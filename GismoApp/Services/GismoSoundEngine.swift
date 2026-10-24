import AVFoundation
import CoreGraphics

// MARK: - GismoSoundEngine
// Sesleri ve konuşmaları bellekte WAV formatına çevirip AVAudioPlayer ile çalar.
// AVAudioEngine kullanılmaz, böylece mikrofon (GismoVoiceEngine) ile ASLA çakışmaz.

final class GismoSoundEngine: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {

    static let shared = GismoSoundEngine()

    private var sfxPlayer: AVAudioPlayer?
    private var speechPlayer: AVAudioPlayer?
    private let fallbackSynthesizer = AVSpeechSynthesizer()
    private let sampleRate: Double = 44100
    private let sfxQueue = DispatchQueue(label: "com.gismo.soundengine.sfx", qos: .userInitiated)
    private var sfxCache: [GismoSound: Data] = [:]
    private var lastSFXPlayTime: TimeInterval = 0

    private var meterTimer: Timer?
    private var onSpeechStarted: (@MainActor () -> Void)?
    private var onSpeechLevelUpdate: (@MainActor (CGFloat) -> Void)?
    private var onSpeechComplete: (@MainActor () -> Void)?

    private override init() {
        super.init()
        fallbackSynthesizer.delegate = self
    }

    // MARK: - Sound Effects (SFX)

    func stopSFX() {
        if Thread.isMainThread {
            sfxPlayer?.stop()
            sfxPlayer = nil
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.sfxPlayer?.stop()
                self?.sfxPlayer = nil
            }
        }
    }

    func play(_ sound: GismoSound) {
        let now = ProcessInfo.processInfo.systemUptime
        // Arka arkaya tetiklenen melodilerin üst üste binip takılı kalmasını önle (debounce)
        guard now - lastSFXPlayTime >= 0.35 else { return }
        lastSFXPlayTime = now

        sfxQueue.async { [weak self] in
            guard let self else { return }
            let wavData: Data
            if let cached = self.sfxCache[sound] {
                wavData = cached
            } else {
                let samples = sound.makeSamples(sampleRate: self.sampleRate)
                let generated = self.makeWAVData(from: samples, sampleRate: Int(self.sampleRate))
                self.sfxCache[sound] = generated
                wavData = generated
            }

            DispatchQueue.main.async {
                // Konuşma aktifken efekt sesi çalma
                guard self.speechPlayer?.isPlaying != true && !self.fallbackSynthesizer.isSpeaking else { return }
                do {
                    self.sfxPlayer?.stop()
                    self.sfxPlayer = nil
                    let player = try AVAudioPlayer(data: wavData)
                    player.numberOfLoops = 0
                    player.volume = 0.75
                    player.prepareToPlay()
                    self.sfxPlayer = player
                    player.play()
                } catch {
                    print("[SoundEngine] SFX oynatma hatası: \(error)")
                }
            }
        }
    }

    // MARK: - Cute Robotic Speech Playback (Gemini TTS + DSP)

    func speak(
        audioData: Data,
        mimeType: String,
        emotion: GismoEmotionName,
        onPlaybackStarted: (@MainActor () -> Void)? = nil,
        onLevelUpdate: @escaping @MainActor (CGFloat) -> Void,
        onComplete: @escaping @MainActor () -> Void
    ) {
        stopSpeech()
        self.onSpeechStarted = onPlaybackStarted
        self.onSpeechLevelUpdate = onLevelUpdate
        self.onSpeechComplete = onComplete

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let (rawSamples, inputSampleRate) = self.decodeAudioToFloatSamples(data: audioData, mimeType: mimeType)
            let trimmedSamples = self.trimSilence(rawSamples)
            guard !trimmedSamples.isEmpty else {
                Task { @MainActor in
                    onPlaybackStarted?()
                    onLevelUpdate(0)
                    onComplete()
                }
                return
            }

            let roboticSamples = self.processCuteRobotVoice(
                samples: trimmedSamples,
                sampleRate: Double(inputSampleRate),
                emotion: emotion
            )
            let wavData = self.makeWAVData(from: roboticSamples, sampleRate: inputSampleRate)

            DispatchQueue.main.async {
                self.playProcessedSpeechWAV(wavData)
            }
        }
    }

    // MARK: - Instant On-Device Technological Robotic Speech (AVSpeechSynthesizer + DSP)

    func speakFallback(
        text: String,
        emotion: GismoEmotionName,
        onPlaybackStarted: (@MainActor () -> Void)? = nil,
        onLevelUpdate: @escaping @MainActor (CGFloat) -> Void,
        onComplete: @escaping @MainActor () -> Void
    ) {
        stopSpeech()
        self.onSpeechStarted = onPlaybackStarted
        self.onSpeechLevelUpdate = onLevelUpdate
        self.onSpeechComplete = onComplete

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestTurkishVoice()
        utterance.rate = 0.50
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0.0
        utterance.postUtteranceDelay = 0.0

        var accumulatedSamples: [Float] = []
        var detectedSampleRate: Int = 22050
        var didFinishSynthesis = false

        fallbackSynthesizer.write(utterance) { [weak self] buffer in
            guard let self else { return }
            guard let pcmBuffer = buffer as? AVAudioPCMBuffer else { return }

            if pcmBuffer.frameLength == 0 {
                guard !didFinishSynthesis else { return }
                didFinishSynthesis = true

                if !accumulatedSamples.isEmpty {
                    let samplesCopy = self.trimSilence(accumulatedSamples)
                    let rateCopy = detectedSampleRate
                    DispatchQueue.global(qos: .userInitiated).async {
                        let roboticSamples = self.processCuteRobotVoice(
                            samples: samplesCopy.isEmpty ? accumulatedSamples : samplesCopy,
                            sampleRate: Double(rateCopy),
                            emotion: emotion
                        )
                        let wavData = self.makeWAVData(from: roboticSamples, sampleRate: rateCopy)
                        DispatchQueue.main.async {
                            self.playProcessedSpeechWAV(wavData)
                        }
                    }
                } else {
                    // Cihaz buffer çıktısı desteklemiyorsa doğrudan robotik tonda konuş
                    DispatchQueue.main.async {
                        let startCallback = self.onSpeechStarted
                        self.onSpeechStarted = nil
                        if let startCallback {
                            Task { @MainActor in startCallback() }
                        }

                        let directUtterance = AVSpeechUtterance(string: text)
                        directUtterance.voice = Self.bestTurkishVoice()
                        directUtterance.pitchMultiplier = 1.0
                        directUtterance.rate = 0.50
                        directUtterance.preUtteranceDelay = 0.0
                        self.fallbackSynthesizer.speak(directUtterance)
                        self.startSimulatedMetering()
                    }
                }
                return
            }

            detectedSampleRate = Int(pcmBuffer.format.sampleRate)
            let frameLength = Int(pcmBuffer.frameLength)

            if let floatData = pcmBuffer.floatChannelData {
                let channel = floatData[0]
                for i in 0..<frameLength {
                    accumulatedSamples.append(channel[i])
                }
            } else if let int16Data = pcmBuffer.int16ChannelData {
                let channel = int16Data[0]
                for i in 0..<frameLength {
                    accumulatedSamples.append(Float(channel[i]) / 32768.0)
                }
            }
        }
    }

    /// Baştaki ve sondaki ölü sessizlik örneklerini (dead air) kırpar — konuşma 0. milisaniyede başlar
    private func trimSilence(_ samples: [Float], threshold: Float = 0.008) -> [Float] {
        guard !samples.isEmpty else { return [] }
        var firstIndex = 0
        while firstIndex < samples.count && abs(samples[firstIndex]) < threshold {
            firstIndex += 1
        }
        guard firstIndex < samples.count else { return samples }

        var lastIndex = samples.count - 1
        while lastIndex > firstIndex && abs(samples[lastIndex]) < threshold {
            lastIndex -= 1
        }
        return Array(samples[firstIndex...lastIndex])
    }

    func stopSpeech() {
        meterTimer?.invalidate()
        meterTimer = nil
        sfxPlayer?.stop()
        sfxPlayer = nil
        if speechPlayer?.isPlaying == true {
            speechPlayer?.stop()
        }
        speechPlayer = nil
        if fallbackSynthesizer.isSpeaking {
            fallbackSynthesizer.stopSpeaking(at: .immediate)
        }
        let levelCallback = onSpeechLevelUpdate
        onSpeechStarted = nil
        onSpeechLevelUpdate = nil
        onSpeechComplete = nil
        if let levelCallback {
            Task { @MainActor in levelCallback(0) }
        }
    }

    private func playProcessedSpeechWAV(_ wavData: Data) {
        do {
            sfxPlayer?.stop()
            sfxPlayer = nil
            try? AVAudioSession.sharedInstance().setCategory(
                .playAndRecord,
                mode: .default,
                options: [.duckOthers, .defaultToSpeaker]
            )
            let player = try AVAudioPlayer(data: wavData)
            player.delegate = self
            player.isMeteringEnabled = true
            player.volume = 1.0
            player.prepareToPlay()
            self.speechPlayer = player

            let startCallback = self.onSpeechStarted
            self.onSpeechStarted = nil
            if let startCallback {
                Task { @MainActor in startCallback() }
            }

            player.play()
            startMetering()
        } catch {
            print("[SoundEngine] Konuşma oynatma hatası: \(error)")
            let startCallback = self.onSpeechStarted
            self.onSpeechStarted = nil
            if let startCallback {
                Task { @MainActor in startCallback() }
            }
            finishSpeechPlayback()
        }
    }

    // MARK: - Lip-Sync Metering

    private func startMetering() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, let player = self.speechPlayer, player.isPlaying else { return }
            player.updateMeters()
            let power = player.averagePower(forChannel: 0) // -160 ... 0 dB
            let minDb: Float = -42.0
            let normalized = max(0.0, min(1.0, (power - minDb) / (-minDb)))
            let curved = CGFloat(pow(normalized, 0.75))
            if let callback = self.onSpeechLevelUpdate {
                Task { @MainActor in callback(curved) }
            }
        }
    }

    private func startSimulatedMetering() {
        meterTimer?.invalidate()
        var phase: Double = 0
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            phase += 0.45
            let level = CGFloat(0.25 + 0.65 * abs(sin(phase)) * abs(cos(phase * 0.6)))
            if let callback = self.onSpeechLevelUpdate {
                Task { @MainActor in callback(level) }
            }
        }
    }

    private func finishSpeechPlayback() {
        meterTimer?.invalidate()
        meterTimer = nil
        speechPlayer = nil
        let levelCallback = onSpeechLevelUpdate
        let completeCallback = onSpeechComplete
        onSpeechLevelUpdate = nil
        onSpeechComplete = nil
        Task { @MainActor in
            levelCallback?(0)
            completeCallback?()
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if player === speechPlayer {
            finishSpeechPlayback()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        if speechPlayer == nil {
            finishSpeechPlayback()
        }
    }

    /// Cihazda yüklü en yüksek kaliteli (Premium / Enhanced) Türkçe sesi seçer
    private static func bestTurkishVoice() -> AVSpeechSynthesisVoice? {
        let trVoices = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.lowercased().hasPrefix("tr")
        }
        if let best = trVoices.max(by: { $0.quality.rawValue < $1.quality.rawValue }) {
            return best
        }
        return AVSpeechSynthesisVoice(language: "tr-TR")
    }

    // MARK: - Cute Robot Voice DSP (Gemini sesi korunur, üzerine hafif filtre dokunuşları)
    // TTS modeli değişmez. CuteRobotVoiceDSP; hafif perde/formant yükseltme (süre korunur),
    // küçük-hoparlör EQ'su, düşük karışımlı metalik rezonans ve ring-mod parıltısı uygular.
    // Duyguya göre perde ve robotiklik dozu çok az değişir; karakter sesi her zaman aynı kalır.

    /// Robot ses efektini tamamen kapatmak için UserDefaults "gismoCuteRobotVoiceEnabled" = false
    private var isCuteRobotVoiceEnabled: Bool {
        UserDefaults.standard.object(forKey: "gismoCuteRobotVoiceEnabled") as? Bool ?? true
    }

    private func processCuteRobotVoice(
        samples: [Float],
        sampleRate: Double,
        emotion: GismoEmotionName
    ) -> [Float] {
        guard samples.count > 64 else { return samples }
        var style = Self.cuteRobotStyle(for: emotion)
        if !isCuteRobotVoiceEnabled {
            // Efekt kapalı: yalnızca temiz EQ + normalize (perde/robotik tını yok)
            style.pitchSemitones = 0
            style.combMix = 0
            style.ringMix = 0
            style.highPassHz = 105
        }
        return CuteRobotVoiceDSP.process(samples: samples, sampleRate: sampleRate, style: style)
    }

    private static func cuteRobotStyle(for emotion: GismoEmotionName) -> CuteRobotVoiceDSP.Style {
        var style = CuteRobotVoiceDSP.Style.default
        switch emotion {
        case .happy:
            style.pitchSemitones = 3.4
        case .veryHappy, .surprised:
            style.pitchSemitones = 3.8
            style.ringMix = 0.09
        case .sad, .sleeping:
            style.pitchSemitones = 2.2
            style.combMix = 0.16
            style.ringMix = 0.06
        case .angry:
            style.pitchSemitones = 2.4
            style.combFeedback = 0.42
            style.combMix = 0.24
        case .thoughtful:
            style.pitchSemitones = 2.7
        case .neutral, .listening:
            break
        }
        return style
    }

    // MARK: - Decode WAV or Raw 16-bit PCM

    private func decodeAudioToFloatSamples(data: Data, mimeType: String) -> (samples: [Float], sampleRate: Int) {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return ([], 24000) }

        // 1. RIFF WAV başlığı kontrolü
        if bytes.count > 44,
           bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46 { // "RIFF"
            let sr = Int(UInt32(bytes[24]) |
                         (UInt32(bytes[25]) << 8) |
                         (UInt32(bytes[26]) << 16) |
                         (UInt32(bytes[27]) << 24))
            let validSampleRate = (8000...96000).contains(sr) ? sr : 24000

            // "data" alt-chunk başlangıcını bul
            var pcmStart = 44
            for idx in 12..<(bytes.count - 8) {
                if bytes[idx] == 0x64, bytes[idx + 1] == 0x61, bytes[idx + 2] == 0x74, bytes[idx + 3] == 0x61 {
                    pcmStart = idx + 8
                    break
                }
            }
            let sampleCount = (bytes.count - pcmStart) / 2
            guard sampleCount > 0 else { return ([], validSampleRate) }
            var samples = [Float](repeating: 0, count: sampleCount)
            for i in 0..<sampleCount {
                let offset = pcmStart + i * 2
                let low = UInt16(bytes[offset])
                let high = UInt16(bytes[offset + 1]) << 8
                let intSample = Int16(bitPattern: low | high)
                samples[i] = Float(intSample) / 32768.0
            }
            return (samples, validSampleRate)
        }

        // 2. Ham 16-bit signed little-endian PCM (örn: audio/L16;codec=pcm;rate=24000)
        var parsedRate = 24000
        if let rateRange = mimeType.range(of: "rate=") {
            let tail = mimeType[rateRange.upperBound...]
            let digits = tail.prefix { $0.isNumber }
            if let r = Int(digits), (8000...96000).contains(r) {
                parsedRate = r
            }
        }

        let sampleCount = bytes.count / 2
        var samples = [Float](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            let low = UInt16(bytes[i * 2])
            let high = UInt16(bytes[i * 2 + 1]) << 8
            let intSample = Int16(bitPattern: low | high)
            samples[i] = Float(intSample) / 32768.0
        }
        return (samples, parsedRate)
    }

    // MARK: - WAV Generator

    private func makeWAVData(from samples: [Float], sampleRate: Int) -> Data {
        let byteRate = sampleRate * 2 // 16-bit mono
        var data = Data()
        
        // RIFF chunk
        data.append("RIFF".data(using: .utf8)!)
        data.append(contentsOf: withUnsafeBytes(of: Int32(36 + samples.count * 2)) { Array($0) })
        data.append("WAVE".data(using: .utf8)!)
        
        // fmt subchunk
        data.append("fmt ".data(using: .utf8)!)
        data.append(contentsOf: withUnsafeBytes(of: Int32(16)) { Array($0) }) // Subchunk1Size (16 for PCM)
        data.append(contentsOf: withUnsafeBytes(of: Int16(1)) { Array($0) })  // AudioFormat (1 for PCM)
        data.append(contentsOf: withUnsafeBytes(of: Int16(1)) { Array($0) })  // NumChannels (1)
        data.append(contentsOf: withUnsafeBytes(of: Int32(sampleRate)) { Array($0) }) // SampleRate
        data.append(contentsOf: withUnsafeBytes(of: Int32(byteRate)) { Array($0) })   // ByteRate
        data.append(contentsOf: withUnsafeBytes(of: Int16(2)) { Array($0) })  // BlockAlign
        data.append(contentsOf: withUnsafeBytes(of: Int16(16)) { Array($0) }) // BitsPerSample
        
        // data subchunk
        data.append("data".data(using: .utf8)!)
        data.append(contentsOf: withUnsafeBytes(of: Int32(samples.count * 2)) { Array($0) })
        
        // PCM 16-bit verisi
        var pcmData = Data(capacity: samples.count * 2)
        for sample in samples {
            // Clipping koruması
            let clamped = max(-1.0, min(1.0, sample))
            let intSample = Int16(clamped * 32767.0)
            pcmData.append(contentsOf: withUnsafeBytes(of: intSample) { Array($0) })
        }
        data.append(pcmData)
        return data
    }

    // MARK: - Sample Helpers

    static func makeTone(sampleRate: Double,
                         frequency: Double, duration: Double,
                         volume: Float = 0.30,
                         attack: Double = 0.01, release: Double = 0.08,
                         vibrato: Double = 0, vibratoRate: Double = 6,
                         bitCrush: Int = 0) -> [Float] {

        let count = Int(duration * sampleRate)
        var samples = [Float](repeating: 0, count: count)
        let attackN  = Int(attack  * sampleRate)
        let releaseN = Int(release * sampleRate)
        let releaseStart = count - releaseN

        for i in 0..<count {
            let t = Double(i) / sampleRate
            let freq = frequency + (vibrato > 0 ? sin(2 * .pi * vibratoRate * t) * vibrato : 0)
            var s = sin(2 * .pi * freq * t) * Double(volume)
            if i < attackN           { s *= Double(i) / max(1, Double(attackN)) }
            else if i >= releaseStart { s *= Double(count - i) / max(1, Double(releaseN)) }
            if bitCrush > 0 {
                let steps = pow(2.0, Double(bitCrush))
                s = round(s * steps) / steps
            }
            samples[i] = Float(s)
        }
        return samples
    }

    static func makeSquare(sampleRate: Double,
                           frequency: Double, duration: Double,
                           volume: Float = 0.18) -> [Float] {
        let count = Int(duration * sampleRate)
        var samples = [Float](repeating: 0, count: count)
        let releaseN = Int(0.05 * sampleRate)
        let releaseStart = count - releaseN
        for i in 0..<count {
            let t = Double(i) / sampleRate
            var s = (sin(2 * .pi * frequency * t) > 0 ? 1.0 : -1.0) * Double(volume)
            if i >= releaseStart { s *= Double(count - i) / max(1, Double(releaseN)) }
            samples[i] = Float(s)
        }
        return samples
    }

    /// Birden fazla kanalı birleştirir
    static func mix(tracks: [(samples: [Float], offsetSec: Double)],
                    sampleRate: Double) -> [Float] {
        let totalFrames = tracks.map { Int($0.offsetSec * sampleRate) + $0.samples.count }.max() ?? 0
        var out = [Float](repeating: 0, count: totalFrames)
        
        for track in tracks {
            let offset = Int(track.offsetSec * sampleRate)
            for (i, s) in track.samples.enumerated() {
                let idx = offset + i
                if idx < totalFrames { out[idx] += s }
            }
        }
        // Peak normalize
        let peak = out.map { abs($0) }.max() ?? 0
        if peak > 0.001 {
            let gain = Float(0.92) / peak
            for i in 0..<totalFrames { out[i] *= gain }
        }
        return out
    }

    static func single(_ samples: [Float], sampleRate: Double) -> [Float] {
        return mix(tracks: [(samples, 0)], sampleRate: sampleRate)
    }
}

// MARK: - GismoSound

enum GismoSound: Hashable {
    case startup, listening, thinking, happy, veryHappy
    case sad, angry, surprised, sleeping, wakeUp, neutral, commandReceived

    func makeSamples(sampleRate: Double) -> [Float] {
        let E = GismoSoundEngine.self
        switch self {

        case .startup:
            let n: [(Double, Double, Double)] = [(523,0.10,0), (659,0.10,0.08), (784,0.10,0.16), (1047,0.18,0.24)]
            return E.mix(tracks: n.map { (E.makeTone(sampleRate:sampleRate,frequency:$0.0,duration:$0.1,volume:0.65,attack:0.005,release:0.05,bitCrush:5), $0.2) }, sampleRate:sampleRate)

        case .listening:
            return E.single(E.makeTone(sampleRate:sampleRate,frequency:880,duration:0.12,volume:0.60,attack:0.005,release:0.07), sampleRate:sampleRate)

        case .thinking:
            let n: [(Double, Double)] = [(440,0), (494,0.14), (523,0.28)]
            return E.mix(tracks: n.map { (E.makeTone(sampleRate:sampleRate,frequency:$0.0,duration:0.10,volume:0.55,attack:0.01,release:0.05), $0.1) }, sampleRate:sampleRate)

        case .happy:
            let n: [(Double, Double)] = [(523,0), (659,0.10), (784,0.20)]
            return E.mix(tracks: n.map { (E.makeTone(sampleRate:sampleRate,frequency:$0.0,duration:0.12,volume:0.60,attack:0.005,release:0.06,bitCrush:4), $0.1) }, sampleRate:sampleRate)

        case .veryHappy:
            let n: [(Double, Double)] = [(523,0),(659,0.08),(784,0.16),(1047,0.24),(784,0.32),(1047,0.40)]
            return E.mix(tracks: n.map { (E.makeTone(sampleRate:sampleRate,frequency:$0.0,duration:0.09,volume:0.65,attack:0.004,release:0.04,bitCrush:4), $0.1) }, sampleRate:sampleRate)

        case .sad:
            let n: [(Double, Double)] = [(440,0),(392,0.17),(349,0.34),(294,0.51)]
            return E.mix(tracks: n.map { (E.makeTone(sampleRate:sampleRate,frequency:$0.0,duration:0.20,volume:0.55,attack:0.02,release:0.12,vibrato:3,vibratoRate:5), $0.1) }, sampleRate:sampleRate)

        case .angry:
            return E.mix(tracks: [
                (E.makeSquare(sampleRate:sampleRate,frequency:120,duration:0.35,volume:0.55), 0),
                (E.makeSquare(sampleRate:sampleRate,frequency:90,duration:0.25,volume:0.45), 0.28)
            ], sampleRate:sampleRate)

        case .surprised:
            let n: [(Double, Double)] = [(392,0),(523,0.06),(784,0.12),(1047,0.18)]
            return E.mix(tracks: n.map { (E.makeTone(sampleRate:sampleRate,frequency:$0.0,duration:0.07,volume:0.60,attack:0.003,release:0.03,bitCrush:4), $0.1) }, sampleRate:sampleRate)

        case .sleeping:
            let n: [(Double, Float, Double)] = [(440,0.50,0),(392,0.38,0.28),(349,0.26,0.56)]
            return E.mix(tracks: n.map { (E.makeTone(sampleRate:sampleRate,frequency:$0.0,duration:0.30,volume:$0.1,attack:0.05,release:0.20,vibrato:2,vibratoRate:4), $0.2) }, sampleRate:sampleRate)

        case .wakeUp:
            let n: [(Double, Double)] = [(294,0),(392,0.09),(523,0.18),(784,0.27)]
            return E.mix(tracks: n.map { (E.makeTone(sampleRate:sampleRate,frequency:$0.0,duration:0.10,volume:0.60,attack:0.01,release:0.05,bitCrush:4), $0.1) }, sampleRate:sampleRate)

        case .neutral:
            return E.single(E.makeTone(sampleRate:sampleRate,frequency:523,duration:0.08,volume:0.50,attack:0.005,release:0.04), sampleRate:sampleRate)

        case .commandReceived:
            return E.mix(tracks: [
                (E.makeTone(sampleRate:sampleRate,frequency:784,duration:0.07,volume:0.58,attack:0.004,release:0.03), 0),
                (E.makeTone(sampleRate:sampleRate,frequency:1047,duration:0.07,volume:0.58,attack:0.004,release:0.03), 0.09)
            ], sampleRate:sampleRate)
        }
    }
}

import AVFoundation

// MARK: - GismoSoundEngine
// Sesleri bellekte WAV formatına çevirip AVAudioPlayer ile çalar.
// AVAudioEngine kullanılmaz, böylece mikrofon (GismoVoiceEngine) ile ASLA çakışmaz.

final class GismoSoundEngine {

    static let shared = GismoSoundEngine()

    private var player: AVAudioPlayer?
    private let sampleRate: Double = 44100

    private init() {
        // AVAudioPlayer için özel bir hazırlığa gerek yok
    }

    // MARK: - Public

    func play(_ sound: GismoSound) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let samples = sound.makeSamples(sampleRate: self.sampleRate)
            let wavData = self.makeWAVData(from: samples, sampleRate: Int(self.sampleRate))
            
            DispatchQueue.main.async {
                do {
                    // Önceki sesi kes ve yenisini çal
                    self.player?.stop()
                    self.player = try AVAudioPlayer(data: wavData)
                    self.player?.prepareToPlay()
                    self.player?.play()
                } catch {
                    print("[SoundEngine] Oynatma hatası: \(error)")
                }
            }
        }
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

enum GismoSound {
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

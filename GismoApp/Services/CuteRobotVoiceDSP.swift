import Foundation
import Accelerate

// MARK: - Cute Robot Voice DSP
//
// TTS modelini (Gemini "Aoede") HİÇ değiştirmeden, çıkan sesin üzerine çok hafif
// filtre dokunuşları uygulayarak "sevimli robot" karakteri kazandırır.
//
// Zincir:
//   1. Pitch + formant yukarı kaydırma (süre korunur)  → minik / sevimli gövde
//   2. High-pass (alt basları kes)                       → küçük robot hoparlörü hissi
//   3. Presence / air boost                              → net diksiyon, parlak ton
//   4. Kısa metalik tüp rezonansı (feedback comb)        → hafif robotik tını
//   5. Çok hafif ring-mod karışımı                       → dijital "vızıltı" parıltısı
//   6. Yumuşak limiter + peak normalize
//
// Tüm efektler düşük karışım oranlarında tutulur; kelimeler ve doğal tonlama bozulmaz.
// Bu dosya yalnızca Foundation + Accelerate kullanır (bağımsız test edilebilir).

enum CuteRobotVoiceDSP {

    struct Style {
        /// Yarım ton cinsinden perde kaydırma (+ değer = daha minik / sevimli)
        var pitchSemitones: Double = 3.0
        /// Alt kesim frekansı (Hz) — yükseldikçe ses "küçük hoparlör" gibi olur
        var highPassHz: Double = 150
        /// Presence boost oranı (0 = kapalı)
        var presenceAmount: Float = 0.28
        /// Metalik tüp rezonansı gecikmesi (ms) — rezonans temel frekansı = 1000 / ms
        var combDelayMs: Double = 3.3
        /// Rezonans geri beslemesi (0..<1) — yükseldikçe daha metalik
        var combFeedback: Float = 0.38
        /// Rezonansın kuru sese karışım oranı (0..1)
        var combMix: Float = 0.20
        /// Ring-mod taşıyıcı frekansı (Hz)
        var ringHz: Double = 170
        /// Ring-mod karışım oranı (0..1) — çok düşük tutulmalı
        var ringMix: Float = 0.08

        static let `default` = Style()
    }

    static func process(samples input: [Float], sampleRate: Double, style: Style = .default) -> [Float] {
        guard input.count > 256, sampleRate > 0 else { return input }

        // 1. Perde + formant kaydırma (süre korunur)
        var x = pitchShift(input, sampleRate: sampleRate, semitones: style.pitchSemitones)

        // 2. High-pass
        x = highPass(x, sampleRate: sampleRate, cutoff: style.highPassHz)

        // 3. Presence / air boost
        x = presenceBoost(x, sampleRate: sampleRate, amount: style.presenceAmount)

        // 4. Metalik tüp rezonansı
        x = metallicComb(x, sampleRate: sampleRate,
                         delayMs: style.combDelayMs,
                         feedback: style.combFeedback,
                         mix: style.combMix)

        // 5. Hafif ring-mod parıltısı
        x = ringShimmer(x, sampleRate: sampleRate, carrierHz: style.ringHz, mix: style.ringMix)

        // 6. Yumuşak limiter + normalize
        return softLimitAndNormalize(x, sampleRate: sampleRate, target: 0.95)
    }

    // MARK: - 1. Pitch Shift (Resample + WSOLA)

    /// Önce sinyali `ratio` hızında yeniden örnekler (perde ve formantlar yukarı çıkar, süre kısalır),
    /// ardından WSOLA ile orijinal süreye geri esnetir. Konuşma için çok temiz sonuç verir.
    static func pitchShift(_ x: [Float], sampleRate: Double, semitones: Double) -> [Float] {
        guard abs(semitones) > 0.01 else { return x }
        let ratio = pow(2.0, semitones / 12.0)

        // Aliasing önlemi: yeni Nyquist'in biraz altına low-pass
        var source = x
        if ratio > 1.0 {
            let cutoff = 0.45 * sampleRate / ratio
            source = lowPassBiquad(lowPassBiquad(source, sampleRate: sampleRate, cutoff: cutoff),
                                   sampleRate: sampleRate, cutoff: cutoff)
        }

        let resampled = resample(source, ratio: ratio)
        return wsolaStretch(resampled, sampleRate: sampleRate, targetLength: x.count)
    }

    /// Catmull-Rom kübik interpolasyon ile yeniden örnekleme. ratio > 1 → daha kısa / tiz.
    static func resample(_ x: [Float], ratio: Double) -> [Float] {
        let n = x.count
        let outCount = max(1, Int(Double(n) / ratio))
        var out = [Float](repeating: 0, count: outCount)
        @inline(__always) func s(_ i: Int) -> Float { x[min(max(i, 0), n - 1)] }
        for i in 0..<outCount {
            let pos = Double(i) * ratio
            let i1 = Int(pos)
            let t = Float(pos - Double(i1))
            let p0 = s(i1 - 1), p1 = s(i1), p2 = s(i1 + 1), p3 = s(i1 + 2)
            let a = -0.5 * p0 + 1.5 * p1 - 1.5 * p2 + 0.5 * p3
            let b = p0 - 2.5 * p1 + 2.0 * p2 - 0.5 * p3
            let c = -0.5 * p0 + 0.5 * p2
            out[i] = ((a * t + b) * t + c) * t + p1
        }
        return out
    }

    /// WSOLA (Waveform Similarity Overlap-Add) zaman esnetme — perdeyi değiştirmeden süreyi ayarlar.
    static func wsolaStretch(_ x: [Float], sampleRate: Double, targetLength: Int) -> [Float] {
        guard x.count > 64, targetLength > 64 else { return x }

        var frame = Int(sampleRate * 0.024)          // ~24 ms pencere
        frame += frame % 2                           // çift olsun
        let hopOut = frame / 2                       // %50 örtüşme
        let tolerance = Int(sampleRate * 0.008)      // ±8 ms benzerlik araması
        let alpha = Double(targetLength) / Double(x.count)
        let hopIn = Double(hopOut) / alpha

        // Periyodik Hann — %50 örtüşmede toplamı tam 1'dir
        var window = [Float](repeating: 0, count: frame)
        for i in 0..<frame {
            window[i] = 0.5 - 0.5 * cos(2.0 * Float.pi * Float(i) / Float(frame))
        }

        // Kenar taşmalarına karşı sıfır dolgu
        let pad = frame + tolerance * 2 + hopOut
        var input = [Float](repeating: 0, count: x.count + pad * 2)
        input.replaceSubrange(pad..<(pad + x.count), with: x)
        let maxStart = input.count - frame - 1

        let frames = targetLength / hopOut + 3
        var output = [Float](repeating: 0, count: frames * hopOut + frame)
        var corr = [Float](repeating: 0, count: tolerance * 2 + 1)
        var segment = [Float](repeating: 0, count: frame)

        var prevStart = pad
        input.withUnsafeBufferPointer { inp in
            guard let base = inp.baseAddress else { return }
            for k in 0..<frames {
                // k=0 çerçevesi sinyalin yarım hop öncesinden başlar → output[hopOut] == x[0]
                let nominal = pad + Int(Double(k - 1) * hopIn)
                var start = min(max(nominal, 0), maxStart)

                if k > 0 {
                    // Önceki segmentin doğal devamı ile en benzer konumu ara
                    let template = min(prevStart + hopOut, maxStart)
                    let lo = min(max(nominal - tolerance, 0), maxStart)
                    let hi = min(max(nominal + tolerance, 0), maxStart)
                    let count = hi - lo + 1
                    if count > 1 {
                        corr.withUnsafeMutableBufferPointer { c in
                            vDSP_conv(base + lo, 1, base + template, 1,
                                      c.baseAddress!, 1, vDSP_Length(count), vDSP_Length(frame))
                        }
                        var bestValue: Float = 0
                        var bestIndex: vDSP_Length = 0
                        vDSP_maxvi(corr, 1, &bestValue, &bestIndex, vDSP_Length(count))
                        start = lo + Int(bestIndex)
                    }
                }

                // Pencerele ve üst üste ekle
                vDSP_vmul(base + start, 1, window, 1, &segment, 1, vDSP_Length(frame))
                let outPos = k * hopOut
                output.withUnsafeMutableBufferPointer { o in
                    let dst = o.baseAddress! + outPos
                    vDSP_vadd(dst, 1, segment, 1, dst, 1, vDSP_Length(frame))
                }
                prevStart = start
            }
        }

        // İlk hop yalnızca dolgu bölgesidir; çıktı orijinal hizaya getirilir
        let offset = hopOut
        let end = min(offset + targetLength, output.count)
        var result = Array(output[offset..<end])
        if result.count < targetLength {
            result.append(contentsOf: [Float](repeating: 0, count: targetLength - result.count))
        }
        return result
    }

    // MARK: - 2/3. EQ

    static func highPass(_ x: [Float], sampleRate: Double, cutoff: Double) -> [Float] {
        guard cutoff > 0, x.count > 1 else { return x }
        let rc = 1.0 / (2.0 * .pi * cutoff)
        let dt = 1.0 / sampleRate
        let a = Float(rc / (rc + dt))
        var y = [Float](repeating: 0, count: x.count)
        y[0] = x[0]
        for i in 1..<x.count {
            y[i] = a * (y[i - 1] + x[i] - x[i - 1])
        }
        return y
    }

    /// 2.8 kHz üstünü hafifçe parlatır (diksiyon netliği + sevimli parlaklık)
    static func presenceBoost(_ x: [Float], sampleRate: Double, amount: Float) -> [Float] {
        guard amount > 0, !x.isEmpty else { return x }
        let rc = 1.0 / (2.0 * .pi * 2800.0)
        let dt = 1.0 / sampleRate
        let a = Float(dt / (rc + dt))
        var low: Float = x[0]
        var y = [Float](repeating: 0, count: x.count)
        for i in 0..<x.count {
            low += a * (x[i] - low)
            y[i] = x[i] + amount * (x[i] - low)
        }
        return y
    }

    /// RBJ biquad low-pass (Q = 0.707)
    static func lowPassBiquad(_ x: [Float], sampleRate: Double, cutoff: Double) -> [Float] {
        let w0 = 2.0 * Double.pi * min(cutoff, sampleRate * 0.49) / sampleRate
        let alpha = sin(w0) / (2.0 * 0.7071)
        let cosw = cos(w0)
        let a0 = 1.0 + alpha
        let b0 = Float(((1.0 - cosw) / 2.0) / a0)
        let b1 = Float((1.0 - cosw) / a0)
        let b2 = b0
        let a1 = Float((-2.0 * cosw) / a0)
        let a2 = Float((1.0 - alpha) / a0)
        var y = [Float](repeating: 0, count: x.count)
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
        for i in 0..<x.count {
            let v = b0 * x[i] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x[i]
            y2 = y1; y1 = v
            y[i] = v
        }
        return y
    }

    // MARK: - 4. Metalik Tüp Rezonansı

    static func metallicComb(_ x: [Float], sampleRate: Double, delayMs: Double, feedback: Float, mix: Float) -> [Float] {
        guard mix > 0, !x.isEmpty else { return x }
        let d = max(1, Int(sampleRate * delayMs / 1000.0))
        let fb = min(max(feedback, 0), 0.9)
        var wet = [Float](repeating: 0, count: x.count)
        for i in 0..<x.count {
            let prev: Float = i >= d ? wet[i - d] : 0
            wet[i] = x[i] + fb * prev
        }
        let wetGain = (1 - fb) // rezonans tepe kazancını dengele
        var y = [Float](repeating: 0, count: x.count)
        for i in 0..<x.count {
            y[i] = (1 - mix) * x[i] + mix * wetGain * wet[i]
        }
        return y
    }

    // MARK: - 5. Ring-Mod Parıltısı

    static func ringShimmer(_ x: [Float], sampleRate: Double, carrierHz: Double, mix: Float) -> [Float] {
        guard mix > 0, !x.isEmpty else { return x }
        let step = 2.0 * Double.pi * carrierHz / sampleRate
        var phase = 0.0
        var y = [Float](repeating: 0, count: x.count)
        for i in 0..<x.count {
            let carrier = Float(sin(phase))
            y[i] = x[i] * ((1 - mix) + mix * carrier)
            phase += step
            if phase > 2.0 * Double.pi { phase -= 2.0 * Double.pi }
        }
        return y
    }

    // MARK: - 6. Limiter + Normalize

    static func softLimitAndNormalize(_ x: [Float], sampleRate: Double, target: Float) -> [Float] {
        guard !x.isEmpty else { return x }
        var y = x.map { Float(tanh(Double($0) * 1.15)) }
        var peak: Float = 0
        vDSP_maxmgv(y, 1, &peak, vDSP_Length(y.count))
        if peak > 0.001 {
            var gain = target / peak
            vDSP_vsmul(y, 1, &gain, &y, 1, vDSP_Length(y.count))
        }
        // Başta/sonda tık sesi olmaması için 4 ms fade
        let fade = min(y.count / 4, Int(sampleRate * 0.004))
        if fade > 1 {
            for i in 0..<fade {
                let g = Float(i) / Float(fade)
                y[i] *= g
                y[y.count - 1 - i] *= g
            }
        }
        return y
    }
}

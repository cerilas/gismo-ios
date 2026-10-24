import Foundation

// MARK: - Face Tracking Controller (saf karar çekirdeği)
//
// Robotun motorları yalnızca AÇIK/KAPALI (F/B/L/R/S) çalışır ve komutlar
// uygulama → sunucu → ESP yolunu izler (değişken ağ gecikmesi). Bu yüzden
// sürekli hız kontrolü yerine "darbe → dur → gözlemle → düzelt" döngüsü kullanılır:
//
//  1. Yüz X konumu ~60 Hz örneklenir; karar MEDYAN filtreyle verilir (titreme ve
//     tekil ARKit sıçramaları motoru tetiklemez).
//  2. Histerezisli ölü bölge: |x| > startBand olunca düzeltmeye başlar,
//     |x| < stopBand olunca "merkezde" kabul edip tamamen durur (sürekli kıpırdama yok).
//  3. Darbe süresi hataya ORANTILIDIR (büyük kayma = uzun darbe, küçük = mikro darbe).
//  4. Darbeden sonra robotun gerçekten durduğu ve kameranın yeni görüntüyü verdiği
//     ana kadar (ölçülen ağ gecikmesi + motor ataleti + ARKit gecikmesi) eski
//     örnekler YOK SAYILIR → hareket sırasında bulanık/eskimiş veriyle karar verilmez.
//  5. Her darbenin gerçek etkisi ölçülür ve kazanç (x / ms) ile motor ölü süresi
//     uyarlanır: pil seviyesi, zemin sürtünmesi, kişi mesafesi değişse de
//     sistem kendini kalibre eder.
//  6. Merkezi aşan (overshoot) darbelerden sonra küçük kalan hata kabul edilir;
//     ard arda yön değişimi algılanırsa darbeler kısaltılır ve kısa soğuma uygulanır.
//  7. Kazanç henüz öğrenilmemişken (ilk darbeler) darbe süresi kısıtlanır → ilk hamlede savrulma yok.
//  8. Yüz kadrajın kenarından çıkarsa (kişi hızlı yürüdü / robot aştı) en son görüldüğü
//     tarafa doğru en fazla birkaç kısa "arama" darbesi atılır; bulunamazsa robot durur.
//
// Bu dosya yalnızca Foundation kullanır; zaman dışarıdan verilir (simülasyonla test edilebilir).

struct FaceTrackingTuning {
    /// Bu eşiği aşan kayma düzeltme başlatır (-1...+1 ölçeği)
    var startBand: Double = 0.26
    /// Bu eşiğin içine girince merkezde kabul edilir ve durulur
    var stopBand: Double = 0.10
    /// Darbe süresi sınırları (ms)
    var minPulseMs: Double = 22
    var maxPulseMs: Double = 150
    /// Hesaplanan düzeltmenin uygulanan oranı (<1 → aşmadan yaklaş)
    var aggressiveness: Double = 0.75
    /// Başlangıç tahminleri (çalışırken otomatik uyarlanır)
    var initialGainPerMs: Double = 0.005   // 1 ms darbe başına x değişimi
    var initialDeadMs: Double = 14         // motorun harekete geçmesi için gereken süre
    /// Kararda kullanılan medyan penceresi (sn) ve minimum örnek sayısı
    var medianWindow: Double = 0.12
    var minSamples: Int = 4
    /// Darbe sonrası motor ataleti + ARKit işlem gecikmesi (sn)
    var settleExtra: Double = 0.13
    /// Bu süre boyunca yeni yüz örneği gelmezse yüz kayıp sayılır (sn)
    var faceLostAfter: Double = 0.35
    /// Kazanç öğrenilene kadar (ilk N darbe) uygulanacak maksimum darbe (ms)
    var warmupPulses: Int = 2
    var warmupMaxPulseMs: Double = 75
    /// Yüz kenardan kaybolunca arama darbesi ayarları
    var searchEdge: Double = 0.55
    var searchPulseMs: Double = 60
    var maxSearchPulses: Int = 3
    var searchGiveUpAfter: Double = 2.5
}

struct FaceTrackingCore {

    enum Decision: Equatable {
        /// Bekle (motor durmalı) — verilen süre sonra tekrar sor
        case wait(seconds: Double)
        /// Yüz yok — motor durmalı
        case faceLost
        /// direction: +1 → yüz sağda (x>0), -1 → yüz solda. ms: darbe süresi, x: karar anındaki konum
        case pulse(direction: Int, ms: Double, x: Double)
    }

    var tuning: FaceTrackingTuning
    private(set) var gainPerMs: Double
    private(set) var deadMs: Double
    private(set) var isCentered = true
    /// Son `decide` çağrısı GÜNCEL bir ölçümle "merkezde" kararı verdiyse true
    /// (sabitlenme beklenirken / veri yetersizken false kalır)
    private(set) var lastDecisionCentered = false

    private var samples: [(t: Double, x: Double)] = []
    private var observeAfter: Double = 0
    private var pendingPulse: (direction: Int, ms: Double, xBefore: Double)?
    private var recentDirections: [(t: Double, dir: Int)] = []
    private var cooldownUntil: Double = 0
    private var learnedPulses = 0
    private var searchPulsesLeft = 0

    init(tuning: FaceTrackingTuning = FaceTrackingTuning()) {
        self.tuning = tuning
        self.gainPerMs = tuning.initialGainPerMs
        self.deadMs = tuning.initialDeadMs
    }

    // MARK: Girdi

    mutating func addSample(x: Double, at t: Double) {
        samples.append((t, max(-1, min(1, x))))
        if let first = samples.first, t - first.t > 1.0 {
            samples.removeAll { t - $0.t > 1.0 }
        }
    }

    /// Takip durdurulduğunda / yeniden başlatıldığında çağrılır (öğrenilen kazanç korunur)
    mutating func reset() {
        samples.removeAll()
        pendingPulse = nil
        observeAfter = 0
        isCentered = true
        recentDirections.removeAll()
        searchPulsesLeft = 0
    }

    /// Darbe bitip DUR komutu gönderildiğinde çağrılır.
    /// - latency: ölçülen tek yön (uygulama → robot) gecikme tahmini (sn)
    /// - xBefore: karar anındaki konum (`.pulse` içindeki x). Arama darbelerinde NaN gelir → öğrenme yapılmaz.
    mutating func didFinishPulse(direction: Int, ms: Double, xBefore: Double, at t: Double, latency: Double) {
        observeAfter = t + max(0, latency) + tuning.settleExtra
        pendingPulse = xBefore.isNaN ? nil : (direction, ms, xBefore)
    }

    // MARK: Karar

    mutating func decide(now: Double) -> Decision {
        lastDecisionCentered = false
        guard let last = samples.last, now - last.t <= tuning.faceLostAfter else {
            pendingPulse = nil
            isCentered = true
            return searchDecision(now: now)
        }
        searchPulsesLeft = tuning.maxSearchPulses

        // Darbe sonrası sabitlenme bekleniyor
        if now < observeAfter {
            return .wait(seconds: observeAfter - now)
        }

        let windowStart = max(observeAfter, now - tuning.medianWindow)
        let window = samples.filter { $0.t >= windowStart }.map(\.x)
        guard window.count >= tuning.minSamples else {
            return .wait(seconds: 0.02)
        }
        let x = Self.median(window)

        // Son darbenin etkisini öğren
        var overshot = false
        if let p = pendingPulse {
            pendingPulse = nil
            overshot = learn(from: p, xAfter: x)
        }

        if now < cooldownUntil {
            return .wait(seconds: cooldownUntil - now)
        }

        let err = abs(x)

        // Histerezis
        if err < tuning.stopBand || (overshot && err < tuning.startBand) {
            isCentered = true
            lastDecisionCentered = true
            return .wait(seconds: 0.04)
        }
        if isCentered && err < tuning.startBand {
            lastDecisionCentered = true
            return .wait(seconds: 0.04)
        }
        isCentered = false

        let direction = x > 0 ? 1 : -1

        // Ard arda yön değişimi (salınım) koruması
        recentDirections.append((now, direction))
        recentDirections.removeAll { now - $0.t > 2.5 }
        if recentDirections.count >= 3 {
            let n = recentDirections.count
            let a = recentDirections[n - 3].dir, b = recentDirections[n - 2].dir, c = recentDirections[n - 1].dir
            if a != b && b != c {
                gainPerMs = min(gainPerMs * 1.5, 0.05)   // darbeleri kısalt
                recentDirections.removeAll()
                cooldownUntil = now + 0.5
                isCentered = err < tuning.startBand
                return .wait(seconds: 0.5)
            }
        }

        // Hedef: merkeze tam değil, stopBand'in biraz içine (aşmadan) yaklaş
        let target = err * tuning.aggressiveness
        let cap = learnedPulses < tuning.warmupPulses ? tuning.warmupMaxPulseMs : tuning.maxPulseMs
        let ms = min(cap, max(tuning.minPulseMs, deadMs + target / gainPerMs))
        return .pulse(direction: direction, ms: ms, x: x)
    }

    /// Yüz kaybolduğunda: en son kenara yakın görüldüyse o tarafa birkaç kısa arama darbesi
    private mutating func searchDecision(now: Double) -> Decision {
        guard searchPulsesLeft > 0,
              let last = samples.last,
              now - last.t < tuning.searchGiveUpAfter,
              now >= observeAfter else {
            return .faceLost
        }
        let tail = samples.suffix(3).map(\.x)
        let lastSeen = Self.median(Array(tail))
        guard abs(lastSeen) >= tuning.searchEdge else { return .faceLost }
        searchPulsesLeft -= 1
        return .pulse(direction: lastSeen > 0 ? 1 : -1, ms: tuning.searchPulseMs, x: .nan)
    }

    /// Ölçülen darbe etkisine göre kazanç ve ölü süreyi uyarlar. Merkez aşıldıysa true döner.
    private mutating func learn(from p: (direction: Int, ms: Double, xBefore: Double), xAfter: Double) -> Bool {
        let sign = Double(p.direction)
        let moved = (p.xBefore - xAfter) * sign      // + → merkeze doğru hareket
        let overshot = xAfter * sign < -tuning.stopBand * 0.5

        learnedPulses += 1
        if moved < 0.02 {
            // Robot kıpırdamadı → motor ölü süresi tahmini düşük
            deadMs = min(deadMs + 5, 70)
            return overshot
        }

        let effective = max(p.ms - deadMs, 4)
        let observed = moved / effective
        gainPerMs = min(0.05, max(0.0015, gainPerMs * 0.65 + observed * 0.35))
        if observed > gainPerMs * 2.2 { deadMs = max(0, deadMs - 3) }
        return overshot
    }

    private static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// Fotoğraf öncesi ortalama gibi anlık durumlar için son medyan konum
    func currentX(now: Double) -> Double? {
        guard let last = samples.last, now - last.t <= tuning.faceLostAfter else { return nil }
        let start = max(observeAfter, now - tuning.medianWindow)
        let window = samples.filter { $0.t >= start }.map(\.x)
        guard window.count >= tuning.minSamples else { return nil }
        return Self.median(window)
    }
}

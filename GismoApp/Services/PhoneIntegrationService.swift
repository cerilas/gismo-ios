import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Contacts
import EventKit
import HealthKit
import CoreMotion
import CoreLocation
import CallKit
import MessageUI
import UserNotifications
#if canImport(AlarmKit)
import AlarmKit
#endif

// MARK: - Telefon (Varsayılan) Entegrasyonları
//
// Gismo'nun yapay zekasının iPhone'daki verileri görüp kullanabilmesini sağlar:
// Kamera, Rehber, Takvim, Anımsatıcılar, Alarm & Zamanlayıcı, Sağlık, Aktivite,
// Konum & Hava Durumu, Telefon Araması, Mesajlar, Cihaz Durumu.
//
// iOS KISITLARI (Apple güvenlik politikası — hiçbir App Store uygulaması yapamaz):
//  • Gelen SMS / iMessage içeriklerini okumak
//  • Arama geçmişini (gelen / cevapsız aramalar) görmek
//  • Saat uygulamasındaki mevcut alarmları görmek / silmek
//  • Onaysız arama başlatmak veya onaysız SMS göndermek (sistem onay ekranı çıkar)
// Bunların yerine: Gismo kendi kurduğu alarmları yönetir (iOS 26+ AlarmKit ile gerçek alarm),
// aramayı sistem onayıyla başlatır, mesajı hazır taslakla açar, anlık arama durumunu görür.

enum PhoneCapability: String, CaseIterable, Identifiable {
    case camera, contacts, calendar, reminders, alarms, health, activity, location, calls, messages, device

    var id: String { rawValue }

    var title: String {
        switch self {
        case .camera:    return "Kamera"
        case .contacts:  return "Rehber"
        case .calendar:  return "Takvim"
        case .reminders: return "Anımsatıcılar"
        case .alarms:    return "Alarm & Zamanlayıcı"
        case .health:    return "Sağlık"
        case .activity:  return "Aktivite & Hareket"
        case .location:  return "Konum & Hava Durumu"
        case .calls:     return "Telefon Araması"
        case .messages:  return "Mesajlar"
        case .device:    return "Cihaz Durumu"
        }
    }

    var detail: String {
        switch self {
        case .camera:    return "Fotoğraf çekme, gördüğünü anlatma"
        case .contacts:  return "Kişi arama, numara, e-posta, doğum günleri"
        case .calendar:  return "Etkinlikleri görme ve yeni etkinlik ekleme"
        case .reminders: return "Yapılacaklar listesi, hatırlatıcı ekleme"
        case .alarms:    return "Alarm kurma, zamanlayıcı, kurulu alarmları görme"
        case .health:    return "Adım, nabız, uyku, kalori, kilo, oksijen"
        case .activity:  return "Adım sayar, mesafe, kat, anlık hareket"
        case .location:  return "Neredeyim, hava durumu, yol tarifi"
        case .calls:     return "Kişiyi arama, anlık arama durumu"
        case .messages:  return "SMS / iMessage / WhatsApp taslağı"
        case .device:    return "Pil, depolama, fener, ekran parlaklığı"
        }
    }

    var icon: String {
        switch self {
        case .camera:    return "camera.fill"
        case .contacts:  return "person.crop.circle.fill"
        case .calendar:  return "calendar"
        case .reminders: return "checklist"
        case .alarms:    return "alarm.fill"
        case .health:    return "heart.fill"
        case .activity:  return "figure.walk"
        case .location:  return "location.fill"
        case .calls:     return "phone.fill"
        case .messages:  return "message.fill"
        case .device:    return "iphone"
        }
    }

    var tint: Color {
        switch self {
        case .camera:    return Color(red: 0.55, green: 0.60, blue: 0.70)
        case .contacts:  return Color(red: 0.62, green: 0.55, blue: 0.48)
        case .calendar:  return Color(red: 1.00, green: 0.33, blue: 0.33)
        case .reminders: return Color(red: 1.00, green: 0.62, blue: 0.20)
        case .alarms:    return Color(red: 1.00, green: 0.75, blue: 0.20)
        case .health:    return Color(red: 1.00, green: 0.30, blue: 0.45)
        case .activity:  return Color(red: 0.45, green: 0.90, blue: 0.35)
        case .location:  return Color(red: 0.25, green: 0.60, blue: 1.00)
        case .calls:     return Color(red: 0.25, green: 0.85, blue: 0.40)
        case .messages:  return Color(red: 0.30, green: 0.85, blue: 0.45)
        case .device:    return Color(red: 0.55, green: 0.55, blue: 0.95)
        }
    }

    /// Sistem izni gerektirmeyen yetenekler (her zaman kullanılabilir)
    var needsSystemPermission: Bool {
        switch self {
        case .calls, .device: return false
        case .messages:       return false
        default:              return true
        }
    }
}

enum PhonePermissionState: Equatable {
    case notDetermined, granted, denied, unavailable

    var label: String {
        switch self {
        case .notDetermined: return "İzin Ver"
        case .granted:       return "Açık"
        case .denied:        return "Ayarlar"
        case .unavailable:   return "Desteklenmiyor"
        }
    }
}

// MARK: - Service

@MainActor
final class PhoneIntegrationService: ObservableObject {

    static let shared = PhoneIntegrationService()

    @Published private(set) var states: [PhoneCapability: PhonePermissionState] = [:]
    @Published private(set) var enabledMap: [PhoneCapability: Bool] = [:]

    private let contactStore = CNContactStore()
    private let eventStore = EKEventStore()
    private let healthStore = HKHealthStore()
    private let pedometer = CMPedometer()
    private let motionManager = CMMotionActivityManager()
    private let callObserver = CXCallObserver()
    private lazy var locationFetcher = LocationFetcher()
    private let messagePresenter = MessageComposerPresenter()

    private init() {
        // HealthKit yeteneği sonradan eklenmiş olabilir: her açılışta yeniden denensin
        UserDefaults.standard.set(false, forKey: "phoneCap.health.missingEntitlement")
        for cap in PhoneCapability.allCases {
            let key = Self.enabledKey(cap)
            enabledMap[cap] = UserDefaults.standard.object(forKey: key) as? Bool ?? true
        }
        refreshStates()
    }

    // MARK: Enable / Permission

    private static func enabledKey(_ cap: PhoneCapability) -> String { "phoneCap.\(cap.rawValue).enabled" }

    func isEnabled(_ cap: PhoneCapability) -> Bool { enabledMap[cap] ?? true }

    func setEnabled(_ cap: PhoneCapability, _ value: Bool) {
        enabledMap[cap] = value
        UserDefaults.standard.set(value, forKey: Self.enabledKey(cap))
    }

    var activeCount: Int {
        PhoneCapability.allCases.filter { isEnabled($0) && states[$0] == .granted }.count
    }

    func refreshStates() {
        for cap in PhoneCapability.allCases {
            states[cap] = currentState(cap)
        }
        if #available(iOS 26.0, *) {} else {
            Task { await refreshNotificationState() }
        }
    }

    private func refreshNotificationState() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: states[.alarms] = .notDetermined
        case .denied:        states[.alarms] = .denied
        default:             states[.alarms] = .granted
        }
    }

    private func currentState(_ cap: PhoneCapability) -> PhonePermissionState {
        switch cap {
        case .camera:
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .contacts:
            let s = CNContactStore.authorizationStatus(for: .contacts)
            if s == .notDetermined { return .notDetermined }
            if s == .denied || s == .restricted { return .denied }
            return .granted
        case .calendar:
            return Self.ekState(EKEventStore.authorizationStatus(for: .event))
        case .reminders:
            return Self.ekState(EKEventStore.authorizationStatus(for: .reminder))
        case .alarms:
            #if canImport(AlarmKit)
            if #available(iOS 26.0, *) {
                switch AlarmManager.shared.authorizationState {
                case .authorized: return .granted
                case .denied: return .denied
                case .notDetermined: return .notDetermined
                @unknown default: return .notDetermined
                }
            }
            #endif
            return states[.alarms] ?? .notDetermined
        case .health:
            guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
            // Uygulama HealthKit yeteneği olmadan imzalandıysa (Xcode > Signing & Capabilities > HealthKit eklenmemiş)
            if UserDefaults.standard.bool(forKey: "phoneCap.health.missingEntitlement") { return .unavailable }
            // Okuma izni durumu gizlilik gereği sorgulanamaz; istendi mi bilgisini tutarız
            return UserDefaults.standard.bool(forKey: "phoneCap.health.requested") ? .granted : .notDetermined
        case .activity:
            guard CMPedometer.isStepCountingAvailable() || CMMotionActivityManager.isActivityAvailable() else { return .unavailable }
            switch CMMotionActivityManager.authorizationStatus() {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .location:
            switch CLLocationManager().authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .calls, .device:
            return .granted
        case .messages:
            return .granted
        }
    }

    private static func ekState(_ s: EKAuthorizationStatus) -> PhonePermissionState {
        switch s {
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        default: return .granted
        }
    }

    /// Sistem izin penceresini açar (gerekiyorsa). İzin verilirse true döner.
    @discardableResult
    func requestAccess(_ cap: PhoneCapability) async -> Bool {
        defer { refreshStates() }
        switch cap {
        case .camera:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .contacts:
            return (try? await contactStore.requestAccess(for: .contacts)) ?? false
        case .calendar:
            if #available(iOS 17.0, *) {
                return (try? await eventStore.requestFullAccessToEvents()) ?? false
            }
            return (try? await eventStore.requestAccess(to: .event)) ?? false
        case .reminders:
            if #available(iOS 17.0, *) {
                return (try? await eventStore.requestFullAccessToReminders()) ?? false
            }
            return (try? await eventStore.requestAccess(to: .reminder)) ?? false
        case .alarms:
            #if canImport(AlarmKit)
            if #available(iOS 26.0, *) {
                return await GismoAlarmKit.authorize()
            }
            #endif
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            await refreshNotificationState()
            return granted
        case .health:
            guard HKHealthStore.isHealthDataAvailable() else { return false }
            do {
                try await healthStore.requestAuthorization(toShare: [], read: Self.healthReadTypes)
                UserDefaults.standard.set(true, forKey: "phoneCap.health.requested")
                UserDefaults.standard.set(false, forKey: "phoneCap.health.missingEntitlement")
                return true
            } catch {
                print("[Health] Yetki hatası: \(error.localizedDescription)")
                if error.localizedDescription.lowercased().contains("entitlement") {
                    UserDefaults.standard.set(true, forKey: "phoneCap.health.missingEntitlement")
                }
                return false
            }
        case .activity:
            // CoreMotion izni ilk sorguda istenir
            return await withCheckedContinuation { cont in
                let now = Date()
                pedometer.queryPedometerData(from: now.addingTimeInterval(-60), to: now) { _, error in
                    let denied = (error as NSError?)?.code == Int(CMErrorMotionActivityNotAuthorized.rawValue)
                    cont.resume(returning: !denied)
                }
            }
        case .location:
            return await locationFetcher.requestAuthorization()
        case .calls, .device, .messages:
            return true
        }
    }

    /// Kullanıma hazır mı? Kapalıysa veya izin yoksa kullanıcıya okunacak açıklamayı döndürür.
    private func ensureReady(_ cap: PhoneCapability) async -> String? {
        guard isEnabled(cap) else {
            return "\(cap.title) entegrasyonu kapalı. Kullanıcı Entegrasyonlar > Telefon bölümünden açabilir."
        }
        switch currentState(cap) {
        case .granted:
            return nil
        case .unavailable:
            if cap == .health && HKHealthStore.isHealthDataAvailable() {
                return "Sağlık erişimi bu uygulama derlemesinde etkin değil (HealthKit yeteneği eklenmemiş). Geliştirici Xcode'da Signing & Capabilities > + Capability > HealthKit eklemeli."
            }
            return "\(cap.title) bu cihazda desteklenmiyor."
        case .denied:
            return "\(cap.title) izni reddedilmiş. Kullanıcı iPhone Ayarlar > Gismo bölümünden izni açmalı."
        case .notDetermined:
            let ok = await requestAccess(cap)
            return ok ? nil : "\(cap.title) izni verilmedi."
        }
    }

    // MARK: - Gemini Araç Tanımları

    nonisolated static let readOnlyToolNames: Set<String> = [
        "getDateTime", "searchContacts", "getUpcomingBirthdays", "getCallStatus",
        "getCalendarEvents", "getReminders", "listAlarms", "getHealthData", "getActivity",
        "getLocation", "getWeather", "getDeviceStatus", "analyzeCamera"
    ]

    nonisolated(unsafe) static let functionDeclarations: [[String: Any]] = {
        func obj(_ props: [String: Any], _ required: [String] = []) -> [String: Any] {
            var o: [String: Any] = ["type": "OBJECT", "properties": props]
            if !required.isEmpty { o["required"] = required }
            return o
        }
        let s: (String) -> [String: Any] = { ["type": "STRING", "description": $0] }
        let i: (String) -> [String: Any] = { ["type": "INTEGER", "description": $0] }
        let dateHint = "Yerel saatle 'yyyy-MM-dd'T'HH:mm' biçiminde (örn: 2026-10-25T14:30). Bugünün tarihi için önce getDateTime kullanabilirsin."
        return [
            ["name": "getDateTime",
             "description": "Şu anki tarih, saat, gün ve saat dilimini verir.",
             "parameters": obj([:])],
            ["name": "analyzeCamera",
             "description": "Kameradan anlık görüntü alıp (galeriye KAYDETMEDEN) ne gördüğünü analiz eder. 'Ne görüyorsun', 'elimde ne var', 'üstümdeki ne renk', 'şunu oku' gibi sorular için.",
             "parameters": obj(["question": s("Görüntü hakkında cevaplanacak soru (örn: 'Elimde ne var?').")])],
            ["name": "searchContacts",
             "description": "Telefon rehberinde kişi arar; ad, telefon numaraları, e-postalar, şirket, adres ve doğum gününü getirir.",
             "parameters": obj(["query": s("Aranacak isim (örn: 'Ahmet', 'Annem'). Rehberdeki kişi sayısı için boş bırak.")])],
            ["name": "getUpcomingBirthdays",
             "description": "Rehberdeki yaklaşan doğum günlerini listeler.",
             "parameters": obj(["days": i("Kaç gün içindekiler (varsayılan 30).")])],
            ["name": "makePhoneCall",
             "description": "Rehberdeki bir kişiyi veya numarayı telefonla arar (iOS arama onay ekranı açılır). Önce kullanıcıdan onay al.",
             "parameters": obj(["contactOrNumber": s("Kişi adı (örn: 'Annem') veya telefon numarası.")], ["contactOrNumber"])],
            ["name": "getCallStatus",
             "description": "Şu an devam eden / beklemedeki / gelen bir telefon araması olup olmadığını söyler. (Arama geçmişi iOS tarafından paylaşılmaz.)",
             "parameters": obj([:])],
            ["name": "sendPhoneMessage",
             "description": "Telefonun kendi Mesajlar uygulamasıyla (SMS/iMessage) mesaj taslağı açar; kullanıcı 'Gönder'e dokunarak yollar. Önce mesajı ve alıcıyı kullanıcıya teyit ettir.",
             "parameters": obj(["contactOrNumber": s("Kişi adı veya numara."), "message": s("Mesaj metni.")], ["contactOrNumber", "message"])],
            ["name": "sendWhatsAppMessage",
             "description": "WhatsApp'ta kişiye hazır mesajla sohbet açar; kullanıcı gönder'e dokunur. Önce teyit al.",
             "parameters": obj(["contactOrNumber": s("Kişi adı veya numara."), "message": s("Mesaj metni.")], ["contactOrNumber", "message"])],
            ["name": "getCalendarEvents",
             "description": "Takvimdeki etkinlikleri listeler (bugün, yarın, bu hafta vb.).",
             "parameters": obj(["startDate": s("Başlangıç tarihi. \(dateHint) Boşsa bugün."), "days": i("Kaç günlük (varsayılan 1).")])],
            ["name": "createCalendarEvent",
             "description": "Takvime yeni etkinlik ekler.",
             "parameters": obj(["title": s("Etkinlik başlığı."), "startDate": s("Başlangıç. \(dateHint)"),
                                "durationMinutes": i("Süre dakika (varsayılan 60)."), "location": s("Konum (opsiyonel)."),
                                "notes": s("Not (opsiyonel).")], ["title", "startDate"])],
            ["name": "getReminders",
             "description": "Anımsatıcılar uygulamasındaki tamamlanmamış yapılacakları listeler.",
             "parameters": obj([:])],
            ["name": "createReminder",
             "description": "Anımsatıcılar'a yeni yapılacak/hatırlatıcı ekler (tarih verilirse o saatte bildirim gelir).",
             "parameters": obj(["title": s("Hatırlatıcı metni."), "dueDate": s("Opsiyonel zaman. \(dateHint)"), "notes": s("Not (opsiyonel).")], ["title"])],
            ["name": "setAlarm",
             "description": "Belirtilen saate alarm kurar (iOS 26+ gerçek alarm, eski sürümlerde sesli bildirim).",
             "parameters": obj(["time": s("Saat 'HH:mm' (örn: '07:30' → en yakın 07:30) veya tam tarih \(dateHint)"), "label": s("Alarm etiketi (opsiyonel).")], ["time"])],
            ["name": "setTimer",
             "description": "Geri sayım zamanlayıcısı kurar; süre dolunca alarm çalar.",
             "parameters": obj(["minutes": i("Dakika."), "seconds": i("Saniye (opsiyonel)."), "label": s("Etiket (opsiyonel, örn: 'Makarna').")])],
            ["name": "listAlarms",
             "description": "Gismo'nun kurduğu aktif alarm ve zamanlayıcıları listeler.",
             "parameters": obj([:])],
            ["name": "cancelAlarm",
             "description": "Gismo'nun kurduğu alarm/zamanlayıcıyı iptal eder.",
             "parameters": obj(["query": s("Etiket, saat ('07:30') veya hepsi için 'hepsi'.")], ["query"])],
            ["name": "getHealthData",
             "description": "Apple Sağlık verilerini okur.",
             "parameters": obj(["metric": s("summary | steps | distance | activeEnergy | exercise | flights | heartRate | restingHeartRate | hrv | sleep | weight | bloodOxygen"),
                                "days": i("Kaç günlük veri (varsayılan 1 = bugün).")], ["metric"])],
            ["name": "getActivity",
             "description": "Telefonun hareket sensöründen adım, mesafe, çıkılan kat ve şu anki hareket durumunu (yürüyor, koşuyor, araçta, duruyor) verir.",
             "parameters": obj(["days": i("0 = bugün, 1 = dün ... (varsayılan 0).")])],
            ["name": "getLocation",
             "description": "Kullanıcının şu anki konumunu (adres, semt, şehir) verir.",
             "parameters": obj([:])],
            ["name": "getWeather",
             "description": "Hava durumunu ve 3 günlük tahmini verir.",
             "parameters": obj(["place": s("Şehir/yer adı. Boşsa kullanıcının bulunduğu konum.")])],
            ["name": "openMapsDirections",
             "description": "Apple Haritalar'da bir yere yol tarifi açar.",
             "parameters": obj(["destination": s("Gidilecek yer/adres.")], ["destination"])],
            ["name": "getDeviceStatus",
             "description": "Telefonun pil yüzdesi, şarj durumu, düşük güç modu, boş depolama, model, iOS sürümü ve ekran parlaklığını verir.",
             "parameters": obj([:])],
            ["name": "setFlashlight",
             "description": "Telefonun fenerini açar veya kapatır.",
             "parameters": obj(["on": ["type": "BOOLEAN", "description": "true = aç, false = kapat"]], ["on"])],
            ["name": "setScreenBrightness",
             "description": "Ekran parlaklığını ayarlar.",
             "parameters": obj(["level": i("0-100 arası parlaklık yüzdesi.")], ["level"])]
        ]
    }()

    nonisolated static let promptSummary = """
    TELEFON ERİŞİMİN (iPhone): Kamera (analyzeCamera ile gördüğünü anlatma), Rehber (searchContacts, getUpcomingBirthdays), \
    Takvim (getCalendarEvents, createCalendarEvent), Anımsatıcılar (getReminders, createReminder), Alarm/Zamanlayıcı (setAlarm, setTimer, listAlarms, cancelAlarm), \
    Sağlık (getHealthData), Aktivite (getActivity), Konum/Hava (getLocation, getWeather, openMapsDirections), Telefon (makePhoneCall, getCallStatus), \
    Mesajlar (sendPhoneMessage, sendWhatsAppMessage), Cihaz (getDeviceStatus, setFlashlight, setScreenBrightness), tarih/saat (getDateTime).
    Arama yapmadan ve mesaj taslağı açmadan önce alıcıyı ve mesajı tekrar edip onay iste.
    iOS KISITI: Gelen SMS'leri okumak, arama geçmişini (gelen/cevapsız aramalar) görmek ve Saat uygulamasındaki mevcut alarmları görmek Apple tarafından hiçbir uygulamaya izin verilmez. \
    Kullanıcı bunları sorarsa kibarca iOS'un buna izin vermediğini söyle ve yapabileceğin alternatifi öner (ör. şu anki arama durumu, Gismo'nun kurduğu alarmlar).
    Bir araç "kapalı" veya "izin verilmedi" derse kullanıcıya Entegrasyonlar > Telefon bölümünden açabileceğini söyle.
    """

    // MARK: - Araç Yürütücü

    /// Bu servise ait bir araçsa sonucu döndürür, değilse nil.
    func execute(name: String, args: [String: Any]) async -> String? {
        switch name {
        case "getDateTime":          return dateTimeInfo()
        case "searchContacts":       return await searchContacts(query: str(args["query"]))
        case "getUpcomingBirthdays": return await upcomingBirthdays(days: int(args["days"]) ?? 30)
        case "makePhoneCall":        return await makePhoneCall(str(args["contactOrNumber"]))
        case "getCallStatus":        return callStatus()
        case "sendPhoneMessage":     return await sendPhoneMessage(str(args["contactOrNumber"]), str(args["message"]))
        case "sendWhatsAppMessage":  return await sendWhatsApp(str(args["contactOrNumber"]), str(args["message"]))
        case "getCalendarEvents":    return await calendarEvents(start: str(args["startDate"]), days: int(args["days"]) ?? 1)
        case "createCalendarEvent":  return await createEvent(args)
        case "getReminders":         return await reminders()
        case "createReminder":       return await createReminder(args)
        case "setAlarm":             return await setAlarm(time: str(args["time"]), label: str(args["label"]))
        case "setTimer":             return await setTimer(minutes: int(args["minutes"]) ?? 0, seconds: int(args["seconds"]) ?? 0, label: str(args["label"]))
        case "listAlarms":           return await listAlarms()
        case "cancelAlarm":          return await cancelAlarm(query: str(args["query"]))
        case "getHealthData":        return await healthData(metric: str(args["metric"]), days: int(args["days"]) ?? 1)
        case "getActivity":          return await activity(daysAgo: int(args["days"]) ?? 0)
        case "getLocation":          return await location()
        case "getWeather":           return await weather(place: str(args["place"]))
        case "openMapsDirections":   return await openMaps(str(args["destination"]))
        case "getDeviceStatus":      return deviceStatus()
        case "setFlashlight":        return setFlashlight(on: (args["on"] as? Bool) ?? ((args["on"] as? NSNumber)?.boolValue ?? true))
        case "setScreenBrightness":  return setBrightness(int(args["level"]) ?? 50)
        default:                     return nil
        }
    }

    /// analyzeCamera kamera erişimi kontrolü (görüntü GeminiService'de işlenir)
    func cameraReadyMessage() async -> String? { await ensureReady(.camera) }

    private func str(_ v: Any?) -> String { (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    private func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }

    // MARK: Tarih / Saat

    nonisolated private static let trLocale = Locale(identifier: "tr_TR")

    nonisolated private static func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = trLocale
        f.dateFormat = pattern
        return f.string(from: date)
    }

    nonisolated static func currentDateLine() -> String {
        "Şu an: \(format(Date(), "d MMMM yyyy EEEE, HH:mm")) (\(TimeZone.current.identifier))."
    }

    private func dateTimeInfo() -> String {
        Self.currentDateLine() + " ISO: \(Self.format(Date(), "yyyy-MM-dd'T'HH:mm"))"
    }

    /// Gemini'den gelen tarih metnini yerel saatle çözümler
    nonisolated static func parseDate(_ raw: String, preferFuture: Bool = false) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: text) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: text) { return d }

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for p in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "dd.MM.yyyy HH:mm", "yyyy-MM-dd", "dd.MM.yyyy"] {
            f.dateFormat = p
            if let d = f.date(from: text) { return d }
        }

        // Sadece saat: "07:30", "7.30", "7"
        let cleaned = text.replacingOccurrences(of: ".", with: ":")
        let parts = cleaned.split(separator: ":").compactMap { Int($0) }
        if (1...2).contains(parts.count), (0...23).contains(parts[0]) {
            let minute = parts.count > 1 ? parts[1] : 0
            guard (0...59).contains(minute) else { return nil }
            var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
            comps.hour = parts[0]; comps.minute = minute; comps.second = 0
            guard var d = Calendar.current.date(from: comps) else { return nil }
            if preferFuture && d <= Date() { d = Calendar.current.date(byAdding: .day, value: 1, to: d) ?? d }
            return d
        }
        return nil
    }

    // MARK: Rehber

    private static func fold(_ s: String) -> String {
        s.lowercased(with: trLocale)
            .replacingOccurrences(of: "ı", with: "i")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: trLocale)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Annem" → ["annem", "anne"], "Ahmet'i" → ["ahmet'i", "ahmet"]
    private static func queryVariants(_ q: String) -> [String] {
        var base = fold(q)
        if let apos = base.firstIndex(where: { $0 == "'" || $0 == "’" }) { base = String(base[..<apos]) }
        var out = [base]
        for suffix in ["imi", "umu", "ime", "ume", "im", "um", "m"] where base.hasSuffix(suffix) && base.count > suffix.count + 2 {
            out.append(String(base.dropLast(suffix.count)))
        }
        return out
    }

    nonisolated(unsafe) private static let contactKeys: [CNKeyDescriptor] = [
        CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
        CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactBirthdayKey, CNContactPostalAddressesKey,
        CNContactJobTitleKey
    ] as [CNKeyDescriptor]

    private nonisolated static func fetchAllContacts(_ store: CNContactStore) -> [CNContact] {
        var result: [CNContact] = []
        let req = CNContactFetchRequest(keysToFetch: contactKeys)
        req.sortOrder = .userDefault
        try? store.enumerateContacts(with: req) { c, _ in result.append(c) }
        return result
    }

    private static func displayName(_ c: CNContact) -> String {
        let full = "\(c.givenName) \(c.familyName)".trimmingCharacters(in: .whitespaces)
        if !full.isEmpty { return full }
        if !c.nickname.isEmpty { return c.nickname }
        return c.organizationName
    }

    private func findContacts(_ query: String, limit: Int = 5) async -> [CNContact] {
        let store = contactStore
        let all = await Task.detached(priority: .userInitiated) { Self.fetchAllContacts(store) }.value
        let variants = Self.queryVariants(query)
        var scored: [(CNContact, Int)] = []
        for c in all {
            let full = Self.fold("\(c.givenName) \(c.familyName)")
            let fields = [full, Self.fold(c.givenName), Self.fold(c.nickname), Self.fold(c.organizationName)]
            var best = 0
            for v in variants where !v.isEmpty {
                for f in fields where !f.isEmpty {
                    if f == v { best = max(best, 4) }
                    else if f.hasPrefix(v) { best = max(best, 3) }
                    else if f.split(separator: " ").contains(where: { $0.hasPrefix(v) }) { best = max(best, 2) }
                    else if f.contains(v) { best = max(best, 1) }
                }
            }
            if best > 0 { scored.append((c, best)) }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    private static func phoneLabel(_ raw: String?) -> String {
        guard let raw else { return "telefon" }
        return CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: raw)
    }

    private func searchContacts(query: String) async -> String {
        if let msg = await ensureReady(.contacts) { return msg }
        if query.isEmpty {
            let store = contactStore
            let count = await Task.detached { Self.fetchAllContacts(store).count }.value
            return "Rehberde toplam \(count) kişi var."
        }
        let matches = await findContacts(query)
        guard !matches.isEmpty else { return "Rehberde '\(query)' ile eşleşen kişi bulunamadı." }
        return matches.map { c in
            var lines = ["• \(Self.displayName(c))"]
            if !c.organizationName.isEmpty || !c.jobTitle.isEmpty {
                lines.append("  İş: \([c.jobTitle, c.organizationName].filter { !$0.isEmpty }.joined(separator: ", "))")
            }
            for p in c.phoneNumbers.prefix(3) {
                lines.append("  \(Self.phoneLabel(p.label)): \(p.value.stringValue)")
            }
            for e in c.emailAddresses.prefix(2) { lines.append("  e-posta: \(e.value as String)") }
            if let b = c.birthday, let month = b.month, let day = b.day {
                var comps = DateComponents(); comps.month = month; comps.day = day; comps.year = b.year ?? 2000
                if let d = Calendar.current.date(from: comps) {
                    lines.append("  Doğum günü: \(Self.format(d, b.year == nil ? "d MMMM" : "d MMMM yyyy"))")
                }
            }
            if let a = c.postalAddresses.first?.value {
                let addr = [a.street, a.subLocality, a.city].filter { !$0.isEmpty }.joined(separator: ", ")
                if !addr.isEmpty { lines.append("  Adres: \(addr)") }
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    private func upcomingBirthdays(days: Int) async -> String {
        if let msg = await ensureReady(.contacts) { return msg }
        let store = contactStore
        let all = await Task.detached { Self.fetchAllContacts(store) }.value
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var items: [(String, Int, Date)] = []
        for c in all {
            guard let b = c.birthday, let m = b.month, let d = b.day else { continue }
            var comps = cal.dateComponents([.year], from: today); comps.month = m; comps.day = d
            guard var next = cal.date(from: comps) else { continue }
            if next < today { next = cal.date(byAdding: .year, value: 1, to: next) ?? next }
            let diff = cal.dateComponents([.day], from: today, to: next).day ?? 999
            if diff <= days { items.append((Self.displayName(c), diff, next)) }
        }
        guard !items.isEmpty else { return "Önümüzdeki \(days) gün içinde rehberde doğum günü yok." }
        return items.sorted { $0.1 < $1.1 }.prefix(10).map {
            "• \($0.0): \(Self.format($0.2, "d MMMM EEEE"))" + ($0.1 == 0 ? " (BUGÜN)" : " (\($0.1) gün sonra)")
        }.joined(separator: "\n")
    }

    /// Kişi adı veya numarayı (görünen ad, numara) olarak çözer
    private func resolvePhone(_ input: String) async -> (name: String, number: String)? {
        let digits = input.filter { $0.isNumber || $0 == "+" }
        if digits.filter(\.isNumber).count >= 7 { return (input, digits) }
        guard await ensureReady(.contacts) == nil else { return nil }
        guard let c = await findContacts(input, limit: 1).first else { return nil }
        let mobileLabels = [CNLabelPhoneNumberMobile, CNLabelPhoneNumberiPhone]
        let phone = c.phoneNumbers.first { mobileLabels.contains($0.label ?? "") } ?? c.phoneNumbers.first
        guard let number = phone?.value.stringValue else { return nil }
        return (Self.displayName(c), number.filter { $0.isNumber || $0 == "+" })
    }

    // MARK: Arama & Mesaj

    private func makePhoneCall(_ target: String) async -> String {
        if let msg = await ensureReady(.calls) { return msg }
        guard let (name, number) = await resolvePhone(target) else {
            return "'\(target)' için telefon numarası bulunamadı (rehber izni açık mı?)."
        }
        guard let url = URL(string: "tel://\(number)") else { return "Numara geçersiz." }
        let ok = await UIApplication.shared.open(url)
        return ok ? "\(name) (\(number)) için arama ekranı açıldı; iOS onayıyla arama başlıyor."
                  : "Bu cihaz telefon araması yapamıyor."
    }

    private func callStatus() -> String {
        let calls = callObserver.calls
        guard !calls.isEmpty else {
            return "Şu an devam eden bir telefon araması yok. (iOS arama geçmişini uygulamalarla paylaşmaz.)"
        }
        return calls.map { c in
            if c.hasEnded { return "• Az önce biten bir arama" }
            if c.isOnHold { return "• Beklemede bir arama" }
            if !c.hasConnected { return c.isOutgoing ? "• Çalan giden arama" : "• Şu an GELEN bir arama çalıyor" }
            return c.isOutgoing ? "• Devam eden giden arama" : "• Devam eden gelen arama"
        }.joined(separator: "\n")
    }

    private func sendPhoneMessage(_ target: String, _ message: String) async -> String {
        if let msg = await ensureReady(.messages) { return msg }
        guard MFMessageComposeViewController.canSendText() else { return "Bu cihaz mesaj gönderemiyor." }
        guard let (name, number) = await resolvePhone(target) else {
            return "'\(target)' için telefon numarası bulunamadı."
        }
        let shown = messagePresenter.present(recipient: number, body: message)
        return shown ? "\(name) için mesaj taslağı açıldı. Göndermek için ekrandaki 'Gönder' tuşuna dokunman yeterli."
                     : "Mesaj ekranı açılamadı."
    }

    private func sendWhatsApp(_ target: String, _ message: String) async -> String {
        if let msg = await ensureReady(.messages) { return msg }
        guard let (name, number) = await resolvePhone(target) else {
            return "'\(target)' için telefon numarası bulunamadı."
        }
        var digits = number.filter(\.isNumber)
        if digits.hasPrefix("0") && digits.count == 11 { digits = "90" + digits.dropFirst() }
        else if digits.count == 10 && digits.hasPrefix("5") { digits = "90" + digits }
        let text = message.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let app = URL(string: "whatsapp://send?phone=\(digits)&text=\(text)"), await UIApplication.shared.open(app) {
            return "\(name) ile WhatsApp sohbeti mesaj hazır olarak açıldı; göndermek için 'Gönder'e dokun."
        }
        if let web = URL(string: "https://wa.me/\(digits)?text=\(text)"), await UIApplication.shared.open(web) {
            return "WhatsApp bağlantısı açıldı (\(name))."
        }
        return "WhatsApp açılamadı; uygulama yüklü olmayabilir."
    }

    // MARK: Takvim & Anımsatıcılar

    private func calendarEvents(start: String, days: Int) async -> String {
        if let msg = await ensureReady(.calendar) { return msg }
        let cal = Calendar.current
        let startDate = cal.startOfDay(for: Self.parseDate(start) ?? Date())
        let end = cal.date(byAdding: .day, value: max(1, min(days, 31)), to: startDate) ?? startDate
        let pred = eventStore.predicateForEvents(withStart: startDate, end: end, calendars: nil)
        let events = eventStore.events(matching: pred).sorted { $0.startDate < $1.startDate }
        let range = days <= 1 ? Self.format(startDate, "d MMMM EEEE") : "\(Self.format(startDate, "d MMMM")) – \(Self.format(end.addingTimeInterval(-1), "d MMMM"))"
        guard !events.isEmpty else { return "\(range) için takvimde etkinlik yok." }
        let lines = events.prefix(20).map { e -> String in
            let when = e.isAllDay ? "\(Self.format(e.startDate, "d MMM")) tüm gün" : "\(Self.format(e.startDate, days <= 1 ? "HH:mm" : "d MMM HH:mm"))–\(Self.format(e.endDate, "HH:mm"))"
            var line = "• \(when): \(e.title ?? "Başlıksız")"
            if let loc = e.location, !loc.isEmpty { line += " @ \(loc)" }
            return line
        }
        return "\(range) etkinlikleri:\n" + lines.joined(separator: "\n")
    }

    private func createEvent(_ args: [String: Any]) async -> String {
        if let msg = await ensureReady(.calendar) { return msg }
        let title = str(args["title"])
        guard let start = Self.parseDate(str(args["startDate"])) else { return "Etkinlik tarihi anlaşılamadı." }
        let event = EKEvent(eventStore: eventStore)
        event.title = title.isEmpty ? "Gismo etkinliği" : title
        event.startDate = start
        event.endDate = start.addingTimeInterval(Double(max(5, int(args["durationMinutes"]) ?? 60)) * 60)
        let loc = str(args["location"]); if !loc.isEmpty { event.location = loc }
        let notes = str(args["notes"]); if !notes.isEmpty { event.notes = notes }
        event.calendar = eventStore.defaultCalendarForNewEvents
        event.addAlarm(EKAlarm(relativeOffset: -15 * 60))
        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
            return "'\(event.title ?? "")' etkinliği \(Self.format(start, "d MMMM EEEE HH:mm")) için takvime eklendi (15 dk önce hatırlatma)."
        } catch {
            return "Etkinlik eklenemedi: \(error.localizedDescription)"
        }
    }

    private func reminders() async -> String {
        if let msg = await ensureReady(.reminders) { return msg }
        let pred = eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let items: [(String, Date?)] = await withCheckedContinuation { cont in
            eventStore.fetchReminders(matching: pred) { list in
                let mapped = (list ?? []).map { r in (r.title ?? "", r.dueDateComponents.flatMap { Calendar.current.date(from: $0) }) }
                cont.resume(returning: mapped)
            }
        }
        guard !items.isEmpty else { return "Tamamlanmamış anımsatıcı yok." }
        let sorted = items.sorted { ($0.1 ?? .distantFuture) < ($1.1 ?? .distantFuture) }
        return "Yapılacaklar (\(items.count)):\n" + sorted.prefix(15).map { t, d in
            "• \(t)" + (d.map { " — \(Self.format($0, "d MMM HH:mm"))" } ?? "")
        }.joined(separator: "\n")
    }

    private func createReminder(_ args: [String: Any]) async -> String {
        if let msg = await ensureReady(.reminders) { return msg }
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = str(args["title"]).isEmpty ? "Gismo hatırlatıcısı" : str(args["title"])
        guard let calendar = eventStore.defaultCalendarForNewReminders() else { return "Anımsatıcılar listesi bulunamadı." }
        reminder.calendar = calendar
        let notes = str(args["notes"]); if !notes.isEmpty { reminder.notes = notes }
        var whenText = ""
        if let due = Self.parseDate(str(args["dueDate"]), preferFuture: true) {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
            whenText = " (\(Self.format(due, "d MMMM EEEE HH:mm")))"
        }
        do {
            try eventStore.save(reminder, commit: true)
            return "Anımsatıcı eklendi: '\(reminder.title ?? "")'\(whenText)."
        } catch {
            return "Anımsatıcı eklenemedi: \(error.localizedDescription)"
        }
    }

    // MARK: Alarm & Zamanlayıcı

    private struct StoredAlarm: Codable {
        let id: UUID
        let date: Date
        let label: String
        let isTimer: Bool
    }

    private var storedAlarms: [StoredAlarm] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "gismo.alarms"),
                  let list = try? JSONDecoder().decode([StoredAlarm].self, from: data) else { return [] }
            return list.filter { $0.date > Date().addingTimeInterval(-60) }
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "gismo.alarms") }
    }

    private func scheduleAlarm(at date: Date, label: String, isTimer: Bool) async -> String? {
        if let msg = await ensureReady(.alarms) { return msg }
        let id = UUID()
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            do {
                try await GismoAlarmKit.schedule(id: id, date: date, label: label)
            } catch {
                return "Alarm kurulamadı: \(error.localizedDescription)"
            }
            storedAlarms = storedAlarms + [StoredAlarm(id: id, date: date, label: label, isTimer: isTimer)]
            return nil
        }
        #endif
        let content = UNMutableNotificationContent()
        content.title = isTimer ? "⏱ Zamanlayıcı bitti" : "⏰ Gismo Alarmı"
        content.body = label
        content.sound = .defaultCritical
        content.interruptionLevel = .timeSensitive
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let request = UNNotificationRequest(identifier: "gismo.alarm.\(id.uuidString)", content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            return "Alarm kurulamadı: \(error.localizedDescription)"
        }
        storedAlarms = storedAlarms + [StoredAlarm(id: id, date: date, label: label, isTimer: isTimer)]
        return nil
    }

    private var alarmKindNote: String {
        if #available(iOS 26.0, *) { return "" }
        return " (iOS 26 öncesinde sesli bildirim olarak çalar; telefon sessizdeyse duyulmayabilir)"
    }

    private func setAlarm(time: String, label: String) async -> String {
        guard let date = Self.parseDate(time, preferFuture: true), date > Date() else {
            return "Alarm saati anlaşılamadı veya geçmişte kaldı."
        }
        let text = label.isEmpty ? "Alarm" : label
        if let err = await scheduleAlarm(at: date, label: text, isTimer: false) { return err }
        let rel = Self.relative(date)
        return "Alarm kuruldu: \(Self.format(date, "d MMMM EEEE HH:mm")) (\(rel) sonra) — '\(text)'\(alarmKindNote)."
    }

    private func setTimer(minutes: Int, seconds: Int, label: String) async -> String {
        let total = max(0, minutes) * 60 + max(0, seconds)
        guard total >= 5 else { return "Zamanlayıcı süresi çok kısa." }
        let date = Date().addingTimeInterval(TimeInterval(total))
        let text = label.isEmpty ? "Zamanlayıcı" : label
        if let err = await scheduleAlarm(at: date, label: text, isTimer: true) { return err }
        return "\(Self.relative(date)) zamanlayıcı başladı — '\(text)', \(Self.format(date, "HH:mm:ss"))'te çalacak\(alarmKindNote)."
    }

    private static func relative(_ date: Date) -> String {
        let s = Int(date.timeIntervalSinceNow.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) saat") }
        if m > 0 { parts.append("\(m) dakika") }
        if h == 0 && sec > 0 && m < 5 { parts.append("\(sec) saniye") }
        return parts.isEmpty ? "birkaç saniye" : parts.joined(separator: " ")
    }

    private func listAlarms() async -> String {
        var list = storedAlarms
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            let live = Set(GismoAlarmKit.activeIDs())
            list = list.filter { live.contains($0.id) }
        }
        #endif
        storedAlarms = list
        guard !list.isEmpty else {
            return "Gismo'nun kurduğu aktif alarm veya zamanlayıcı yok. (Saat uygulamasındaki alarmları iOS paylaşmaz.)"
        }
        return list.sorted { $0.date < $1.date }.map {
            "• \($0.isTimer ? "Zamanlayıcı" : "Alarm") \(Self.format($0.date, "d MMM EEEE HH:mm")) — \($0.label)"
        }.joined(separator: "\n")
    }

    private func cancelAlarm(query: String) async -> String {
        let q = Self.fold(query)
        let all = storedAlarms
        let targets: [StoredAlarm]
        if q.isEmpty || ["hepsi", "tumu", "tum", "all"].contains(q) {
            targets = all
        } else {
            targets = all.filter { Self.fold($0.label).contains(q) || Self.format($0.date, "HH:mm") == query.replacingOccurrences(of: ".", with: ":") }
        }
        guard !targets.isEmpty else { return "'\(query)' ile eşleşen Gismo alarmı bulunamadı." }
        for a in targets {
            #if canImport(AlarmKit)
            if #available(iOS 26.0, *) { GismoAlarmKit.cancel(a.id) }
            #endif
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["gismo.alarm.\(a.id.uuidString)"])
        }
        let ids = Set(targets.map(\.id))
        storedAlarms = all.filter { !ids.contains($0.id) }
        return "\(targets.count) alarm/zamanlayıcı iptal edildi."
    }

    // MARK: Sağlık (HealthKit)

    private static let healthReadTypes: Set<HKObjectType> = {
        var set: Set<HKObjectType> = []
        let ids: [HKQuantityTypeIdentifier] = [.stepCount, .distanceWalkingRunning, .activeEnergyBurned, .appleExerciseTime,
                                               .flightsClimbed, .heartRate, .restingHeartRate, .heartRateVariabilitySDNN,
                                               .bodyMass, .oxygenSaturation]
        for id in ids { if let t = HKObjectType.quantityType(forIdentifier: id) { set.insert(t) } }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { set.insert(sleep) }
        return set
    }()

    private func healthSum(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ start: Date, _ end: Date) async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
        let pred = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await withCheckedContinuation { cont in
            let q = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: pred, options: .cumulativeSum) { _, stats, _ in
                cont.resume(returning: stats?.sumQuantity()?.doubleValue(for: unit))
            }
            healthStore.execute(q)
        }
    }

    private func healthStats(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ start: Date, _ end: Date) async -> (avg: Double, min: Double, max: Double)? {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
        let pred = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await withCheckedContinuation { cont in
            let q = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: pred,
                                      options: [.discreteAverage, .discreteMin, .discreteMax]) { _, stats, _ in
                guard let s = stats, let a = s.averageQuantity(), let mn = s.minimumQuantity(), let mx = s.maximumQuantity() else {
                    cont.resume(returning: nil); return
                }
                cont.resume(returning: (a.doubleValue(for: unit), mn.doubleValue(for: unit), mx.doubleValue(for: unit)))
            }
            healthStore.execute(q)
        }
    }

    private func healthLatest(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit) async -> (Double, Date)? {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
                guard let s = samples?.first as? HKQuantitySample else { cont.resume(returning: nil); return }
                cont.resume(returning: (s.quantity.doubleValue(for: unit), s.endDate))
            }
            healthStore.execute(q)
        }
    }

    /// Belirtilen gece için toplam uyku süresi (saat). Farklı kaynakların çakışan kayıtları birleştirilir.
    private func sleepHours(nightEnding end: Date) async -> Double? {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: end)
        let start = dayStart.addingTimeInterval(-6 * 3600)   // önceki gün 18:00
        let finish = dayStart.addingTimeInterval(14 * 3600)  // bu gün 14:00
        let pred = HKQuery.predicateForSamples(withStart: start, end: finish, options: [])
        let asleep: Set<Int> = Set(HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue))
        let intervals: [(Date, Date)] = await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: pred, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                let list = (samples as? [HKCategorySample] ?? []).filter { asleep.contains($0.value) }.map { ($0.startDate, $0.endDate) }
                cont.resume(returning: list)
            }
            healthStore.execute(q)
        }
        guard !intervals.isEmpty else { return nil }
        var merged: [(Date, Date)] = []
        for iv in intervals.sorted(by: { $0.0 < $1.0 }) {
            if let last = merged.last, iv.0 <= last.1 { merged[merged.count - 1].1 = max(last.1, iv.1) }
            else { merged.append(iv) }
        }
        return merged.reduce(0) { $0 + $1.1.timeIntervalSince($1.0) } / 3600
    }

    private func healthData(metric: String, days: Int) async -> String {
        if let msg = await ensureReady(.health) { return msg }
        let cal = Calendar.current
        let end = Date()
        let span = max(1, min(days, 90))
        let start = cal.date(byAdding: .day, value: -(span - 1), to: cal.startOfDay(for: end)) ?? end
        let period = span == 1 ? "Bugün" : "Son \(span) gün"
        let noData = "\(period) için bu veriye Sağlık uygulamasında kayıt yok (veya Gismo'ya okuma izni verilmemiş — Sağlık > Paylaşım > Uygulamalar > Gismo)."
        let perMinute = HKUnit.count().unitDivided(by: .minute())

        func n(_ v: Double, _ digits: Int = 0) -> String { String(format: "%.\(digits)f", v) }

        switch metric.lowercased() {
        case "steps":
            guard let v = await healthSum(.stepCount, .count(), start, end) else { return noData }
            return "\(period) adım: \(n(v))" + (span > 1 ? " (günlük ort. \(n(v / Double(span))))" : "")
        case "distance":
            guard let v = await healthSum(.distanceWalkingRunning, .meterUnit(with: .kilo), start, end) else { return noData }
            return "\(period) yürüme+koşu mesafesi: \(n(v, 2)) km"
        case "activeenergy", "calories":
            guard let v = await healthSum(.activeEnergyBurned, .kilocalorie(), start, end) else { return noData }
            return "\(period) aktif enerji: \(n(v)) kcal"
        case "exercise":
            guard let v = await healthSum(.appleExerciseTime, .minute(), start, end) else { return noData }
            return "\(period) egzersiz süresi: \(n(v)) dakika"
        case "flights":
            guard let v = await healthSum(.flightsClimbed, .count(), start, end) else { return noData }
            return "\(period) çıkılan kat: \(n(v))"
        case "heartrate":
            guard let s = await healthStats(.heartRate, perMinute, start, end) else { return noData }
            let latest = await healthLatest(.heartRate, perMinute)
            return "\(period) nabız: ort. \(n(s.avg)) bpm (min \(n(s.min)), max \(n(s.max)))"
                + (latest.map { ". Son ölçüm: \(n($0.0)) bpm (\(Self.format($0.1, "HH:mm")))" } ?? "")
        case "restingheartrate":
            guard let v = await healthLatest(.restingHeartRate, perMinute) else { return noData }
            return "Dinlenik nabız: \(n(v.0)) bpm (\(Self.format(v.1, "d MMM")))"
        case "hrv":
            guard let v = await healthLatest(.heartRateVariabilitySDNN, .secondUnit(with: .milli)) else { return noData }
            return "Kalp atış değişkenliği (HRV): \(n(v.0)) ms (\(Self.format(v.1, "d MMM HH:mm")))"
        case "sleep":
            var lines: [String] = []
            for offset in 0..<span {
                let day = cal.date(byAdding: .day, value: -offset, to: end) ?? end
                if let h = await sleepHours(nightEnding: day) {
                    lines.append("• \(Self.format(day, "d MMM EEEE")) gecesi: \(Int(h)) sa \(Int((h - Double(Int(h))) * 60)) dk")
                }
            }
            return lines.isEmpty ? "Uyku kaydı bulunamadı (Apple Watch / uyku takibi gerekli)." : "Uyku:\n" + lines.joined(separator: "\n")
        case "weight":
            guard let v = await healthLatest(.bodyMass, .gramUnit(with: .kilo)) else { return noData }
            return "Son kilo kaydı: \(n(v.0, 1)) kg (\(Self.format(v.1, "d MMMM yyyy")))"
        case "bloodoxygen", "oxygen":
            guard let v = await healthLatest(.oxygenSaturation, .percent()) else { return noData }
            return "Son kan oksijeni: %\(n(v.0 * 100)) (\(Self.format(v.1, "d MMM HH:mm")))"
        default: // summary
            async let steps = healthSum(.stepCount, .count(), start, end)
            async let dist = healthSum(.distanceWalkingRunning, .meterUnit(with: .kilo), start, end)
            async let energy = healthSum(.activeEnergyBurned, .kilocalorie(), start, end)
            async let exercise = healthSum(.appleExerciseTime, .minute(), start, end)
            async let resting = healthLatest(.restingHeartRate, perMinute)
            async let sleep = sleepHours(nightEnding: end)
            var lines: [String] = []
            if let v = await steps { lines.append("Adım: \(n(v))") }
            if let v = await dist { lines.append("Mesafe: \(n(v, 2)) km") }
            if let v = await energy { lines.append("Aktif enerji: \(n(v)) kcal") }
            if let v = await exercise { lines.append("Egzersiz: \(n(v)) dk") }
            if let v = await resting { lines.append("Dinlenik nabız: \(n(v.0)) bpm") }
            if let h = await sleep { lines.append("Dün gece uyku: \(Int(h)) sa \(Int((h - Double(Int(h))) * 60)) dk") }
            return lines.isEmpty ? noData : "\(period) sağlık özeti — " + lines.joined(separator: ", ")
        }
    }

    // MARK: Aktivite (CoreMotion)

    private func activity(daysAgo: Int) async -> String {
        if let msg = await ensureReady(.activity) { return msg }
        let cal = Calendar.current
        let dayStart = cal.date(byAdding: .day, value: -max(0, min(daysAgo, 6)), to: cal.startOfDay(for: Date())) ?? Date()
        let dayEnd = daysAgo == 0 ? Date() : (cal.date(byAdding: .day, value: 1, to: dayStart) ?? Date())

        let pedo: CMPedometerData? = await withCheckedContinuation { cont in
            pedometer.queryPedometerData(from: dayStart, to: dayEnd) { data, _ in cont.resume(returning: data) }
        }
        var lines: [String] = []
        let label = daysAgo == 0 ? "Bugün" : Self.format(dayStart, "d MMMM EEEE")
        if let p = pedo {
            lines.append("\(label): \(p.numberOfSteps.intValue) adım")
            if let d = p.distance?.doubleValue { lines.append(String(format: "%.2f km", d / 1000)) }
            if let f = p.floorsAscended?.intValue, f > 0 { lines.append("\(f) kat çıkıldı") }
        }

        if daysAgo == 0, CMMotionActivityManager.isActivityAvailable() {
            let acts: [CMMotionActivity] = await withCheckedContinuation { cont in
                motionManager.queryActivityStarting(from: Date().addingTimeInterval(-900), to: Date(), to: .main) { list, _ in
                    cont.resume(returning: list ?? [])
                }
            }
            if let a = acts.last(where: { $0.confidence != .low }) ?? acts.last {
                let state: String
                if a.automotive { state = "araçta" }
                else if a.cycling { state = "bisiklette" }
                else if a.running { state = "koşuyor" }
                else if a.walking { state = "yürüyor" }
                else if a.stationary { state = "hareketsiz / duruyor" }
                else { state = "belirsiz" }
                lines.append("Şu anki hareket: \(state)")
            }
        }
        return lines.isEmpty ? "Hareket verisi alınamadı." : lines.joined(separator: ", ")
    }

    // MARK: Konum & Hava Durumu

    private func currentPlace() async -> (CLLocation, String)? {
        guard let loc = await locationFetcher.currentLocation() else { return nil }
        let placemark = try? await CLGeocoder().reverseGeocodeLocation(loc, preferredLocale: Self.trLocale).first
        let parts = [placemark?.name, placemark?.subLocality, placemark?.locality, placemark?.administrativeArea, placemark?.country]
            .compactMap { $0 }.filter { !$0.isEmpty }
        var unique: [String] = []
        for p in parts where !unique.contains(p) { unique.append(p) }
        return (loc, unique.joined(separator: ", "))
    }

    private func location() async -> String {
        if let msg = await ensureReady(.location) { return msg }
        guard let (loc, address) = await currentPlace() else { return "Konum alınamadı." }
        return "Şu anki konum: \(address.isEmpty ? "bilinmiyor" : address) (\(String(format: "%.5f, %.5f", loc.coordinate.latitude, loc.coordinate.longitude)), doğruluk ±\(Int(loc.horizontalAccuracy)) m)"
    }

    private func weather(place: String) async -> String {
        var coord: CLLocationCoordinate2D?
        var placeName = place
        if !place.isEmpty {
            if let pm = try? await CLGeocoder().geocodeAddressString(place).first, let l = pm.location {
                coord = l.coordinate
                placeName = [pm.locality, pm.country].compactMap { $0 }.joined(separator: ", ")
            }
        } else {
            if let msg = await ensureReady(.location) { return msg }
            if let (loc, address) = await currentPlace() {
                coord = loc.coordinate
                placeName = address
            }
        }
        guard let c = coord else { return "Hava durumu için konum bulunamadı." }

        let urlStr = "https://api.open-meteo.com/v1/forecast?latitude=\(c.latitude)&longitude=\(c.longitude)"
            + "&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m"
            + "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max&timezone=auto&forecast_days=3"
        guard let url = URL(string: urlStr),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current"] as? [String: Any] else {
            return "Hava durumu servisine ulaşılamadı."
        }
        func d(_ v: Any?) -> Double { (v as? Double) ?? Double(v as? Int ?? 0) }
        var out = "\(placeName.isEmpty ? "Bulunduğun yer" : placeName): şu an \(Int(d(current["temperature_2m"]).rounded()))°C, "
            + "\(Self.weatherText(Int(d(current["weather_code"])))), hissedilen \(Int(d(current["apparent_temperature"]).rounded()))°C, "
            + "nem %\(Int(d(current["relative_humidity_2m"]))), rüzgar \(Int(d(current["wind_speed_10m"]).rounded())) km/s."
        if let daily = json["daily"] as? [String: Any],
           let codes = daily["weather_code"] as? [Any], let maxs = daily["temperature_2m_max"] as? [Any],
           let mins = daily["temperature_2m_min"] as? [Any], let rain = daily["precipitation_probability_max"] as? [Any] {
            let names = ["Bugün", "Yarın", "Ertesi gün"]
            for idx in 0..<min(3, codes.count, maxs.count, mins.count) {
                out += "\n• \(names[idx]): \(Self.weatherText(Int(d(codes[idx])))), \(Int(d(mins[idx]).rounded()))°/\(Int(d(maxs[idx]).rounded()))°C"
                if idx < rain.count { out += ", yağış ihtimali %\(Int(d(rain[idx])))" }
            }
        }
        return out
    }

    private static func weatherText(_ code: Int) -> String {
        switch code {
        case 0: return "açık"
        case 1: return "çoğunlukla açık"
        case 2: return "parçalı bulutlu"
        case 3: return "kapalı"
        case 45, 48: return "sisli"
        case 51, 53, 55, 56, 57: return "çiseleyen yağmur"
        case 61, 63, 66: return "yağmurlu"
        case 65, 67: return "şiddetli yağmur"
        case 71, 73, 77: return "kar yağışlı"
        case 75: return "yoğun kar"
        case 80, 81: return "sağanak"
        case 82: return "şiddetli sağanak"
        case 85, 86: return "kar sağanağı"
        case 95: return "gök gürültülü fırtına"
        case 96, 99: return "dolulu fırtına"
        default: return "değişken"
        }
    }

    private func openMaps(_ destination: String) async -> String {
        guard !destination.isEmpty,
              let q = destination.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "http://maps.apple.com/?daddr=\(q)&dirflg=d") else { return "Gidilecek yer anlaşılamadı." }
        let ok = await UIApplication.shared.open(url)
        return ok ? "Apple Haritalar'da '\(destination)' için yol tarifi açıldı." : "Haritalar açılamadı."
    }

    // MARK: Cihaz

    private func deviceStatus() -> String {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        var lines: [String] = []
        if device.batteryLevel >= 0 {
            let state: String
            switch device.batteryState {
            case .charging: state = "şarj oluyor"
            case .full: state = "dolu (şarjda)"
            case .unplugged: state = "şarjda değil"
            default: state = "bilinmiyor"
            }
            lines.append("Pil: %\(Int(device.batteryLevel * 100)) (\(state))")
        }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { lines.append("Düşük güç modu AÇIK") }
        if let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
           let free = values.volumeAvailableCapacityForImportantUsage, let total = values.volumeTotalCapacity {
            lines.append(String(format: "Depolama: %.1f GB boş / %.0f GB", Double(free) / 1e9, Double(total) / 1e9))
        }
        lines.append("Model: \(Self.modelIdentifier()), \(device.systemName) \(device.systemVersion)")
        lines.append("Ekran parlaklığı: %\(Int(UIScreen.main.brightness * 100))")
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: lines.append("Telefon ISINMIŞ durumda")
        default: break
        }
        return lines.joined(separator: ", ")
    }

    private static func modelIdentifier() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buf in
            String(decoding: buf.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    private func setFlashlight(on: Bool) -> String {
        guard isEnabled(.device) else { return "Cihaz entegrasyonu kapalı." }
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return "Bu cihazda fener yok." }
        do {
            try device.lockForConfiguration()
            if on { try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel) }
            else { device.torchMode = .off }
            device.unlockForConfiguration()
            return on ? "Fener açıldı." : "Fener kapatıldı."
        } catch {
            return "Fener kontrol edilemedi: \(error.localizedDescription)"
        }
    }

    private func setBrightness(_ level: Int) -> String {
        guard isEnabled(.device) else { return "Cihaz entegrasyonu kapalı." }
        let v = CGFloat(max(0, min(level, 100))) / 100
        UIScreen.main.brightness = v
        return "Ekran parlaklığı %\(Int(v * 100)) yapıldı."
    }
}

// MARK: - AlarmKit (iOS 26+)

#if canImport(AlarmKit)
@available(iOS 26.0, *)
struct GismoAlarmMetadata: AlarmMetadata {
    var label: String = ""
}

@available(iOS 26.0, *)
enum GismoAlarmKit {
    static func authorize() async -> Bool {
        let manager = AlarmManager.shared
        switch manager.authorizationState {
        case .authorized: return true
        case .denied: return false
        default:
            let state = try? await manager.requestAuthorization()
            return state == .authorized
        }
    }

    static func schedule(id: UUID, date: Date, label: String) async throws {
        let stop = AlarmButton(text: "Durdur", textColor: .white, systemImageName: "stop.circle")
        let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: label), stopButton: stop)
        let attributes = AlarmAttributes<GismoAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert),
            metadata: GismoAlarmMetadata(label: label),
            tintColor: .cyan
        )
        let configuration = AlarmManager.AlarmConfiguration<GismoAlarmMetadata>.alarm(
            schedule: .fixed(date),
            attributes: attributes
        )
        _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
    }

    static func activeIDs() -> [UUID] {
        ((try? AlarmManager.shared.alarms) ?? []).map(\.id)
    }

    static func cancel(_ id: UUID) {
        try? AlarmManager.shared.cancel(id: id)
    }
}
#endif

// MARK: - Konum yardımcısı

@MainActor
final class LocationFetcher: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var authContinuation: CheckedContinuation<Bool, Never>?
    private var locationContinuation: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestAuthorization() async -> Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                authContinuation?.resume(returning: false)
                authContinuation = cont
                manager.requestWhenInUseAuthorization()
            }
        default: return false
        }
    }

    func currentLocation() async -> CLLocation? {
        guard await requestAuthorization() else { return nil }
        if let cached = manager.location, cached.timestamp.timeIntervalSinceNow > -120 { return cached }
        return await withCheckedContinuation { cont in
            locationContinuation?.resume(returning: nil)
            locationContinuation = cont
            manager.requestLocation()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                self?.finishLocation(self?.manager.location)
            }
        }
    }

    private func finishLocation(_ loc: CLLocation?) {
        locationContinuation?.resume(returning: loc)
        locationContinuation = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard status != .notDetermined else { return }
            self.authContinuation?.resume(returning: status == .authorizedWhenInUse || status == .authorizedAlways)
            self.authContinuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let loc = locations.last
        Task { @MainActor in self.finishLocation(loc) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let fallback = manager.location
        Task { @MainActor in self.finishLocation(fallback) }
    }
}

// MARK: - Mesaj taslağı sunucusu

@MainActor
final class MessageComposerPresenter: NSObject, MFMessageComposeViewControllerDelegate {
    func present(recipient: String, body: String) -> Bool {
        guard MFMessageComposeViewController.canSendText(), let top = Self.topViewController() else { return false }
        let vc = MFMessageComposeViewController()
        vc.recipients = [recipient]
        vc.body = body
        vc.messageComposeDelegate = self
        top.present(vc, animated: true)
        return true
    }

    nonisolated func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
        Task { @MainActor in controller.dismiss(animated: true) }
    }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

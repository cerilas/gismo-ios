import Foundation
import GoogleSignIn
import UIKit
import Contacts

// MARK: - Models

struct MotorStep {
    let command: RobotCommand
    let durationMs: Int
}

struct GeminiMessage {
    let text: String
    let emotion: GismoEmotionName
    let duration: Double
    let motorSequence: [MotorStep]  // Boş ise hareket yok
}

enum GismoEmotionName: String {
    case neutral, happy, veryHappy, sad, angry, thoughtful, listening, surprised, sleeping
}

// MARK: - Manuel Metin Girişi (1. Sesli Deneme Başarısız Olduğunda Açılan Kutu)

enum ManualInputKind: String {
    case email       // E-posta adresi
    case driveFile   // Google Drive dosya adı
    case phoneOrName // Kişi adı veya telefon numarası
    case general     // Genel spesifik metin / komut

    var defaultTitle: String {
        switch self {
        case .email:       return "E-POSTA ADRESİ GİRİN"
        case .driveFile:   return "DRIVE DOSYA ADI GİRİN"
        case .phoneOrName: return "KİŞİ ADI / NUMARA GİRİN"
        case .general:     return "METİN GİRİŞİ"
        }
    }

    var defaultPlaceholder: String {
        switch self {
        case .email:       return "ornek@domain.com"
        case .driveFile:   return "Dosya adı (örn: 2026 Hesaplar)"
        case .phoneOrName: return "Kişi adı veya 05xx xxx xx xx"
        case .general:     return "Komut veya spesifik metni yazın..."
        }
    }

    var iconName: String {
        switch self {
        case .email:       return "envelope.fill"
        case .driveFile:   return "externaldrive.fill.badge.icloud"
        case .phoneOrName: return "person.crop.circle.badge.questionmark"
        case .general:     return "keyboard.fill"
        }
    }
}

struct ManualInputPrompt: Identifiable, Equatable {
    let id = UUID()
    let kind: ManualInputKind
    let title: String
    let subtitle: String
    let placeholder: String
    let initialText: String
    let suggestions: [String]
}

// MARK: - Gemini Service

final class GeminiService {

    /// Kullanıcının Entegrasyonlar'dan girdiği Yapay Zeka Anahtarı (yüz modu bu anahtar olmadan açılmaz)
    var apiKey: String { AIKeyStore.key }
    private let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"
    private let fallbackEndpoint = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent"
    private let ttsEndpoint = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-preview-tts:generateContent"
    
    // Fotoğraf çekme closure'u (ViewModel'dan atanacak)
    var onTakePhoto: (() async -> Data?)?
    // Galeriye KAYDETMEDEN analiz için kamera görüntüsü (ViewModel'dan atanacak)
    var onCaptureForAnalysis: (() async -> Data?)?
    // 1. sesli denemede spesifik isim/numara/adres/dosya başarısız olursa ekranda yazma kutusu açar
    var onRequestManualInput: ((ManualInputPrompt) -> Void)?
    /// Kullanıcı "son çektiğin fotoyu / galerideki son fotoyu yükle" dediğinde kamera açmadan galerideki son fotoğrafı kullanır
    var preferExistingPhotoInCurrentTurn: Bool = false

    // Konuşma geçmişi (multi-turn)
    private var history: [[String: Any]] = []

    /// Yüz modu açıkken yeni gelen son e-posta (kullanıcının "yanıtla", "bir şey yapma" gibi komutları için)
    var lastIncomingEmail: GmailIncomingEmail?

    private var systemPrompt: String {
        var prompt = PhoneIntegrationService.currentDateLine() + "\n" + baseSystemPrompt + "\n\n" + GismoMemoryService.shared.promptContext()
        if let mail = lastIncomingEmail {
            prompt += """
            
            [SON GELEN AKTİF E-POSTA BİLGİSİ]
            - Gönderen: \(mail.senderName) <\(mail.senderEmail)>
            - Konu: \(mail.subject)
            - İçerik Özeti: \(String(mail.bodyText.prefix(600)))
            Kullanıcı "yanıtla", "cevap yaz" derse bu e-postayı baz al (`replyToLastEmail` aracını kullan). "Tamam bir şey yapma", "kalsın", "gerek yok" derse `dismissLastEmail` aracını çağır veya nazikçe bir şey yapmayacağını söyle.
            """
        }
        return prompt
    }

    private let baseSystemPrompt = """
    Sen Gismo, sevimli ve empatik bir Türkçe konuşan robot yardımcısın. Kısa yanıtlar ver (max 2 cümle).
    Her yanıtın sonuna MUTLAKA şu etiketi ekle (başka hiçbir şey ekleme):
    ###EMO:duygu|süre|MOV:komutlar###

    Duygular: neutral, happy, veryHappy, sad, angry, thoughtful, surprised, listening, sleeping
    Süre: saniye (0=kalıcı)
    MOV: F=İleri,B=Geri,L=Sol,R=Sağ,S=Dur — max 1.5sn toplam, S ile bitir

    KABİLİYETLERİN: konuşma, robot hareketi, fotoğraf çekme, uyku modu, GMAIL (e-posta okuma, arama, özetleme, gönderme, yeni gelen e-postayı anons edip yanıtlama, ekli dosya gönderme), GOOGLE DRIVE (dosya arama, son dosyaları listeleme, dosya/PDF/doküman/tablo açıp okuma ve özetleme, yeni metin/not dosyası oluşturup yükleme, Drive'dan dosya alıp mail atma), GOOGLE PHOTOS (fotoğraf yükleme, fotoğrafları listeleme/arama, buluttan fotoğraf indirip galeriye kaydetme veya mail atma), SMS GÖNDERME ve REHBER SORGULAMA.
    ÖNEMLİ GÜVENLİK KURALI: Kullanıcı SMS veya E-posta göndermek/yanıtlamak istediğinde ASLA ilgili aracı anında çalıştırma! Önce alıcıyı ve mesajı kullanıcıya tekrar et ve "Mesajı gönderiyorum, onaylıyor musun?" diye sor. SADECE kullanıcı "evet, onayla, gönder" gibi onaylayıcı bir cevap verirse `sendSMS`, `sendEmail` veya `replyToLastEmail` aracını çalıştır.
    YENİ GELEN MAİL BİLDİRİMİ KURALI:
    - Sana `[SİSTEM BİLDİRİMİ - YENİ E-POSTA GELDİ]` geldiğinde, kullanıcıya "Bir mail geldi!" diyerek kimden geldiğini ve ne hakkında olduğunu ÇOK KISA ve DOĞAL bir biçimde (1-2 cümleyle) özetle, ardından "Yanıtlamamı ister misin?" diye sor.
    - Kullanıcı bu mail için "tamam bir şey yapma", "kalsın", "gerek yok" derse `dismissLastEmail` aracını kullan ve kısaca "Tamamdır, bir şey yapmıyorum." de.
    - Kullanıcı "yanıtla" der ama ne yazacağını söylemezse "Ne yazmamı istersin?" diye sor; ne yazacağını söylerse kısaca tekrar edip onay iste ve onaylayınca `replyToLastEmail` aracını çağır.
    - Kullanıcı "artık gelen mailleri okuma", "gelen mailleri bildirme", "mail bildirimlerini kapat" derse `setIncomingMailNotifications` aracını `enabled: false` ile çağır. "Gelen mailleri bana bildir", "yeni mail gelirse haber ver", "mail bildirimlerini aç" derse `setIncomingMailNotifications` aracını `enabled: true` ile çağır.
    Kullanıcı sana belirli bir santimetre (cm) gitmeni söylerse (Örn: "1 cm ileri gel", "5 cm sola dön"), robotun tekerlek ataletini (kaymasını) hesaba katarak her 1 cm için tam olarak 15ms hesapla (Örn: 1 cm = 15, 2 cm = 30, 5 cm = 75). Robotun sarsılmaması için hareket sürelerini daima çok düşük tut.
    Eğer kullanıcı "etrafında tam tur dön", "360 derece dön" gibi bir şey isterse, tek bir yöne 1000ms güç vererek bunu başarabilirsin (Örn: MOV:L,1000;S).
    \(PhoneIntegrationService.promptSummary)
    Kullanıcı Drive'daki bir dosyayı okumak/özetlemek isterse doğrudan `readDriveFile` aracına `fileName` (veya biliyorsan `fileId`) vererek tek adımda okuyabilirsin.
    DRIVE BENZER DOSYA VE MANUEL METİN KUTUSU KURALLARI:
    1) Drive'da dosya ararken ASLA kullanıcıdan birebir tam dosya adını ezbere söylemesini bekleme! `searchDrive`, `readDriveFile` veya `emailDriveFile` sana `[BENZER DRIVE DOSYALARI BULUNDU]` dönerse, bulduğun benzer dosya isimlerini kullanıcıya doğal bir şekilde söyleyip "Drive'da şu benzer dosyaları buldum: [Dosya 1] mi yoksa [Dosya 2] mi?" diye sor. Kullanıcı hangisi olduğunu söylediğinde o dosyanın tam adını veya ID'sini kullan.
    2) E-posta adresi, Drive dosya adı, kişi adı veya telefon numarası gibi spesifik girdilerde 1. sesli deneme başarısız olursa (örneğin adres/dosya/kişi bulunamazsa, e-posta adresi bozuk çevrilirse veya kullanıcı "hayır yanlış anladın / o adres değil / o dosya değil" derse), kullanıcıyı tekrar sesle söylemeye zorlama; hemen `requestManualTextInput` aracını çağırarak ekranda yazma kutusunu aç ve "Ekranda açtığım kutuya el ile yazabilirsin." de.
    Kullanıcı Drive'a not/özet/metin kaydetmek isterse `createDriveFile` aracını kullan.
    FOTOĞRAF KURALLARI:
    1) Kullanıcı sadece "fotoğrafımı çek", "selfie çek", "resmimi çek" derse (yalnızca galeriye kaydetmek için) doğrudan `takePhoto` aracını kullan.
    2) Kullanıcı "fotoğraf çekip Drive'a yükle" derse `uploadPhotoToDrive(useLastPhoto: false)` aracını kullan.
    3) Kullanıcı "SON ÇEKTİĞİN fotoğrafı / az önceki fotoğrafı / galerideki son fotoğrafı Drive'a yükle" derse ASLA yeniden fotoğraf çekme! `uploadPhotoToDrive(useLastPhoto: true)` aracını kullan.
    4) Kullanıcı "fotoğraf çekip Google Fotoğraflar'a yükle" derse `uploadPhotoToGooglePhotos(useLastPhoto: false)`, "son çektiğin / galerideki son fotoğrafı Google Fotoğraflar'a yükle" derse `uploadPhotoToGooglePhotos(useLastPhoto: true)` aracını kullan.
    5) Kullanıcı "fotoğraf çekip şu adrese mail at" derse `emailPhoto(useLastPhoto: false)`, "son çektiğin / galerideki fotoğrafı şu adrese mail at" derse `emailPhoto(useLastPhoto: true)` aracını kullan.
    6) Google Fotoğraflar'da arama/listeleme için `searchGooglePhotos`, buluttan fotoğraf almak/indirmek için `downloadPhotoFromGoogle` aracını kullan.

    ÖNEMLİ KURAL: Kullanıcı "sola git", "sağa dön" gibi ÖZEL BİR HAREKET İSTEMEDİKÇE ASLA MOV: parametresi gönderme! Sadece duyguyu (EMO) gönder, robot varsayılan kafa sallama ve sevinç hareketlerini kendi yapacaktır. (Örn: Sadece ###EMO:happy|3.0### yaz ve bırak).

    Örnekler:
    Harika! ###EMO:veryHappy|4.0###
    Üzgünüm... ###EMO:sad|5.0###
    Tamam, 5 cm sola dönüyorum. ###EMO:happy|3.0|MOV:L,75;S###
    """

    static let sharedFunctionDeclarations: [[String: Any]] = baseFunctionDeclarations + PhoneIntegrationService.functionDeclarations + GismoMemoryService.functionDeclarations

    private static let baseFunctionDeclarations: [[String: Any]] = [
        [
            "name": "moveRobot",
            "description": "Robotu fiziksel olarak hareket ettirir (F=İleri, B=Geri, L=Sol, R=Sağ, S=Dur). Her 1 cm için 15ms kullan.",
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "sequence": [
                        "type": "STRING",
                        "description": "Hareket sekansı, örn: 'F,45;S' veya 'L,1000;S'"
                    ]
                ],
                "required": ["sequence"]
            ]
        ],
        [
            "name": "sendEmail",
            "description": "Kullanıcının adına düz e-posta gönderir.",
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "recipient": ["type": "STRING", "description": "Alıcının e-posta adresi."],
                    "subject": ["type": "STRING", "description": "E-postanın konusu."],
                    "body": ["type": "STRING", "description": "E-postanın içeriği."]
                ],
                "required": ["recipient", "subject", "body"]
            ]
        ],
        [
            "name": "replyToLastEmail",
            "description": "Az önce gelen ve kullanıcıya özetlenen son e-postaya aynı konu/thread üzerinden yanıt gönderir.",
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "body": ["type": "STRING", "description": "Gönderilecek yanıt mesajı."]
                ],
                "required": ["body"]
            ]
        ],
        [
            "name": "dismissLastEmail",
            "description": "Kullanıcı yeni gelen e-posta için 'tamam bir şey yapma', 'kalsın', 'gerek yok' dediğinde e-postayı okundu olarak işaretler ve kapatır.",
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "markRead": ["type": "BOOLEAN", "description": "Okundu olarak işaretlensin mi (varsayılan true)."]
                ]
            ]
        ],
        [
            "name": "setIncomingMailNotifications",
            "description": "Kullanıcı 'artık gelen mailleri okuma / bildirme / kapat' veya 'gelen mailleri bana bildir / sesli oku / aç' dediğinde yeni gelen e-postaların otomatik sesli bildirimini açar veya kapatır.",
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "enabled": ["type": "BOOLEAN", "description": "Yeni gelen mailler sesli bildirilsin mi? (true = aç / bildir, false = kapat / okuma)."]
                ],
                "required": ["enabled"]
            ]
        ],
        [
            "name": "readEmails",
            "description": "Kullanıcının Gmail gelen kutusundaki e-postaları okur, arar ve tam içeriklerini özetlemek için getirir.",
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "count": ["type": "INTEGER", "description": "Kaç adet mail getirileceği (Varsayılan 3)."],
                    "query": ["type": "STRING", "description": "Opsiyonel Gmail arama filtresi (örn: 'from:Ahmet', 'is:unread', 'fatura'). Boş bırakılırsa son gelen mailleri getirir."]
                ]
            ]
        ],
        [
            "name": "searchDrive",
            "description": "Google Drive üzerinde dosya araması yapar veya son dosyaları listeler.",
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "query": ["type": "STRING", "description": "Aranacak dosya adı (örn: 'proje özeti'). Tüm son dosyaları listelemek için boş veya 'son' gönderin."]
                ]
            ]
        ],
        [
            "name": "readDriveFile",
            "description": "Google Drive'daki bir dosyayı (Google Docs, E-Tablo, Sunu, PDF, TXT, CSV) dosya adı veya ID ile bulup açar ve içeriğini okur.",
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "fileName": ["type": "STRING", "description": "Okunacak dosyanın adı (örn: '2026 Hesaplar' veya 'rapor.pdf')."],
                    "fileId": ["type": "STRING", "description": "Biliniyorsa dosyanın Google Drive ID'si."]
                ]
            ]
        ],
        [
            "name": "createDriveFile",
            "description": "Google Drive'da yeni bir metin/not/özet dosyası oluşturur ve yükler.",
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "fileName": ["type": "STRING", "description": "Oluşturulacak dosyanın adı (örn: 'toplanti_notlari.txt')."],
                    "content": ["type": "STRING", "description": "Dosyanın içine yazılacak metin içeriği."]
                ],
                "required": ["fileName", "content"]
            ]
        ],
        [
            "name": "emailDriveFile",
            "description": "Google Drive'daki bir dosyayı (ID veya dosya adıyla) alıp belirtilen e-posta adresine ek (attachment) olarak gönderir.",
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "fileName": ["type": "STRING", "description": "Gönderilecek Drive dosyasının adı."],
                    "fileId": ["type": "STRING", "description": "Biliniyorsa Drive dosyasının ID'si."],
                    "recipient": ["type": "STRING", "description": "Alıcı e-posta adresi."],
                    "subject": ["type": "STRING", "description": "E-posta konusu."],
                    "body": ["type": "STRING", "description": "E-posta mesaj metni."]
                ],
                "required": ["recipient", "subject", "body"]
            ]
        ],
        [
            "name": "takePhoto",
            "description": "Kameradan anlık fotoğraf/selfie çeker, ekranda önizlemesini gösterir ve YALNIZCA telefonun fotoğraf galerisine (Film Rulosu) kaydeder. Buluta veya e-postaya göndermez.",
            "parameters": [
                "type": "OBJECT",
                "properties": [:]
            ]
        ],
        [
            "name": "uploadPhotoToDrive",
            "description": "Google Drive'a fotoğraf yükler. Kullanıcı 'son çektiğin fotoyu / galerideki son fotoyu yükle' dediyse useLastPhoto=true gönder (tekrar fotoğraf çekmez, galerideki son fotoğrafı yükler). 'Fotoğraf çekip yükle' dediyse useLastPhoto=false gönder.",
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "fileName": ["type": "STRING", "description": "Kaydedilecek fotoğrafın adı (opsiyonel, örn: gismo_selfie.jpg)."],
                    "useLastPhoto": ["type": "BOOLEAN", "description": "true = yeni fotoğraf çekmeden galerideki/son çekilen fotoğrafı yükler. false = kameradan yeni fotoğraf çekip yükler."]
                ]
            ]
        ],
        [
            "name": "uploadPhotoToGooglePhotos",
            "description": "Google Fotoğraflar albümüne ve Drive'a fotoğraf yükler. Kullanıcı 'son çektiğin / galerideki son fotoyu yükle' dediyse useLastPhoto=true gönder (tekrar fotoğraf çekmez).",
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "fileName": ["type": "STRING", "description": "Fotoğraf dosya adı (opsiyonel, örn: gismo_ani.jpg)."],
                    "description": ["type": "STRING", "description": "Fotoğraf açıklaması."],
                    "useLastPhoto": ["type": "BOOLEAN", "description": "true = yeni fotoğraf çekmeden galerideki/son çekilen fotoğrafı yükler. false = kameradan yeni fotoğraf çekip yükler."]
                ]
            ]
        ],
        [
            "name": "searchGooglePhotos",
            "description": "Google Fotoğraflar (Google Photos) ve Drive'daki fotoğrafları listeler veya isimle arar.",
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "query": ["type": "STRING", "description": "Aranacak fotoğraf adı (boş bırakılırsa son fotoğrafları listeler)."],
                    "count": ["type": "INTEGER", "description": "Kaç fotoğraf listeleneceği (Varsayılan 5)."]
                ]
            ]
        ],
        [
            "name": "downloadPhotoFromGoogle",
            "description": "Google Fotoğraflar veya Drive'dan bir fotoğrafı indirip telefon galerisine kaydeder ve/veya e-posta olarak gönderir.",
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "photoIdOrName": ["type": "STRING", "description": "Fotoğrafın adı, ID'si veya en son fotoğraf için 'son'."],
                    "emailRecipient": ["type": "STRING", "description": "Opsiyonel: Fotoğrafın gönderileceği e-posta adresi."]
                ]
            ]
        ],
        [
            "name": "emailPhoto",
            "description": "Fotoğrafı belirtilen e-posta adresine ek (attachment) olarak gönderir. Kullanıcı 'son çektiğin / galerideki son fotoğrafı mail at' dediyse useLastPhoto=true gönder (tekrar fotoğraf çekmez).",
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "recipient": ["type": "STRING", "description": "Alıcı e-posta adresi."],
                    "subject": ["type": "STRING", "description": "E-posta konusu (opsiyonel)."],
                    "body": ["type": "STRING", "description": "E-posta metni (opsiyonel)."],
                    "useLastPhoto": ["type": "BOOLEAN", "description": "true = yeni fotoğraf çekmeden galerideki/son çekilen fotoğrafı gönderir. false = kameradan yeni fotoğraf çekip gönderir."]
                ],
                "required": ["recipient"]
            ]
        ],
        [
            "name": "sendSMS",
            "description": "Kullanıcının adına belirtilen kişiye veya telefon numarasına kısa mesaj (SMS) gönderir.",
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "recipientName": ["type": "STRING", "description": "Kişinin rehberdeki adı (Örn: Hakan, Annem)"],
                    "phoneNumber": ["type": "STRING", "description": "Alıcının telefon numarası (örn: 05xxxxxxxxx)"],
                    "message": ["type": "STRING", "description": "Gönderilecek SMS metni."]
                ],
                "required": ["message"]
            ]
        ],
        [
            "name": "searchContact",
            "description": "Kullanıcının telefon rehberinde bir kişiyi arar ve numarasını getirir.",
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "name": ["type": "STRING", "description": "Rehberde aranacak kişinin adı (Örn: Ömer, Annem)"]
                ],
                "required": ["name"]
            ]
        ],
        [
            "name": "requestManualTextInput",
            "description": "E-posta adresi, Drive dosya adı, kişi adı veya telefon numarası gibi spesifik girdiler 1. sesli denemede yanlış anlaşıldığında, bulunamadığında veya kullanıcı 'hayır yanlış' dediğinde ekranda kullanıcının el ile yazabileceği bir metin kutusu açar.",
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "fieldType": [
                        "type": "STRING",
                        "description": "Girdi türü: 'email' (e-posta adresi), 'driveFile' (Drive dosya adı), 'phoneOrName' (kişi adı veya telefon numarası), 'general' (diğer spesifik metin)."
                    ],
                    "reason": [
                        "type": "STRING",
                        "description": "Kullanıcıya gösterilecek kısa açıklama (örn: 'E-posta adresini el ile yazın')."
                    ],
                    "initialValue": [
                        "type": "STRING",
                        "description": "Varsa sesli algılanan taslak metin."
                    ]
                ],
                "required": ["fieldType"]
            ]
        ]
    ]

    func send(_ userText: String, robotName: String, includeTools: Bool = true) async throws -> GeminiMessage {
        let userMessage: [String: Any] = [
            "role": "user",
            "parts": [["text": userText]]
        ]

        var contents: [[String: Any]] = history
        contents.append(userMessage)
        
        var body: [String: Any] = [
            "system_instruction": [
                "parts": [["text": systemPrompt]]
            ],
            "contents": contents,
            "generationConfig": [
                "temperature": 0.85,
                "maxOutputTokens": 600
            ]
        ]
        if includeTools {
            body["tools"] = [
                [
                    "function_declarations": Self.sharedFunctionDeclarations
                ]
            ]
        }

        guard let url = URL(string: "\(endpoint)?key=\(apiKey)") else {
            throw GeminiError.invalidURL
        }

        let requestBodyData = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15.0 // Gemini API takılmasını önlemek için zaman aşımı
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = requestBodyData

        var (data, response) = try await URLSession.shared.data(for: request)

        guard var httpResponse = response as? HTTPURLResponse else {
            throw GeminiError.httpError(0, "Sunucu yanıt vermedi")
        }

        // Kota (429) veya geçici servis hatasında (503/404) yedek modeli dene
        if [404, 429, 503].contains(httpResponse.statusCode),
           let fallbackURL = URL(string: "\(fallbackEndpoint)?key=\(apiKey)") {
            var retryReq = URLRequest(url: fallbackURL)
            retryReq.httpMethod = "POST"
            retryReq.timeoutInterval = 15.0
            retryReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            retryReq.httpBody = requestBodyData
            if let (retryData, retryResp) = try? await URLSession.shared.data(for: retryReq),
               let retryHttp = retryResp as? HTTPURLResponse {
                data = retryData
                httpResponse = retryHttp
            }
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let detail = Self.extractAPIErrorMessage(from: data)
            print("[Gemini] HTTP \(httpResponse.statusCode): \(detail)")
            throw GeminiError.httpError(httpResponse.statusCode, detail)
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = json["candidates"] as? [[String: Any]],
            let first = candidates.first,
            let content = first["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]],
            let firstPart = parts.first
        else {
            throw GeminiError.parseError
        }

        // Function Calling kontrolü
        if let functionCall = parts.compactMap({ $0["functionCall"] as? [String: Any] }).first,
           let name = functionCall["name"] as? String {
            let args = functionCall["args"] as? [String: Any] ?? [:]
            print("[Gemini] Function Call Yakalandı: \(name)")

            history.append(userMessage)
            let (toolResult, motorSteps) = await executeLiveTool(name: name, args: args)

            // Okuma/Arama araçlarında sonucu Gemini'ye özetlet (includeTools: false ile sonsuz döngüyü önle)
            let summarizationTools: Set<String> = Set(["readEmails", "searchDrive", "readDriveFile", "searchGooglePhotos", "recallMemories"]).union(PhoneIntegrationService.readOnlyToolNames)
            if summarizationTools.contains(name) {
                let summaryPrompt = """
                Kullanıcının isteği: \(userText)
                \(name) aracından gelen veri:
                \(toolResult)

                Lütfen bu bilgiyi kullanıcıya doğal, samimi ve kısa (1-2 cümle) Türkçe ile özetle.
                """
                return try await send(summaryPrompt, robotName: robotName, includeTools: false)
            }

            let isError = toolResult.lowercased().contains("hata") || toolResult.lowercased().contains("bulunamadı") || toolResult.lowercased().contains("değil") || toolResult.lowercased().contains("yok")
            let emotion: GismoEmotionName = isError ? .sad : .veryHappy
            history.append(["role": "model", "parts": [["text": toolResult]]])
            return GeminiMessage(text: toolResult, emotion: emotion, duration: 4.0, motorSequence: motorSteps)
        }

        // Normal Metin Yanıtı
        guard let rawText = firstPart["text"] as? String else {
            throw GeminiError.parseError
        }

        print("[Gemini] RAW: \(rawText)")

        history.append(userMessage)
        history.append([
            "role": "model",
            "parts": [["text": rawText]]
        ])

        if history.count > 20 {
            history = Array(history.dropFirst(2))
        }

        return parseResponse(rawText)
    }

    func resetHistory() {
        history = []
    }

    func recordTurnInHistory(userText: String, modelText: String) {
        history.append(["role": "user", "parts": [["text": userText]]])
        history.append(["role": "model", "parts": [["text": modelText]]])
        if history.count > 20 {
            history = Array(history.dropFirst(2))
        }
    }

    // MARK: - Gemini TTS (Natural Turkish Neural Speech Synthesis)

    func synthesizeSpeech(text: String, emotion: GismoEmotionName) async throws -> (data: Data, mimeType: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GeminiError.parseError
        }

        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": trimmed]
                    ]
                ]
            ],
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": [
                    "languageCode": "tr-TR",
                    "voiceConfig": [
                        "prebuiltVoiceConfig": [
                            "voiceName": "Aoede" // Doğal, berrak ve akıcı yapay zeka asistan sesi
                        ]
                    ]
                ]
            ]
        ]

        guard let url = URL(string: "\(ttsEndpoint)?key=\(apiKey)") else {
            throw GeminiError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10.0
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let detail = Self.extractAPIErrorMessage(from: data)
            print("[Gemini TTS] HTTP \(status): \(detail)")
            throw GeminiError.httpError(status, detail)
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = json["candidates"] as? [[String: Any]],
            let first = candidates.first,
            let content = first["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]]
        else {
            throw GeminiError.parseError
        }

        for part in parts {
            let inlineData = (part["inlineData"] as? [String: Any]) ?? (part["inline_data"] as? [String: Any])
            if let inlineData,
               let base64String = inlineData["data"] as? String,
               let audioData = Data(base64Encoded: base64String) {
                let mimeType = (inlineData["mimeType"] as? String)
                    ?? (inlineData["mime_type"] as? String)
                    ?? "audio/L16;codec=pcm;rate=24000"
                return (audioData, mimeType)
            }
        }

        throw GeminiError.parseError
    }

    // MARK: - Private

    private func parseResponse(_ raw: String) -> GeminiMessage {
        // ###EMO:duygu|süre|MOV:komutlar### formatını yakala
        let pattern = #"###EMO:(\w+)\|(\d+(?:\.\d+)?)(?:\|MOV:([^#]*))?###"#

        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let emotionRange  = Range(match.range(at: 1), in: raw),
              let durationRange = Range(match.range(at: 2), in: raw)
        else {
            return GeminiMessage(text: raw, emotion: .neutral, duration: 0, motorSequence: [])
        }

        let emotionString  = String(raw[emotionRange])
        let durationString = String(raw[durationRange])
        let duration       = Double(durationString) ?? 0
        let emotion        = GismoEmotionName(rawValue: emotionString) ?? .neutral

        // Motor sekansı parse et
        var motorSequence: [MotorStep] = []
        if let movRange = Range(match.range(at: 3), in: raw) {
            let movString = String(raw[movRange])
            motorSequence = parseMotorSequence(movString)
        }

        // Tag'i metinden temizle
        let fullRange = Range(match.range, in: raw)!
        let cleanText = raw.replacingCharacters(in: fullRange, with: "").trimmingCharacters(in: .whitespaces)

        return GeminiMessage(text: cleanText, emotion: emotion, duration: duration, motorSequence: motorSequence)
    }

    private func parseMotorSequence(_ movString: String) -> [MotorStep] {
        // Format: "F,300;B,200;S" veya "S"
        return movString.split(separator: ";").compactMap { part in
            let components = part.split(separator: ",")
            guard let cmdStr = components.first else { return nil }
            let cmd = String(cmdStr).trimmingCharacters(in: .whitespaces).uppercased()
            let durationMs = components.count > 1 ? Int(components[1].trimmingCharacters(in: .whitespaces)) ?? 200 : 0

            guard let robotCommand = RobotCommand(rawValue: cmd) else { return nil }
            return MotorStep(command: robotCommand, durationMs: durationMs)
        }
    }

    /// Hem Gemini Live API (WebSocket) hem de Gemini REST API üzerinden gelen tüm araç çağrılarını çalıştırır
    func executeLiveTool(name: String, args: [String: Any]) async -> (result: String, motorSequence: [MotorStep]) {
        switch name {
        case "moveRobot":
            let movStr = (args["sequence"] as? String) ?? "S"
            let steps = parseMotorSequence(movStr)
            return ("Robot hareket komutu uygulandı: \(movStr)", steps)

        case "sendEmail":
            let rawRecipient = args["recipient"] as? String ?? ""
            let recipient = Self.normalizeEmailAddress(rawRecipient)
            let subject = args["subject"] as? String ?? "Gismo Mesajı"
            let body = args["body"] as? String ?? ""
            guard Self.isValidEmailFormat(recipient) else {
                triggerManualInput(
                    kind: .email,
                    subtitle: "E-posta adresi sesle tam anlaşılamadı. Lütfen adresi aşağıya yazın:",
                    initialText: recipient
                )
                return ("E-posta adresi tam anlaşılamadı. Kullanıcının adresi el ile girebilmesi için ekranda yazma kutusu açıldı.", [])
            }
            do {
                let success = try await GmailService.shared.sendEmail(to: recipient, subject: subject, body: body)
                if !success {
                    triggerManualInput(
                        kind: .email,
                        subtitle: "E-posta gönderilemedi. Lütfen alıcı adresini kontrol edip el ile girin:",
                        initialText: recipient
                    )
                }
                return (success ? "\(recipient) adresine e-posta başarıyla gönderildi." : "E-posta gönderilemedi, ekranda adres giriş kutusu açıldı.", [])
            } catch {
                triggerManualInput(
                    kind: .email,
                    subtitle: "E-posta gönderilirken adres hatası oluştu. Lütfen adresi el ile yazın:",
                    initialText: recipient
                )
                return ("E-posta hatası: \(error.localizedDescription). Ekranda adres yazma kutusu açıldı.", [])
            }

        case "replyToLastEmail":
            let body = (args["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else {
                return ("Yanıt metni boş olamaz.", [])
            }
            guard let incoming = lastIncomingEmail else {
                return ("Yanıtlanacak son gelen bir e-posta bulunamadı.", [])
            }
            do {
                let success = try await GmailService.shared.replyToEmail(incoming, body: body)
                if success {
                    return ("\(incoming.senderName) (\(incoming.senderEmail)) kişisine yanıtınız başarıyla gönderildi.", [])
                }
                return ("Yanıt gönderilemedi.", [])
            } catch {
                return ("Yanıt gönderme hatası: \(error.localizedDescription)", [])
            }

        case "dismissLastEmail":
            let markRead = (args["markRead"] as? Bool) ?? true
            if markRead, let incoming = lastIncomingEmail {
                try? await GmailService.shared.markEmailAsRead(messageId: incoming.id)
            }
            return ("Tamamdır, gelen e-posta için herhangi bir işlem yapılmadı.", [])

        case "setIncomingMailNotifications":
            let enabled = (args["enabled"] as? Bool) ?? true
            GmailService.shared.isIncomingMailAnnouncementEnabled = enabled
            if enabled {
                return ("Gelen e-posta sesli bildirimleri açıldı. Artık yeni bir mail geldiğinde sana sesli olarak haber vereceğim.", [])
            } else {
                return ("Gelen e-posta sesli bildirimleri kapatıldı. Artık sen istemedikçe yeni gelen mailleri sesli okumayacağım.", [])
            }

        case "readEmails":
            let count = args["count"] as? Int ?? 3
            let query = args["query"] as? String
            do {
                let emails = try await GmailService.shared.getLatestEmails(count: count, query: query)
                return (emails, [])
            } catch {
                return ("Mailler okunamadı: \(error.localizedDescription)", [])
            }

        case "searchDrive":
            let query = args["query"] as? String ?? ""
            do {
                let result = try await GoogleDriveService.shared.searchFiles(query: query)
                if result.contains("[DRIVE DOSYASI BULUNAMADI]") {
                    let suggestions = GoogleDriveService.shared.lastSuggestedFiles.map { $0.name }
                    triggerManualInput(
                        kind: .driveFile,
                        subtitle: "'\(query)' adında bir dosya bulunamadı. Dosya adını aşağıya yazabilir veya listeden seçebilirsiniz:",
                        initialText: query,
                        suggestions: suggestions
                    )
                }
                return (result, [])
            } catch {
                triggerManualInput(
                    kind: .driveFile,
                    subtitle: "Drive dosya adını el ile yazabilirsiniz:",
                    initialText: query
                )
                return ("Drive araması başarısız: \(error.localizedDescription)", [])
            }

        case "readDriveFile":
            let fileId = args["fileId"] as? String ?? ""
            let fileName = args["fileName"] as? String ?? ""
            do {
                let content = try await GoogleDriveService.shared.readTextFile(fileId: fileId, fileName: fileName)
                return (content, [])
            } catch {
                let suggestions = GoogleDriveService.shared.lastSuggestedFiles.map { $0.name }
                triggerManualInput(
                    kind: .driveFile,
                    subtitle: "'\(fileName.isEmpty ? fileId : fileName)' dosyası bulunamadı. Lütfen dosya adını yazın veya önerilerden seçin:",
                    initialText: fileName,
                    suggestions: suggestions
                )
                return ("Dosya bulunamadı (\(error.localizedDescription)). Kullanıcının dosya adını el ile yazabilmesi için ekranda metin kutusu açıldı.", [])
            }

        case "createDriveFile":
            let fileName = args["fileName"] as? String ?? "gismo_not.txt"
            let content = args["content"] as? String ?? ""
            do {
                let id = try await GoogleDriveService.shared.createTextFile(name: fileName, content: content)
                return ("'\(fileName)' adlı dosya Google Drive'a başarıyla oluşturuldu (ID: \(id)).", [])
            } catch {
                return ("Drive dosyası oluşturulamadı: \(error.localizedDescription)", [])
            }

        case "emailDriveFile":
            let fileId = (args["fileId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let fileNameArg = (args["fileName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let targetRef = !fileId.isEmpty ? fileId : fileNameArg
            let recipient = Self.normalizeEmailAddress(args["recipient"] as? String ?? "")
            let subject = args["subject"] as? String ?? "Google Drive Dosyası"
            let body = args["body"] as? String ?? "Merhaba, istediğiniz Google Drive dosyası ektedir."

            guard Self.isValidEmailFormat(recipient) else {
                triggerManualInput(
                    kind: .email,
                    subtitle: "Dosyanın gönderileceği e-posta adresi tam anlaşılamadı. Lütfen adresi el ile yazın:",
                    initialText: recipient
                )
                return ("Alıcı e-posta adresi geçersiz veya anlaşılamadı. Ekranda e-posta yazma kutusu açıldı.", [])
            }

            do {
                let looksLikeId = !fileId.isEmpty && !fileId.contains(" ") && fileId.count >= 18 && !fileId.contains(".")
                var resolvedTarget = targetRef
                if !looksLikeId {
                    let (exactMatch, similarFiles, _) = try await GoogleDriveService.shared.findBestAndSimilarFiles(query: targetRef, limit: 4)
                    if let exact = exactMatch {
                        resolvedTarget = exact.id
                    } else if similarFiles.count == 1, let only = similarFiles.first, GoogleDriveService.similarityScore(query: targetRef, fileName: only.name) >= 0.62 {
                        resolvedTarget = only.id
                    } else if !similarFiles.isEmpty {
                        let optionsList = similarFiles.enumerated().map { idx, item in
                            "\(idx + 1)) \(item.name) (ID: \(item.id))"
                        }.joined(separator: "\n")
                        return ("""
                        [BENZER DRIVE DOSYALARI BULUNDU - KULLANICIYA SOR]
                        '\(targetRef)' adıyla birebir tek bir dosya yerine şu benzer dosyalar bulundu:
                        \(optionsList)
                        Lütfen kullanıcıya "Drive'da şu benzer dosyaları buldum: hangi dosyayı \(recipient) adresine göndermemi istersin?" diye sor.
                        """, [])
                    }
                }

                let (data, mimeType, resolvedName) = try await GoogleDriveService.shared.downloadFileRaw(fileId: resolvedTarget, asText: false)
                _ = try await GmailService.shared.sendEmail(
                    to: recipient,
                    subject: subject,
                    body: body,
                    attachment: data,
                    attachmentName: resolvedName,
                    attachmentMimeType: mimeType
                )
                return ("Drive'daki '\(resolvedName)' dosyası \(recipient) adresine başarıyla e-posta ile gönderildi.", [])
            } catch {
                let suggestions = GoogleDriveService.shared.lastSuggestedFiles.map { $0.name }
                triggerManualInput(
                    kind: .driveFile,
                    subtitle: "Gönderilecek Drive dosyası bulunamadı. Lütfen dosya adını yazın veya listeden seçin:",
                    initialText: fileNameArg,
                    suggestions: suggestions
                )
                return ("Dosya gönderim hatası: \(error.localizedDescription). Ekranda dosya adı yazma kutusu açıldı.", [])
            }

        case "takePhoto":
            guard let onTakePhoto = onTakePhoto, let _ = await onTakePhoto() else {
                return ("Kamera erişimi yok veya fotoğraf çekilemedi.", [])
            }
            return ("Fotoğrafınız çekildi ve telefonunuzun fotoğraf galerisine kaydedildi.", [])

        case "uploadPhotoToDrive":
            let rawName = (args["fileName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let fileName = rawName.isEmpty ? "gismo_foto_\(Int(Date().timeIntervalSince1970)).jpg" : rawName
            let useLast = (args["useLastPhoto"] as? Bool == true) || preferExistingPhotoInCurrentTurn
            let photoData: Data?
            if useLast {
                photoData = await GismoCameraService.getLatestGalleryOrCapturedPhotoData()
            } else {
                photoData = await onTakePhoto?()
            }
            guard let photoData else {
                return (useLast ? "Galeride veya son çekilenler arasında yüklenecek fotoğraf bulunamadı." : "Kamera erişimi yok veya fotoğraf çekilemedi.", [])
            }
            do {
                let status = try await GooglePhotosService.shared.uploadPhoto(data: photoData, fileName: fileName)
                return (useLast ? "Galerinizdeki son fotoğraf Google Drive'a başarıyla yüklendi. (\(status))" : status, [])
            } catch {
                return ("Fotoğraf yükleme hatası: \(error.localizedDescription)", [])
            }

        case "uploadPhotoToGooglePhotos":
            let rawName = (args["fileName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let fileName = rawName.isEmpty ? "gismo_foto_\(Int(Date().timeIntervalSince1970)).jpg" : rawName
            let desc = args["description"] as? String ?? "Gismo ile çekilen fotoğraf"
            let useLast = (args["useLastPhoto"] as? Bool == true) || preferExistingPhotoInCurrentTurn
            let photoData: Data?
            if useLast {
                photoData = await GismoCameraService.getLatestGalleryOrCapturedPhotoData()
            } else {
                photoData = await onTakePhoto?()
            }
            guard let photoData else {
                return (useLast ? "Galeride veya son çekilenler arasında yüklenecek fotoğraf bulunamadı." : "Kamera erişimi yok veya fotoğraf çekilemedi.", [])
            }
            do {
                let status = try await GooglePhotosService.shared.uploadPhoto(data: photoData, fileName: fileName, description: desc)
                return (useLast ? "Galerinizdeki son fotoğraf Google Fotoğraflar'a başarıyla yüklendi." : status, [])
            } catch {
                return ("Google Fotoğraflar yükleme hatası: \(error.localizedDescription)", [])
            }

        case "searchGooglePhotos":
            let query = args["query"] as? String ?? ""
            let count = args["count"] as? Int ?? 5
            do {
                let result = try await GooglePhotosService.shared.listOrSearchPhotos(query: query, count: count)
                return (result, [])
            } catch {
                return ("Google Fotoğraflar araması başarısız: \(error.localizedDescription)", [])
            }

        case "downloadPhotoFromGoogle":
            let photoRef = args["photoIdOrName"] as? String ?? "son"
            let emailRecipient = (args["emailRecipient"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                let (imgData, imgName) = try await GooglePhotosService.shared.downloadPhoto(photoIdOrName: photoRef)
                if let image = UIImage(data: imgData) {
                    await GismoCameraService.saveToPhotoLibrary(image)
                }
                if !emailRecipient.isEmpty {
                    let cleanEmail = Self.normalizeEmailAddress(emailRecipient)
                    _ = try await GmailService.shared.sendEmail(
                        to: cleanEmail,
                        subject: "Google Fotoğraflar: \(imgName)",
                        body: "İstediğiniz '\(imgName)' fotoğrafı ektedir.",
                        attachment: imgData,
                        attachmentName: imgName,
                        attachmentMimeType: "image/jpeg"
                    )
                    return ("'\(imgName)' fotoğrafı buluttan indirildi, telefon galerisine kaydedildi ve \(cleanEmail) adresine e-posta ile gönderildi.", [])
                }
                return ("'\(imgName)' fotoğrafı Google hesabından indirildi ve telefon galerisine kaydedildi.", [])
            } catch {
                return ("Fotoğraf indirme hatası: \(error.localizedDescription)", [])
            }

        case "emailPhoto":
            let recipient = Self.normalizeEmailAddress(args["recipient"] as? String ?? "")
            guard Self.isValidEmailFormat(recipient) else {
                triggerManualInput(
                    kind: .email,
                    subtitle: "Fotoğrafın gönderileceği e-posta adresini aşağıya yazın:",
                    initialText: recipient
                )
                return ("Fotoğrafın gönderileceği e-posta adresi tam anlaşılamadı. Ekranda e-posta yazma kutusu açıldı.", [])
            }
            let subject = (args["subject"] as? String)?.isEmpty == false ? (args["subject"] as! String) : "Gismo'dan Fotoğraf"
            let body = (args["body"] as? String)?.isEmpty == false ? (args["body"] as! String) : "Merhaba, Gismo ile fotoğrafınız ektedir."
            let useLast = (args["useLastPhoto"] as? Bool == true) || preferExistingPhotoInCurrentTurn
            let photoData: Data?
            if useLast {
                photoData = await GismoCameraService.getLatestGalleryOrCapturedPhotoData()
            } else {
                photoData = await onTakePhoto?()
            }
            guard let photoData else {
                return (useLast ? "Galeride gönderilecek fotoğraf bulunamadı." : "Kamera erişimi yok, fotoğraf çekilemedi.", [])
            }
            do {
                _ = try await GmailService.shared.sendEmail(to: recipient, subject: subject, body: body, attachment: photoData)
                return (useLast ? "Galerinizdeki son fotoğraf \(recipient) adresine e-posta olarak gönderildi." : "Fotoğrafınız çekildi, galeriye kaydedildi ve \(recipient) adresine e-posta olarak gönderildi.", [])
            } catch {
                triggerManualInput(
                    kind: .email,
                    subtitle: "Fotoğraf gönderilirken e-posta adresi hatası oluştu. Lütfen adresi el ile girin:",
                    initialText: recipient
                )
                return ("Fotoğraf e-posta hatası: \(error.localizedDescription). Ekranda yazma kutusu açıldı.", [])
            }

        case "sendSMS":
            let isSmsActive = UserDefaults.standard.bool(forKey: "isSmsActive")
            guard isSmsActive else {
                return ("SMS entegrasyonu aktif değil. Lütfen Entegrasyonlar menüsünden SMS'i açın.", [])
            }
            let message = args["message"] as? String ?? ""
            let phoneFromArgs = args["phoneNumber"] as? String
            let nameFromArgs = args["recipientName"] as? String
            var targetNumber: String? = nil

            if let contactName = nameFromArgs, !contactName.isEmpty {
                targetNumber = try? await SMSService.shared.searchContact(by: contactName)
            } else if let p = phoneFromArgs, !p.isEmpty {
                targetNumber = p
            }

            guard let finalNumber = targetNumber else {
                triggerManualInput(
                    kind: .phoneOrName,
                    subtitle: "Alıcı kişi rehberde bulunamadı. Lütfen kişi adını veya telefon numarasını el ile yazın:",
                    initialText: nameFromArgs ?? phoneFromArgs ?? ""
                )
                return ("Alıcı telefon numarası rehberde bulunamadı. Kullanıcının el ile girmesi için ekranda metin kutusu açıldı.", [])
            }
            do {
                _ = try await SMSService.shared.sendSMS(to: finalNumber, message: message)
                return ("SMS başarıyla gönderildi.", [])
            } catch {
                return ("SMS gönderim hatası: \(error.localizedDescription)", [])
            }

        case "searchContact":
            let contactName = args["name"] as? String ?? ""
            do {
                if let foundNumber = try await SMSService.shared.searchContact(by: contactName) {
                    return ("\(contactName) kişisinin numarası: \(foundNumber)", [])
                }
                triggerManualInput(
                    kind: .phoneOrName,
                    subtitle: "'\(contactName)' rehberde bulunamadı. Kişi adını veya telefon numarasını el ile yazabilirsiniz:",
                    initialText: contactName
                )
                return ("Rehberde '\(contactName)' bulunamadı. Ekranda isim/numara yazma kutusu açıldı.", [])
            } catch {
                return ("Rehber erişim hatası: \(error.localizedDescription)", [])
            }

        case "requestManualTextInput":
            let fieldTypeRaw = (args["fieldType"] as? String ?? "general").trimmingCharacters(in: .whitespacesAndNewlines)
            let kind = ManualInputKind(rawValue: fieldTypeRaw) ?? .general
            let reason = (args["reason"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let initialValue = (args["initialValue"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let suggestions = kind == .driveFile ? GoogleDriveService.shared.lastSuggestedFiles.map { $0.name } : []
            triggerManualInput(
                kind: kind,
                subtitle: reason.isEmpty ? "Sesli algılamada karışıklık olmaması için lütfen aşağıya el ile yazın:" : reason,
                initialText: initialValue,
                suggestions: suggestions
            )
            return ("Ekranda kullanıcının el ile yazabileceği metin kutusu açıldı.", [])

        case "analyzeCamera":
            if let msg = await PhoneIntegrationService.shared.cameraReadyMessage() { return (msg, []) }
            let question = (args["question"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let capture = onCaptureForAnalysis, let imageData = await capture() else {
                return ("Kameradan görüntü alınamadı.", [])
            }
            do {
                let answer = try await analyzeImage(imageData, question: question.isEmpty ? "Bu görüntüde ne görüyorsun?" : question)
                return ("Kamera görüntüsü analizi: \(answer)", [])
            } catch {
                return ("Görüntü analiz hatası: \(error.localizedDescription)", [])
            }

        default:
            if let memoryResult = GismoMemoryService.shared.executeTool(name: name, args: args) {
                return (memoryResult, [])
            }
            if let result = await PhoneIntegrationService.shared.execute(name: name, args: args) {
                return (result, [])
            }
            return ("Bilinmeyen araç: \(name)", [])
        }
    }

    /// Kamera görüntüsünü Gemini (multimodal) ile analiz eder
    func analyzeImage(_ imageData: Data, question: String) async throws -> String {
        let body: [String: Any] = [
            "contents": [[
                "role": "user",
                "parts": [
                    ["inline_data": ["mime_type": "image/jpeg", "data": imageData.base64EncodedString()]],
                    ["text": "Sen bir robotun gözüsün; bu görüntü robotun ön kamerasından (kullanıcıya bakarak) alındı. Türkçe, kısa ve net cevap ver (en fazla 3 cümle). Soru: \(question)"]
                ]
            ]],
            "generationConfig": ["temperature": 0.4, "maxOutputTokens": 400]
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var lastError: Error = GeminiError.parseError
        for base in [endpoint, fallbackEndpoint] {
            guard let url = URL(string: "\(base)?key=\(apiKey)") else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 25
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = bodyData
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    lastError = GeminiError.httpError((resp as? HTTPURLResponse)?.statusCode ?? 0, Self.extractAPIErrorMessage(from: data))
                    continue
                }
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let parts = ((json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] {
                    let text = parts.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { return text }
                }
                lastError = GeminiError.parseError
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func triggerManualInput(
        kind: ManualInputKind,
        title: String? = nil,
        subtitle: String,
        initialText: String = "",
        suggestions: [String] = []
    ) {
        let prompt = ManualInputPrompt(
            kind: kind,
            title: title ?? kind.defaultTitle,
            subtitle: subtitle,
            placeholder: kind.defaultPlaceholder,
            initialText: initialText,
            suggestions: suggestions
        )
        DispatchQueue.main.async { [weak self] in
            self?.onRequestManualInput?(prompt)
        }
    }

    static func isValidEmailFormat(_ email: String) -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 5,
              let atIndex = trimmed.firstIndex(of: "@"),
              trimmed[..<atIndex].count >= 1 else {
            return false
        }
        let domainPart = String(trimmed[trimmed.index(after: atIndex)...])
        return domainPart.contains(".") && domainPart.count >= 3 && !domainPart.hasSuffix(".") && !domainPart.contains("@")
    }

    static func normalizeEmailAddress(_ raw: String) -> String {
        var working = " " + raw.lowercased() + " "
        let replacements: [(String, String)] = [
            (" et ", "@"),
            (" at ", "@"),
            (" nokta ", "."),
            (" dot ", "."),
            (" alt tire ", "_"),
            (" alttire ", "_"),
            (" tire ", "-"),
            (" çizgi ", "-"),
            ("ı", "i"),
            ("ş", "s"),
            ("ğ", "g"),
            ("ü", "u"),
            ("ö", "o"),
            ("ç", "c")
        ]
        for (target, rep) in replacements {
            working = working.replacingOccurrences(of: target, with: rep)
        }
        return working
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?'\""))
    }

    private static func extractAPIErrorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errorObj = json["error"] as? [String: Any],
           let msg = errorObj["message"] as? String {
            return msg
        }
        return String(data: data, encoding: .utf8) ?? "Bilinmeyen API hatası"
    }
}

// MARK: - Gemini Live API WebSocket Service (BidiGenerateContent Native Audio)

struct GeminiLiveTurnResult {
    let text: String
    let audioData: Data
    let mimeType: String
    let emotion: GismoEmotionName
    let duration: Double
    let motorSequence: [MotorStep]
}

final class GeminiLiveService {

    private var webSocketTask: URLSessionWebSocketTask?
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    private var connectedApiKey: String = ""
    private var connectedMemoryRevision: Int = -1
    private var isConnectedAndReady: Bool = false

    private let candidateModels = [
        "models/gemini-3.1-flash-live-preview",
        "models/gemini-2.5-flash-native-audio-preview-12-2025",
        "models/gemini-2.0-flash-live-001"
    ]

    private var liveSystemPrompt: String {
        PhoneIntegrationService.currentDateLine() + "\n" + baseLiveSystemPrompt + "\n" + PhoneIntegrationService.promptSummary + "\n\n" + GismoMemoryService.shared.promptContext()
    }

    private let baseLiveSystemPrompt = """
    Sen Gismo adında, JARVIS ve Cuma (Friday) tarzında zeki, fütüristik, empatik ve çok doğal Türkçe konuşan bir yapay zeka robot asistansın.
    Yanıtların her zaman kısa (en fazla 1-2 cümle), akıcı, berrak ve doğal Türkçe diksiyonla olsun.
    KESİN KURAL: Konuşurken ASLA ###EMO gibi etiketler, kodlar veya parantez içi açıklamalar söyleme! Sadece doğrudan kullanıcıya söylediğin doğal Türkçe cümleyi seslendir.
    Google Drive, Google Fotoğraflar (Google Photos), Gmail, Rehber ve SMS araçlarına tam erişimin var:
    - Drive'da dosya aramak veya son dosyaları listelemek için `searchDrive`,
    - Drive'daki bir dosyayı (Doküman, Tablo, PDF, Metin) adı veya ID'si ile açıp okumak ve özetlemek için `readDriveFile`,
    - Drive'da yeni bir metin/not/özet dosyası oluşturmak için `createDriveFile`,
    - Drive'dan dosya alıp e-posta ile göndermek için `emailDriveFile`,
    - Sadece kameradan fotoğraf/selfie çekip telefon galerisine kaydetmek için `takePhoto`,
    - Kameradan yeni fotoğraf çekip Google Drive'a yüklemek için `uploadPhotoToDrive(useLastPhoto: false)`, kullanıcının "son çektiğin fotoyu / az önceki fotoğrafı / galerideki son fotoğrafı Drive'a yükle" dediği durumlarda YENİ FOTOĞRAF ÇEKMEDEN galerideki son fotoğrafı yüklemek için `uploadPhotoToDrive(useLastPhoto: true)`,
    - Kameradan yeni fotoğraf çekip Google Fotoğraflar'a yüklemek için `uploadPhotoToGooglePhotos(useLastPhoto: false)`, son çekilen / galerideki son fotoğrafı yüklemek için `uploadPhotoToGooglePhotos(useLastPhoto: true)`,
    - Kameradan yeni fotoğraf çekip e-posta olarak göndermek için `emailPhoto(useLastPhoto: false)`, son çekilen / galerideki son fotoğrafı e-posta olarak göndermek için `emailPhoto(useLastPhoto: true)`,
    - Google Fotoğraflar'da arama/listeleme için `searchGooglePhotos`, buluttan fotoğraf indirip galeriye kaydetmek veya mail atmak için `downloadPhotoFromGoogle`,
    - Mailleri okumak/aramak/özetlemek için `readEmails`, mail göndermek için `sendEmail`, son gelen maile yanıt vermek için `replyToLastEmail`, son gelen mailde işlem yapmamak/kapatmak için `dismissLastEmail`, gelen maillerin otomatik sesli bildirimini açıp kapatmak için `setIncomingMailNotifications`,
    - Fiziksel hareket için `moveRobot` (1 cm = 15ms; örn: 3 cm ileri = "F,45;S", 360 derece dönüş = "L,1000;S") araçlarını kullan.
    Kullanıcı SMS veya E-posta göndermek/yanıtlamak istediğinde önce alıcıyı ve mesajı kısaca tekrar edip onay iste; sadece onay verdiğinde ilgili aracı çağır.
    DRIVE BENZER DOSYA VE MANUEL METİN KUTUSU KURALLARI:
    - Drive'da dosya ararken ASLA kullanıcıdan birebir tam dosya adını ezbere söylemesini bekleme! `searchDrive`, `readDriveFile` veya `emailDriveFile` aracından `[BENZER DRIVE DOSYALARI BULUNDU]` dönerse, bulduğun benzer dosya isimlerini kullanıcıya söyleyip "Drive'da şu benzer dosyaları buldum: şu dosya mı yoksa bu dosya mı?" diye sor. Kullanıcı hangisini seçerse onun tam adını veya ID'sini kullan.
    - E-posta adresi, Drive dosya adı, kişi adı veya telefon numarası gibi spesifik girdilerde 1. sesli deneme başarısız olursa (örneğin adres/dosya/kişi bulunamazsa, e-posta adresi bozuk çevrilirse veya kullanıcı "hayır yanlış anladın / o adres değil / o dosya değil" derse), kullanıcıyı tekrar sesle söylemeye zorlama; hemen `requestManualTextInput` aracını çağırarak ekranda yazma kutusunu aç ve "Ekranda açtığım kutuya el ile yazabilirsin." de.
    Kullanıcı "artık gelen mailleri okuma", "gelen mailleri bildirme", "mail bildirimlerini kapat" derse `setIncomingMailNotifications(enabled: false)` çağır. "Gelen mailleri bana bildir", "mail gelirse haber ver" derse `setIncomingMailNotifications(enabled: true)` çağır.
    Sana `[SİSTEM BİLDİRİMİ - YENİ E-POSTA GELDİ]` iletildiğinde:
    - Doğrudan doğal ve samimi bir şekilde "Bir mail geldi!" diyerek kimden geldiğini ve içeriğini ÇOK KISA (1-2 cümle) özetle ve "Yanıtlamamı ister misin?" diye sor.
    - Kullanıcı sonrasında "tamam bir şey yapma", "kalsın", "gerek yok" derse `dismissLastEmail` aracını çağırıp "Tamamdır, bir şey yapmıyorum." de.
    - Kullanıcı "yanıtla" derse ne yazmak istediğini sor veya söylediyse onay alıp `replyToLastEmail` aracını çağır.
    """

    private var liveFunctionDeclarations: [[String: Any]] {
        GeminiService.sharedFunctionDeclarations
    }

    func disconnect() {
        isConnectedAndReady = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    /// Oturumu önceden ısıtır (kullanıcı konuşmadan önce WebSocket bağlantısını hazır tutar)
    func prewarm(apiKey: String) {
        Task {
            try? await ensureConnected(apiKey: apiKey)
        }
    }

    func ensureConnected(apiKey: String) async throws {
        if isConnectedAndReady,
           connectedApiKey == apiKey,
           let task = webSocketTask,
           task.state == .running {
            return
        }

        disconnect()

        var lastError: Error = GeminiError.httpError(0, "Live API bağlantısı kurulamadı.")
        for model in candidateModels {
            do {
                try await connectWithModel(model, apiKey: apiKey)
                connectedApiKey = apiKey
                connectedMemoryRevision = GismoMemoryService.shared.revision
                isConnectedAndReady = true
                print("[GeminiLive] Bağlantı hazır (\(model))")
                return
            } catch {
                print("[GeminiLive] \(model) bağlantı hatası: \(error.localizedDescription)")
                lastError = error
                disconnect()
            }
        }
        throw lastError
    }

    private func connectWithModel(_ modelName: String, apiKey: String) async throws {
        let urlString = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            throw GeminiError.invalidURL
        }

        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 16 * 1024 * 1024
        self.webSocketTask = task
        task.resume()

        let setupPayload: [String: Any] = [
            "setup": [
                "model": modelName,
                "generationConfig": [
                    "responseModalities": ["AUDIO"],
                    "speechConfig": [
                        "voiceConfig": [
                            "prebuiltVoiceConfig": [
                                "voiceName": "Aoede" // Doğal, berrak ve gerçekçi asistan sesi
                            ]
                        ]
                    ]
                ],
                "outputAudioTranscription": [:] as [String: Any],
                "inputAudioTranscription": [:] as [String: Any],
                "systemInstruction": [
                    "parts": [
                        ["text": liveSystemPrompt]
                    ]
                ],
                "tools": [
                    [
                        "functionDeclarations": liveFunctionDeclarations
                    ]
                ]
            ]
        ]

        try await sendJSON(setupPayload, over: task)

        // setupComplete yanıtını bekle
        let msg = try await receiveJSON(from: task, timeoutSeconds: 5.5)
        if msg["setupComplete"] != nil {
            return
        }
        if let err = msg["error"] as? [String: Any], let message = err["message"] as? String {
            let code = err["code"] as? Int ?? 403
            throw GeminiError.httpError(code, message)
        }
        throw GeminiError.parseError
    }

    /// Kullanıcının söylediklerini Live API'ye iletir; tek akışta (stream) hem doğal 24kHz sesi hem de metni alır
    func sendTurn(_ userText: String, using geminiService: GeminiService) async throws -> GeminiLiveTurnResult {
        let key = geminiService.apiKey
        try await ensureConnected(apiKey: key)

        guard let task = webSocketTask else {
            throw GeminiError.httpError(0, "Live WebSocket aktif değil")
        }

        // Realtime text input gönder
        let realtimePayload: [String: Any] = [
            "realtimeInput": [
                "text": userText
            ]
        ]

        do {
            try await sendJSON(realtimePayload, over: task)
        } catch {
            // Soket koptuysa 1 kez yeniden bağlanıp tekrar gönder
            disconnect()
            try await ensureConnected(apiKey: key)
            guard let retryTask = webSocketTask else { throw error }
            try await sendJSON(realtimePayload, over: retryTask)
        }

        guard let activeTask = webSocketTask else {
            throw GeminiError.httpError(0, "Live WebSocket bulunamadı")
        }

        var accumulatedAudio = Data()
        var detectedMimeType = "audio/pcm;rate=24000"
        var accumulatedTranscript = ""
        var accumulatedMotorSteps: [MotorStep] = []

        while true {
            let message = try await receiveJSON(from: activeTask, timeoutSeconds: 12.0)

            if let errorObj = message["error"] as? [String: Any] {
                let code = errorObj["code"] as? Int ?? 500
                let detail = errorObj["message"] as? String ?? "Live API hatası"
                disconnect()
                throw GeminiError.httpError(code, detail)
            }

            // 1. Tool Call kontrolü
            if let toolCall = message["toolCall"] as? [String: Any],
               let functionCalls = toolCall["functionCalls"] as? [[String: Any]] {
                var functionResponses: [[String: Any]] = []

                for fc in functionCalls {
                    let callName = fc["name"] as? String ?? ""
                    let callId = fc["id"] as? String ?? ""
                    let args = fc["args"] as? [String: Any] ?? [:]

                    let (resultText, motorSteps) = await geminiService.executeLiveTool(name: callName, args: args)
                    if !motorSteps.isEmpty {
                        accumulatedMotorSteps.append(contentsOf: motorSteps)
                    }

                    var responseItem: [String: Any] = [
                        "name": callName,
                        "response": [
                            "result": resultText
                        ]
                    ]
                    if !callId.isEmpty {
                        responseItem["id"] = callId
                    }
                    functionResponses.append(responseItem)
                }

                let toolResponsePayload: [String: Any] = [
                    "toolResponse": [
                        "functionResponses": functionResponses
                    ]
                ]
                try await sendJSON(toolResponsePayload, over: activeTask)
                continue
            }

            // 2. Server Content (Ses parçaları + Anlık Transkripsiyon)
            if let serverContent = message["serverContent"] as? [String: Any] {
                if let modelTurn = serverContent["modelTurn"] as? [String: Any],
                   let parts = modelTurn["parts"] as? [[String: Any]] {
                    for part in parts {
                        if let inlineData = (part["inlineData"] as? [String: Any]) ?? (part["inline_data"] as? [String: Any]),
                           let b64 = inlineData["data"] as? String,
                           let chunk = Data(base64Encoded: b64) {
                            accumulatedAudio.append(chunk)
                            if let mime = (inlineData["mimeType"] as? String) ?? (inlineData["mime_type"] as? String) {
                                detectedMimeType = mime
                            }
                        }
                        if let textPart = part["text"] as? String, !textPart.isEmpty {
                            if accumulatedTranscript.isEmpty {
                                accumulatedTranscript += textPart
                            }
                        }
                    }
                }

                if let outputTranscription = serverContent["outputTranscription"] as? [String: Any],
                   let transText = outputTranscription["text"] as? String {
                    accumulatedTranscript += transText
                }

                let generationComplete = (serverContent["generationComplete"] as? Bool) == true
                let turnComplete = (serverContent["turnComplete"] as? Bool) == true

                // generationComplete geldiği anda tüm ses ve metin üretimi tamamlanmıştır
                if (generationComplete || turnComplete) && (!accumulatedAudio.isEmpty || !accumulatedTranscript.isEmpty) {
                    break
                }
            }
        }

        let cleanedText = Self.cleanTranscript(accumulatedTranscript)
        let inferredEmotion = Self.inferEmotion(from: cleanedText, userText: userText)
        let wordCount = Double(max(1, cleanedText.split(separator: " ").count))
        let estimatedDuration = max(3.5, min(8.0, wordCount * 0.45))

        return GeminiLiveTurnResult(
            text: cleanedText.isEmpty ? "Seni dinliyorum!" : cleanedText,
            audioData: accumulatedAudio,
            mimeType: detectedMimeType,
            emotion: inferredEmotion,
            duration: estimatedDuration,
            motorSequence: accumulatedMotorSteps
        )
    }

    // MARK: - Helpers

    private func sendJSON(_ object: [String: Any], over task: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let str = String(data: data, encoding: .utf8) else {
            throw GeminiError.parseError
        }
        try await task.send(.string(str))
    }

    private func receiveJSON(from task: URLSessionWebSocketTask, timeoutSeconds: Double) async throws -> [String: Any] {
        try await withThrowingTaskGroup(of: [String: Any].self) { group in
            group.addTask {
                let message = try await task.receive()
                let data: Data
                switch message {
                case .string(let text):
                    data = Data(text.utf8)
                case .data(let d):
                    data = d
                @unknown default:
                    throw GeminiError.parseError
                }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw GeminiError.parseError
                }
                return json
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                throw GeminiError.httpError(408, "Live API yanıt zaman aşımı")
            }
            guard let first = try await group.next() else {
                throw GeminiError.parseError
            }
            group.cancelAll()
            return first
        }
    }

    private static func cleanTranscript(_ raw: String) -> String {
        let pattern = #"###EMO:[^#]*###"#
        var cleaned = raw
        if let regex = try? NSRegularExpression(pattern: pattern) {
            cleaned = regex.stringByReplacingMatches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: "")
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func inferEmotion(from responseText: String, userText: String) -> GismoEmotionName {
        let lower = (responseText + " " + userText).lowercased()
        if lower.contains("harika") || lower.contains("süper") || lower.contains("yaşasın") || lower.contains("çok sevindim") || lower.contains("gülümse") {
            return .veryHappy
        } else if lower.contains("üzgün") || lower.contains("maalesef") || lower.contains("hata") || lower.contains("yapamadım") || lower.contains("özür") {
            return .sad
        } else if lower.contains("kız") || lower.contains("sinir") || lower.contains("dikkat et") {
            return .angry
        } else if lower.contains("vay") || lower.contains("inanılmaz") || lower.contains("gerçekten mi") || lower.contains("şaşırdım") {
            return .surprised
        } else if lower.contains("iyi geceler") || lower.contains("uyku") || lower.contains("şekerleme") {
            return .sleeping
        } else if lower.contains("düşün") || lower.contains("bakalım") || lower.contains("kontrol ed") {
            return .thoughtful
        } else {
            return .happy
        }
    }
}

// MARK: - Errors

enum GeminiError: LocalizedError {
    case invalidURL
    case httpError(Int, String)
    case parseError

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Gemini URL geçersiz."
        case .httpError(let code, let detail):
            if detail.lowercased().contains("leaked") || detail.lowercased().contains("api_key_invalid") || code == 403 {
                return "Gemini API anahtarı geçersiz/iptal edilmiş (HTTP \(code)). Entegrasyonlar menüsünden yeni bir Gemini API anahtarı girin."
            }
            if code == 429 {
                return "Gemini API kota sınırı aşıldı (HTTP 429)."
            }
            return "Gemini API Hatası (HTTP \(code)): \(detail)"
        case .parseError:
            return "Gemini yanıtı parse edilemedi."
        }
    }
}
// MARK: - Gmail Service

struct GmailIncomingEmail: Equatable, Sendable {
    let id: String
    let threadId: String
    let rfcMessageId: String
    let senderName: String
    let senderEmail: String
    let fromHeader: String
    let subject: String
    let snippet: String
    let bodyText: String
    let internalDateMs: Int64
}

final class GmailService {
    static let shared = GmailService()
    private let incomingMailAnnounceKey = "gismo_incoming_mail_announce_enabled"

    /// Kullanıcının sesli komutla ("gelen mailleri okuma" / "gelen mailleri bana bildir") açıp kapatabildiği canlı mail bildirim ayarı (Varsayılan: true)
    var isIncomingMailAnnouncementEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: incomingMailAnnounceKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: incomingMailAnnounceKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: incomingMailAnnounceKey)
        }
    }

    private init() {}

    /// Yüz modu açıldığında mevcut maillerin tekrar anons edilmemesi için gelen kutusundaki son mail ID'lerini alır
    func fetchRecentInboxIds(maxResults: Int = 5) async throws -> Set<String> {
        guard let user = await GoogleAuthService.shared.currentUser else {
            return []
        }
        let refreshedUser = try await refreshUserIfNeeded(user)
        let token = refreshedUser.accessToken.tokenString

        var urlComps = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        urlComps.queryItems = [
            URLQueryItem(name: "maxResults", value: "\(maxResults)"),
            URLQueryItem(name: "q", value: "in:inbox -from:me")
        ]

        var req = URLRequest(url: urlComps.url!)
        req.timeoutInterval = 10.0
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return []
        }

        struct ListRes: Decodable {
            let messages: [MsgId]?
            struct MsgId: Decodable { let id: String }
        }
        let decoded = try? JSONDecoder().decode(ListRes.self, from: data)
        return Set((decoded?.messages ?? []).map(\.id))
    }

    /// Yüz modu açıkken yeni düşen okunmamış e-posta olup olmadığını kontrol eder
    func checkForNewIncomingEmail(seenIds: Set<String>, sinceMs: Int64) async throws -> GmailIncomingEmail? {
        guard let user = await GoogleAuthService.shared.currentUser else {
            return nil
        }
        let refreshedUser = try await refreshUserIfNeeded(user)
        let token = refreshedUser.accessToken.tokenString

        var urlComps = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        urlComps.queryItems = [
            URLQueryItem(name: "maxResults", value: "3"),
            URLQueryItem(name: "q", value: "in:inbox is:unread -from:me")
        ]

        var req = URLRequest(url: urlComps.url!)
        req.timeoutInterval = 10.0
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (listData, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }

        struct ListRes: Decodable {
            let messages: [MsgId]?
            struct MsgId: Decodable { let id: String }
        }
        guard let listRes = try? JSONDecoder().decode(ListRes.self, from: listData),
              let msgs = listRes.messages, !msgs.isEmpty else {
            return nil
        }

        for msg in msgs where !seenIds.contains(msg.id) {
            let msgUrl = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(msg.id)?format=full")!
            var mReq = URLRequest(url: msgUrl)
            mReq.timeoutInterval = 10.0
            mReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            guard let (mData, mResp) = try? await URLSession.shared.data(for: mReq),
                  let mHttp = mResp as? HTTPURLResponse, mHttp.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: mData) as? [String: Any] else {
                continue
            }

            let internalDateStr = json["internalDate"] as? String ?? "0"
            let internalDateMs = Int64(internalDateStr) ?? 0

            // Yalnızca yüz modu açıldıktan (veya çok kısa süre öncesinden) sonra gelen yeni mailleri anons et
            if sinceMs > 0 && internalDateMs > 0 && internalDateMs < (sinceMs - 20_000) {
                continue
            }

            let threadId = json["threadId"] as? String ?? ""
            let snippet = json["snippet"] as? String ?? ""
            var subject = "Konusuz"
            var fromHeader = "Bilinmeyen Gönderen"
            var rfcMessageId = ""
            var fullBody = ""

            if let payload = json["payload"] as? [String: Any] {
                if let headers = payload["headers"] as? [[String: Any]] {
                    for h in headers {
                        guard let name = h["name"] as? String, let value = h["value"] as? String else { continue }
                        if name.caseInsensitiveCompare("Subject") == .orderedSame {
                            subject = value
                        } else if name.caseInsensitiveCompare("From") == .orderedSame {
                            fromHeader = value
                        } else if name.caseInsensitiveCompare("Message-ID") == .orderedSame {
                            rfcMessageId = value
                        }
                    }
                }
                fullBody = Self.extractBodyText(from: payload)
            }

            let (senderName, senderEmail) = Self.parseFromHeader(fromHeader)
            let cleanBody = fullBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? snippet
                : String(fullBody.prefix(1200))

            return GmailIncomingEmail(
                id: msg.id,
                threadId: threadId,
                rfcMessageId: rfcMessageId,
                senderName: senderName,
                senderEmail: senderEmail,
                fromHeader: fromHeader,
                subject: subject,
                snippet: snippet,
                bodyText: cleanBody,
                internalDateMs: internalDateMs
            )
        }

        return nil
    }

    /// Gelen e-postaya aynı Gmail dizisi (thread) içinde yanıt gönderir ve okundu olarak işaretler
    func replyToEmail(_ incoming: GmailIncomingEmail, body: String) async throws -> Bool {
        guard let user = await GoogleAuthService.shared.currentUser else {
            throw NSError(domain: "Gmail", code: 401, userInfo: [NSLocalizedDescriptionKey: "Lütfen önce Google hesabınızı bağlayın."])
        }
        let refreshedUser = try await refreshUserIfNeeded(user)
        let accessToken = refreshedUser.accessToken.tokenString

        let replySubject = incoming.subject.lowercased().hasPrefix("re:")
            ? incoming.subject
            : "Re: \(incoming.subject)"
        let subjectData = replySubject.data(using: .utf8)?.base64EncodedString() ?? ""
        let encodedSubject = "=?utf-8?B?\(subjectData)?="

        var headers = [
            "To: \(incoming.senderEmail)",
            "Subject: \(encodedSubject)",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=\"UTF-8\""
        ]
        if !incoming.rfcMessageId.isEmpty {
            headers.append("In-Reply-To: \(incoming.rfcMessageId)")
            headers.append("References: \(incoming.rfcMessageId)")
        }

        let rawMessage = headers.joined(separator: "\r\n") + "\r\n\r\n" + body
        guard let rawData = rawMessage.data(using: .utf8) else { return false }

        let base64Encoded = rawData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        var jsonPayload: [String: Any] = ["raw": base64Encoded]
        if !incoming.threadId.isEmpty {
            jsonPayload["threadId"] = incoming.threadId
        }

        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonPayload)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return false
        }

        try? await markEmailAsRead(messageId: incoming.id)
        return true
    }

    /// Belirtilen e-postadan UNREAD etiketini kaldırır
    func markEmailAsRead(messageId: String) async throws {
        guard !messageId.isEmpty, let user = await GoogleAuthService.shared.currentUser else { return }
        let refreshedUser = try await refreshUserIfNeeded(user)
        let accessToken = refreshedUser.accessToken.tokenString

        guard let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(messageId)/modify") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["removeLabelIds": ["UNREAD"]])
        _ = try? await URLSession.shared.data(for: request)
    }

    private static func parseFromHeader(_ raw: String) -> (name: String, email: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ltIndex = trimmed.firstIndex(of: "<"),
           let gtIndex = trimmed.firstIndex(of: ">"),
           ltIndex < gtIndex {
            let namePart = String(trimmed[..<ltIndex])
                .replacingOccurrences(of: "\"", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let emailPart = String(trimmed[trimmed.index(after: ltIndex)..<gtIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (namePart.isEmpty ? emailPart : namePart, emailPart)
        }
        return (trimmed, trimmed)
    }
    
    /// Yapay Zekanın çağıracağı ana mail atma fonksiyonu
    func sendEmail(to recipient: String, subject: String, body: String, attachment: Data? = nil, attachmentName: String = "photo.jpg", attachmentMimeType: String = "image/jpeg") async throws -> Bool {
        // Main thread üzerinde Auth kontrolü yapıyoruz
        guard let user = await GoogleAuthService.shared.currentUser else {
            throw NSError(domain: "Gmail", code: 401, userInfo: [NSLocalizedDescriptionKey: "Lütfen önce Google hesabınızı bağlayın."])
        }
        
        // Token'ın geçerli olduğundan emin ol (Süresi dolmuşsa arkaplanda yeniler)
        let refreshedUser = try await refreshUserIfNeeded(user)
        let accessToken = refreshedUser.accessToken.tokenString
        
        // Türkçe karakterlerin Subject (Konu) kısmında hata vermemesi için MIME Encoding (Base64) yapıyoruz.
        let subjectData = subject.data(using: .utf8)?.base64EncodedString() ?? ""
        let encodedSubject = "=?utf-8?B?\(subjectData)?="
        
        var rawMessage = ""
        
        if let attachment = attachment {
            let boundary = UUID().uuidString
            rawMessage += "To: \(recipient)\r\n"
            rawMessage += "Subject: \(encodedSubject)\r\n"
            rawMessage += "MIME-Version: 1.0\r\n"
            rawMessage += "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n\r\n"
            
            // Text part
            rawMessage += "--\(boundary)\r\n"
            rawMessage += "Content-Type: text/plain; charset=\"UTF-8\"\r\n\r\n"
            rawMessage += "\(body)\r\n\r\n"
            
            // Attachment part
            rawMessage += "--\(boundary)\r\n"
            rawMessage += "Content-Type: \(attachmentMimeType); name=\"\(attachmentName)\"\r\n"
            rawMessage += "Content-Disposition: attachment; filename=\"\(attachmentName)\"\r\n"
            rawMessage += "Content-Transfer-Encoding: base64\r\n\r\n"
            
            let base64Attachment = attachment.base64EncodedString(options: .lineLength64Characters)
            rawMessage += "\(base64Attachment)\r\n"
            rawMessage += "--\(boundary)--"
        } else {
            rawMessage = """
            To: \(recipient)
            Subject: \(encodedSubject)
            Content-Type: text/plain; charset="UTF-8"
            
            \(body)
            """
        }
        
        guard let rawData = rawMessage.data(using: .utf8) else {
            return false
        }
        
        // Gmail API'si Base64Url formatı (RFC 4648) bekler (+ yerine -, / yerine _, sondaki = işaretleri yok)
        let base64Encoded = rawData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
            
        let jsonPayload: [String: Any] = ["raw": base64Encoded]
        let jsonData = try JSONSerialization.data(withJSONObject: jsonPayload)
        
        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        
        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
            print("[Gmail] Mail başarıyla gönderildi: \(recipient)")
            return true
        } else {
            // Google API'den dönen gerçek hatayı göster
            var errDetail = "Bilinmeyen API Hatası"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorObj = json["error"] as? [String: Any],
               let message = errorObj["message"] as? String {
                errDetail = message
            }
            print("[Gmail] Gönderim Hatası: \(errDetail)")
            throw NSError(domain: "Gmail", code: 500, userInfo: [NSLocalizedDescriptionKey: "Hata detayı: \(errDetail)"])
        }
    }
    
    // Asenkron olarak user refresh işlemini sarmalayalım
    private func refreshUserIfNeeded(_ user: GIDGoogleUser) async throws -> GIDGoogleUser {
        return try await withCheckedThrowingContinuation { continuation in
            user.refreshTokensIfNeeded { refreshedUser, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let refreshedUser = refreshedUser {
                    continuation.resume(returning: refreshedUser)
                } else {
                    continuation.resume(throwing: NSError(domain: "Gmail", code: 500, userInfo: [NSLocalizedDescriptionKey: "Token yenilenemedi."]))
                }
            }
        }
    }

    /// Yapay Zekanın çağıracağı tam içerikli mail okuma ve arama fonksiyonu
    func getLatestEmails(count: Int = 3, query: String? = nil) async throws -> String {
        guard let user = await GoogleAuthService.shared.currentUser else {
            throw NSError(domain: "Gmail", code: 401, userInfo: [NSLocalizedDescriptionKey: "Lütfen önce Google hesabınızı bağlayın."])
        }
        
        let refreshedUser = try await refreshUserIfNeeded(user)
        let token = refreshedUser.accessToken.tokenString
        
        let trimmedQuery = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let gmailQuery = trimmedQuery.isEmpty ? "in:inbox" : trimmedQuery
        
        var urlComps = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        urlComps.queryItems = [
            URLQueryItem(name: "maxResults", value: "\(max(1, min(10, count)))"),
            URLQueryItem(name: "q", value: gmailQuery)
        ]
        
        var req = URLRequest(url: urlComps.url!)
        req.timeoutInterval = 15.0
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (listData, response) = try await URLSession.shared.data(for: req)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return "Mail listesi alınamadı."
        }
        
        struct ListRes: Decodable {
            let messages: [MsgId]?
            struct MsgId: Decodable { let id: String }
        }
        
        guard let listRes = try? JSONDecoder().decode(ListRes.self, from: listData),
              let msgs = listRes.messages, !msgs.isEmpty else {
            return trimmedQuery.isEmpty ? "Gelen kutusunda hiç mail bulunamadı." : "'\(trimmedQuery)' aramasına uygun mail bulunamadı."
        }
        
        var resultText = "Bulunan Mailler (\(msgs.count) adet):\n"
        
        for (index, msg) in msgs.enumerated() {
            let msgUrl = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(msg.id)?format=full")!
            var mReq = URLRequest(url: msgUrl)
            mReq.timeoutInterval = 15.0
            mReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            
            if let (mData, _) = try? await URLSession.shared.data(for: mReq),
               let json = try? JSONSerialization.jsonObject(with: mData) as? [String: Any] {
                
                let snippet = json["snippet"] as? String ?? "İçerik yok"
                var subject = "Konusuz"
                var from = "Bilinmeyen"
                var fullBody = ""
                
                if let payload = json["payload"] as? [String: Any] {
                    if let headers = payload["headers"] as? [[String: Any]] {
                        for h in headers {
                            if let name = h["name"] as? String, let value = h["value"] as? String {
                                if name.caseInsensitiveCompare("Subject") == .orderedSame { subject = value }
                                if name.caseInsensitiveCompare("From") == .orderedSame { from = value }
                            }
                        }
                    }
                    fullBody = Self.extractBodyText(from: payload)
                }
                
                let bodyToUse = fullBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? snippet
                    : String(fullBody.prefix(1200))
                resultText += "\(index + 1). Kimden: \(from) | Konu: \(subject)\nİçerik: \(bodyToUse)\n---\n"
            }
        }
        return resultText
    }

    private static func extractBodyText(from payload: [String: Any]) -> String {
        let mimeType = (payload["mimeType"] as? String ?? "").lowercased()
        if let body = payload["body"] as? [String: Any],
           let dataStr = body["data"] as? String,
           let decoded = decodeBase64URLString(dataStr), !decoded.isEmpty {
            if mimeType.contains("text/plain") {
                return decoded
            } else if mimeType.contains("text/html") {
                return stripHTML(decoded)
            }
        }

        if let parts = payload["parts"] as? [[String: Any]] {
            // Önce text/plain parçayı ara
            for part in parts {
                let pMime = (part["mimeType"] as? String ?? "").lowercased()
                if pMime.contains("text/plain") {
                    let extracted = extractBodyText(from: part)
                    if !extracted.isEmpty { return extracted }
                }
            }
            // Yoksa diğer alt parçaları dolaş
            for part in parts {
                let extracted = extractBodyText(from: part)
                if !extracted.isEmpty { return extracted }
            }
        }
        return ""
    }

    private static func decodeBase64URLString(_ base64url: String) -> String? {
        var b64 = base64url
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = b64.count % 4
        if remainder > 0 {
            b64.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func stripHTML(_ html: String) -> String {
        let withoutTags = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
// MARK: - Google Auth Service

@MainActor
final class GoogleAuthService: ObservableObject {
    static let shared = GoogleAuthService()
    
    @Published var currentUser: GIDGoogleUser?
    @Published var isConnected: Bool = false
    @Published var lastAuthError: String? = nil
    
    let clientId = "312777580050-0od6id68t7gh274aveien553acopmrsr.apps.googleusercontent.com"

    /// Gmail + Google Drive + Google Photos tam erişim yetkileri
    let requiredScopes = [
        "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/drive",
        "https://www.googleapis.com/auth/drive.file",
        "https://www.googleapis.com/auth/drive.readonly",
        "https://www.googleapis.com/auth/photoslibrary.readonly",
        "https://www.googleapis.com/auth/photoslibrary.appendonly"
    ]
    
    private init() {
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientId)
        checkStatus()
    }
    
    func checkStatus() {
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientId)
        GIDSignIn.sharedInstance.restorePreviousSignIn { user, error in
            if let user = user {
                self.currentUser = user
                self.isConnected = true
                self.lastAuthError = nil
            } else {
                self.isConnected = false
            }
        }
    }
    
    func signIn(presenting viewController: UIViewController) {
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientId)
        let topVC = Self.topViewController(from: viewController)
        
        GIDSignIn.sharedInstance.signIn(withPresenting: topVC, hint: nil, additionalScopes: requiredScopes) { result, error in
            if let error = error {
                print("[GoogleAuth] Giriş Hatası: \(error.localizedDescription)")
                self.lastAuthError = error.localizedDescription
                return
            }
            if let user = result?.user {
                self.currentUser = user
                self.isConnected = true
                self.lastAuthError = nil
                print("[GoogleAuth] Başarıyla giriş yapıldı: \(user.profile?.email ?? "")")
            }
        }
    }

    private static func topViewController(from root: UIViewController) -> UIViewController {
        var current = root
        while let presented = current.presentedViewController {
            current = presented
        }
        return current
    }
    
    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        self.currentUser = nil
        self.isConnected = false
        self.lastAuthError = nil
        print("[GoogleAuth] Çıkış yapıldı.")
    }
}

// MARK: - Netgsm SMS Service (Cerilas AS)
final class SMSService {
    static let shared = SMSService()
    
    static let defaultCerilasUsername = "8503044989"
    static let defaultCerilasPassword = "Dnz.24232423"
    static let defaultCerilasHeader   = "CERILAS AS"
    
    private var username: String {
        let saved = (UserDefaults.standard.string(forKey: "netgsmUsername") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return saved.isEmpty ? Self.defaultCerilasUsername : saved
    }
    
    private var password: String {
        let saved = (UserDefaults.standard.string(forKey: "netgsmPassword") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return saved.isEmpty ? Self.defaultCerilasPassword : saved
    }
    
    private var header: String {
        let savedHeader = (UserDefaults.standard.string(forKey: "netgsmHeader") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return savedHeader.isEmpty ? Self.defaultCerilasHeader : savedHeader
    }
    
    private let apiUrl = "https://api.netgsm.com.tr/sms/rest/v2/send"
    private let otpApiUrl = "https://api.netgsm.com.tr/sms/rest/v2/otp"
    
    private init() {}
    
    func sendSMS(to phoneNumber: String, message: String) async throws -> String {
        guard let url = URL(string: apiUrl) else {
            throw NSError(domain: "SMS", code: 400, userInfo: [NSLocalizedDescriptionKey: "Geçersiz URL"])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10.0 // 10 saniye zaman aşımı (Takılmaları önlemek için)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Basic Auth
        let safeUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let safePass = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let loginString = "\(safeUser):\(safePass)"
        guard let loginData = loginString.data(using: .utf8) else {
            throw NSError(domain: "SMS", code: 400, userInfo: [NSLocalizedDescriptionKey: "Geçersiz kimlik bilgileri"])
        }
        let base64LoginString = loginData.base64EncodedString()
        request.setValue("Basic \(base64LoginString)", forHTTPHeaderField: "Authorization")
        
        let cleanNumber = phoneNumber.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        let safeHeader = header.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let requestBody: [String: Any] = [
            "msgheader": safeHeader,
            "messages": [
                [
                    "msg": message,
                    "no": cleanNumber
                ]
            ],
            "encoding": "TR",
            "iysfilter": "0",
            "appname": "GismoApp"
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: requestBody)
        request.httpBody = jsonData
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "SMS", code: 500, userInfo: [NSLocalizedDescriptionKey: "Sunucu yanıt vermedi."])
        }
        
        if let responseString = String(data: data, encoding: .utf8) {
            print("[SMS] Yanıt: \(responseString)")
        }
        
        guard let jsonResponse = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "SMS", code: 500, userInfo: [NSLocalizedDescriptionKey: "Yanıt anlaşılamadı."])
        }
        
        if let code = jsonResponse["code"] as? String, code == "00" {
            let jobId = jsonResponse["jobid"] as? String ?? "Bilinmiyor"
            return "Mesaj başarıyla gönderildi (Job: \(jobId))."
        } else {
            let desc = jsonResponse["description"] as? String ?? "Bilinmeyen hata"
            throw NSError(domain: "SMS", code: 500, userInfo: [NSLocalizedDescriptionKey: "SMS Gönderim Hatası: \(desc)"])
        }
    }
    
    // MARK: - Contact Search
    @MainActor
    func searchContact(by name: String) async throws -> String? {
        let store = CNContactStore()
        
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined {
            let granted = try await store.requestAccess(for: .contacts)
            guard granted else { throw NSError(domain: "Contacts", code: 401, userInfo: [NSLocalizedDescriptionKey: "Rehber izni reddedildi"]) }
        } else if status != .authorized {
            throw NSError(domain: "Contacts", code: 401, userInfo: [NSLocalizedDescriptionKey: "Rehber izni verilmemiş"])
        }
        
        let keys = [CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        
        var foundNumber: String? = nil
        let lowerName = name.folding(options: .diacriticInsensitive, locale: .current).lowercased()
        let searchTokens = lowerName.split(separator: " ")
        
        try store.enumerateContacts(with: request) { contact, stop in
            let fullName = "\(contact.givenName) \(contact.familyName)"
                .folding(options: .diacriticInsensitive, locale: .current)
                .lowercased()
            
            let allTokensMatch = searchTokens.allSatisfy { fullName.contains($0) }
            
            if allTokensMatch && !searchTokens.isEmpty {
                if let firstPhone = contact.phoneNumbers.first?.value.stringValue {
                    let clean = firstPhone.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                    foundNumber = clean
                    stop.pointee = true
                }
            }
        }
        
        return foundNumber
    }
}

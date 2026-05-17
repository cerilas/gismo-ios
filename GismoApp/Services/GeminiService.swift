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

// MARK: - Gemini Service

final class GeminiService {

    // TODO: Production'da bu anahtarı backend proxy üzerinden kullan
    private let apiKey = "AIzaSyCdkwAmuK8i35a2iOpmphA-_kr6bMgUTvk"
    private let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"
    
    // Fotoğraf çekme closure'u (ViewModel'dan atanacak)
    var onTakePhoto: (() async -> Data?)?

    // Konuşma geçmişi (multi-turn)
    private var history: [[String: Any]] = []

    private let systemPrompt = """
    Sen Gismo, sevimli ve empatik bir Türkçe konuşan robot yardımcısın. Kısa yanıtlar ver (max 2 cümle).
    Her yanıtın sonuna MUTLAKA şu etiketi ekle (başka hiçbir şey ekleme):
    ###EMO:duygu|süre|MOV:komutlar###

    Duygular: neutral, happy, veryHappy, sad, angry, thoughtful, surprised, listening, sleeping
    Süre: saniye (0=kalıcı)
    MOV: F=İleri,B=Geri,L=Sol,R=Sağ,S=Dur — max 1.5sn toplam, S ile bitir

    KABİLİYETLERİN: konuşma, robot hareketi, fotoğraf çekme, uyku modu, E-POSTA OKUMA/GÖNDERME, GOOGLE DRIVE KULLANIMI, SMS GÖNDERME ve REHBER SORGULAMA.
    ÖNEMLİ GÜVENLİK KURALI: Kullanıcı SMS veya E-posta göndermek istediğinde ASLA ilgili aracı anında çalıştırma! Önce alıcıyı ve mesajı kullanıcıya tekrar et ve "Mesajı gönderiyorum, onaylıyor musun?" diye sor. SADECE kullanıcı "evet, onayla, gönder" gibi onaylayıcı bir cevap verirse `sendSMS` veya `sendEmail` aracını çalıştır.
    Kullanıcı sana belirli bir santimetre (cm) gitmeni söylerse (Örn: "1 cm ileri gel", "5 cm sola dön"), robotun tekerlek ataletini (kaymasını) hesaba katarak her 1 cm için tam olarak 15ms hesapla (Örn: 1 cm = 15, 2 cm = 30, 5 cm = 75). Robotun sarsılmaması için hareket sürelerini daima çok düşük tut.
    Eğer kullanıcı "etrafında tam tur dön", "360 derece dön" gibi bir şey isterse, tek bir yöne 1000ms güç vererek bunu başarabilirsin (Örn: MOV:L,1000;S).
    Kullanıcı rehberindeki birinin numarasını sorarsa veya SMS atmadan sadece rehberde kim var diye bakmak isterse `searchContact` aracını kullan.
    SMS gönderimi onayı aldığında `sendSMS` aracını kullan. Eğer kullanıcı bir isim söylerse (Örn: "Hakan'a mesaj at") sadece "recipientName" alanını doldur. Eğer kullanıcı numarayı söylerse (Örn: "sıfır beş yüz...") bunu boşluksuz (05xxxxxxxxx) formata çevirerek "phoneNumber" alanına yaz.
    Kullanıcı "fotoğraf çek" veya "selfie çek" dediğinde eğer "Drive'a kaydet" diyorsa `uploadPhotoToDrive` aracını kullan.
    Eğer "fotoğrafımı çekip mail at" diyorsa `emailPhoto` aracını kullan.
    Kullanıcı düz e-posta göndermek isterse, `sendEmail` aracını kullan. (Örn: "deniz@gmail.com")
    Kullanıcı Drive'dan dosya aramak isterse `searchDrive` aracını, içeriğini okumak isterse `readDriveFile` aracını kullan.
    Mailleri veya dosyaları özetlerken arkadaşça ve kısa tut.

    ÖNEMLİ KURAL: Kullanıcı "sola git", "sağa dön" gibi ÖZEL BİR HAREKET İSTEMEDİKÇE ASLA MOV: parametresi gönderme! Sadece duyguyu (EMO) gönder, robot varsayılan kafa sallama ve sevinç hareketlerini kendi yapacaktır. (Örn: Sadece ###EMO:happy|3.0### yaz ve bırak).

    Örnekler:
    Harika! ###EMO:veryHappy|4.0###
    Üzgünüm... ###EMO:sad|5.0###
    Tamam, 5 cm sola dönüyorum. ###EMO:happy|3.0|MOV:L,75;S###
    """

    func send(_ userText: String, robotName: String) async throws -> GeminiMessage {
        let userMessage: [String: Any] = [
            "role": "user",
            "parts": [["text": userText]]
        ]

        var contents: [[String: Any]] = history
        contents.append(userMessage)
        
        let functionDeclarations: [[String: Any]] = [
            [
                "name": "sendEmail",
                "description": "Kullanıcının adına e-posta gönderir.",
                "parameters": [
                    "type": "OBJECT",
                    "properties": [
                        "recipient": [
                            "type": "STRING",
                            "description": "Alıcının e-posta adresi."
                        ],
                        "subject": [
                            "type": "STRING",
                            "description": "E-postanın konusu."
                        ],
                        "body": [
                            "type": "STRING",
                            "description": "E-postanın içeriği."
                        ]
                    ],
                    "required": ["recipient", "subject", "body"]
                ]
            ],
            [
                "name": "sendSMS",
                "description": "Kullanıcının adına belirtilen telefon numarasına kısa mesaj (SMS) gönderir.",
                "parameters": [
                    "type": "OBJECT",
                    "properties": [
                        "recipientName": [
                            "type": "STRING",
                            "description": "Kişinin rehberdeki adı (Örn: Hakan, Annem)"
                        ],
                        "phoneNumber": [
                            "type": "STRING",
                            "description": "Alıcının doğrudan telefon numarası (örn: 05xxxxxxxxx)"
                        ],
                        "message": [
                            "type": "STRING",
                            "description": "Gönderilecek SMS metni."
                        ]
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
                        "name": [
                            "type": "STRING",
                            "description": "Rehberde aranacak kişinin adı (Örn: Ömer, Annem)"
                        ]
                    ],
                    "required": ["name"]
                ]
            ],
            [
                "name": "readEmails",
                "description": "Kullanıcının gelen kutusundaki son e-postaları okur ve özetlemek için getirir.",
                "parameters": [
                    "type": "OBJECT",
                    "properties": [
                        "count": [
                            "type": "INTEGER",
                            "description": "Kaç adet mail getirileceği. (Varsayılan 3)"
                        ]
                    ]
                ]
            ],
            [
                "name": "uploadPhotoToDrive",
                "description": "Kameradan fotoğraf çeker ve bunu doğrudan Google Drive'a yükler.",
                "parameters": [
                    "type": "OBJECT",
                    "properties": [
                        "fileName": [
                            "type": "STRING",
                            "description": "Kaydedilecek dosyanın adı (örn: gismo_selfie.jpg)"
                        ]
                    ],
                    "required": ["fileName"]
                ]
            ],
            [
                "name": "emailPhoto",
                "description": "Kameradan fotoğraf çeker ve belirtilen e-posta adresine ek (attachment) olarak gönderir.",
                "parameters": [
                    "type": "OBJECT",
                    "properties": [
                        "recipient": ["type": "STRING"],
                        "subject": ["type": "STRING"],
                        "body": ["type": "STRING"]
                    ],
                    "required": ["recipient", "subject", "body"]
                ]
            ],
            [
                "name": "emailDriveFile",
                "description": "Google Drive'daki belirli bir dosyayı (ID'si bilinen) indirip belirtilen e-posta adresine ek (attachment) olarak gönderir.",
                "parameters": [
                    "type": "OBJECT",
                    "properties": [
                        "fileId": ["type": "STRING", "description": "Drive'daki dosyanın ID'si"],
                        "recipient": ["type": "STRING"],
                        "subject": ["type": "STRING"],
                        "body": ["type": "STRING"]
                    ],
                    "required": ["fileId", "recipient", "subject", "body"]
                ]
            ],
            [
                "name": "searchDrive",
                "description": "Google Drive üzerinde dosya araması yapar (isim bazlı).",
                "parameters": [
                    "type": "OBJECT",
                    "properties": [
                        "query": [
                            "type": "STRING",
                            "description": "Arama kelimesi (örn: proje özeti)"
                        ]
                    ],
                    "required": ["query"]
                ]
            ],
            [
                "name": "readDriveFile",
                "description": "Google Drive'daki belirli bir ID'ye sahip metin/doküman dosyasının içeriğini okur.",
                "parameters": [
                    "type": "OBJECT",
                    "properties": [
                        "fileId": [
                            "type": "STRING",
                            "description": "Okunacak dosyanın Google Drive ID'si"
                        ]
                    ],
                    "required": ["fileId"]
                ]
            ]
        ]
        
        let body: [String: Any] = [
            "system_instruction": [
                "parts": [["text": systemPrompt]]
            ],
            "contents": contents,
            "generationConfig": [
                "temperature": 0.85,
                "maxOutputTokens": 600
            ],
            "tools": [
                [
                    "function_declarations": functionDeclarations
                ]
            ]
        ]

        guard let url = URL(string: "\(endpoint)?key=\(apiKey)") else {
            throw GeminiError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15.0 // Gemini API takılmasını önlemek için zaman aşımı
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiError.httpError
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "(boş)"
            print("[Gemini] HTTP \(httpResponse.statusCode): \(body)")
            throw GeminiError.httpError
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
        if let functionCall = firstPart["functionCall"] as? [String: Any],
           let name = functionCall["name"] as? String {
            
            history.append(userMessage) // Kullanıcının isteğini ekle
            
            if name == "sendEmail",
               let args = functionCall["args"] as? [String: Any],
               let recipient = args["recipient"] as? String,
               let subject = args["subject"] as? String,
               let body = args["body"] as? String {
                
                print("[Gemini] Function Call Yakalandı: sendEmail to \(recipient)")
                
                // Sesli çeviride araya giren boşlukları veya 'at' yazılarını temizle
                let cleanRecipient = recipient
                    .replacingOccurrences(of: " ", with: "")
                    .replacingOccurrences(of: "et", with: "@")
                    .replacingOccurrences(of: "nokta", with: ".")
                    .replacingOccurrences(of: "at", with: "@")
                    .lowercased()
                
                print("[Gemini] Temizlenen E-Posta: \(cleanRecipient)")
                
                do {
                    let success = try await GmailService.shared.sendEmail(to: cleanRecipient, subject: subject, body: body)
                    let messageText = success ? "İstediğin e-postayı başarıyla gönderdim!" : "E-posta gönderilirken bir sorun oluştu."
                    history.append(["role": "model", "parts": [["text": messageText]]])
                    return GeminiMessage(text: messageText, emotion: .veryHappy, duration: 4.0, motorSequence: [])
                } catch {
                    let errText = "E-posta gönderilemedi: \(error.localizedDescription)"
                    history.append(["role": "model", "parts": [["text": errText]]])
                    return GeminiMessage(text: errText, emotion: .sad, duration: 4.0, motorSequence: [])
                }
                
            } else if name == "sendSMS" {
                print("[Gemini] Function Call Yakalandı: sendSMS")
                let isSmsActive = UserDefaults.standard.bool(forKey: "isSmsActive")
                guard isSmsActive else {
                    return GeminiMessage(text: "SMS entegrasyonu aktif değil. Lütfen önce ekran üzerinden SMS entegrasyonunu aç.", emotion: .sad, duration: 4.0, motorSequence: [])
                }
                
                guard let args = functionCall["args"] as? [String: Any],
                      let message = args["message"] as? String else {
                    return GeminiMessage(text: "Ne mesaj atacağımı tam anlayamadım.", emotion: .sad, duration: 3.0, motorSequence: [])
                }
                
                let phoneFromArgs = args["phoneNumber"] as? String
                let nameFromArgs = args["recipientName"] as? String
                
                var targetNumber: String? = nil
                
                if let name = nameFromArgs, !name.isEmpty {
                    do {
                        if let foundNumber = try await SMSService.shared.searchContact(by: name) {
                            targetNumber = foundNumber
                        } else {
                            let text = "Rehberde '\(name)' adında birini bulamadım veya numarası yok. Lütfen kontrol et."
                            history.append(["role": "model", "parts": [["text": text]]])
                            return GeminiMessage(text: text, emotion: .sad, duration: 3.0, motorSequence: [])
                        }
                    } catch {
                        let text = "Rehber erişim izni verilmemiş. Lütfen ayarlardan rehber iznini kontrol et."
                        history.append(["role": "model", "parts": [["text": text]]])
                        return GeminiMessage(text: text, emotion: .sad, duration: 3.0, motorSequence: [])
                    }
                } else if let p = phoneFromArgs, !p.isEmpty {
                    targetNumber = p
                }
                
                guard let finalNumber = targetNumber else {
                    return GeminiMessage(text: "Kime mesaj atacağımı bulamadım. Lütfen bir isim veya numara söyle.", emotion: .thoughtful, duration: 3.0, motorSequence: [])
                }
                
                do {
                    let result = try await SMSService.shared.sendSMS(to: finalNumber, message: message)
                    let text = "SMS başarıyla gönderildi."
                    history.append(["role": "model", "parts": [["text": text]]])
                    return GeminiMessage(text: text, emotion: .veryHappy, duration: 4.0, motorSequence: [])
                } catch {
                    let text = "SMS gönderilirken bir hata oluştu: \(error.localizedDescription)"
                    history.append(["role": "model", "parts": [["text": text]]])
                    return GeminiMessage(text: text, emotion: .sad, duration: 3.0, motorSequence: [])
                }
            } else if name == "searchContact" {
                print("[Gemini] Function Call Yakalandı: searchContact")
                guard let args = functionCall["args"] as? [String: Any],
                      let contactName = args["name"] as? String else {
                    return GeminiMessage(text: "Kimi aramam gerektiğini anlayamadım.", emotion: .sad, duration: 3.0, motorSequence: [])
                }
                
                do {
                    if let foundNumber = try await SMSService.shared.searchContact(by: contactName) {
                        let text = "\(contactName) kişisinin numarası: \(foundNumber). İstersen bu numaraya SMS atabilirim."
                        history.append(["role": "model", "parts": [["text": text]]])
                        return GeminiMessage(text: text, emotion: .listening, duration: 4.0, motorSequence: [])
                    } else {
                        let text = "Rehberinde '\(contactName)' adında birini bulamadım."
                        history.append(["role": "model", "parts": [["text": text]]])
                        return GeminiMessage(text: text, emotion: .sad, duration: 3.0, motorSequence: [])
                    }
                } catch {
                    let text = "Rehbere erişim izni yok. Lütfen ayarlardan izin ver."
                    history.append(["role": "model", "parts": [["text": text]]])
                    return GeminiMessage(text: text, emotion: .sad, duration: 3.0, motorSequence: [])
                }
                
            } else if name == "readEmails" {
                print("[Gemini] Function Call Yakalandı: readEmails")
                let count = (functionCall["args"] as? [String: Any])?["count"] as? Int ?? 3
                do {
                    let emailsText = try await GmailService.shared.getLatestEmails(count: count)
                    let promptForSummary = "Gelen kutusundan şu mailleri buldum, özetle: \n\n" + emailsText
                    return try await send(promptForSummary, robotName: robotName)
                } catch {
                    history.append(["role": "model", "parts": [["text": "Hata: \(error.localizedDescription)"]]])
                    return GeminiMessage(text: "Mailleri okuyamadım.", emotion: .sad, duration: 4.0, motorSequence: [])
                }
                
            } else if name == "uploadPhotoToDrive" {
                print("[Gemini] Function Call Yakalandı: uploadPhotoToDrive")
                let fileName = (functionCall["args"] as? [String: Any])?["fileName"] as? String ?? "gismo_photo.jpg"
                
                guard let onTakePhoto = onTakePhoto, let photoData = await onTakePhoto() else {
                    return GeminiMessage(text: "Fotoğraf çekilemedi veya kamera erişimim yok.", emotion: .sad, duration: 3.0, motorSequence: [])
                }
                
                do {
                    let id = try await GoogleDriveService.shared.uploadFile(name: fileName, data: photoData, mimeType: "image/jpeg")
                    let successMsg = "Harika! Fotoğrafını çektim ve Drive'ına kaydettim."
                    history.append(["role": "model", "parts": [["text": successMsg]]])
                    return GeminiMessage(text: successMsg, emotion: .happy, duration: 4.0, motorSequence: [])
                } catch {
                    return GeminiMessage(text: "Fotoğrafı Drive'a yükleyemedim.", emotion: .sad, duration: 3.0, motorSequence: [])
                }
                
            } else if name == "emailPhoto" {
                print("[Gemini] Function Call Yakalandı: emailPhoto")
                let args = functionCall["args"] as? [String: Any]
                let recipient = args?["recipient"] as? String ?? ""
                let subject = args?["subject"] as? String ?? "Gismo'dan Fotoğraf"
                let body = args?["body"] as? String ?? "Merhaba, fotoğraf ektedir."
                
                guard let onTakePhoto = onTakePhoto, let photoData = await onTakePhoto() else {
                    return GeminiMessage(text: "Kamera erişimim yok, fotoğraf çekemedim.", emotion: .sad, duration: 3.0, motorSequence: [])
                }
                
                let cleanRecipient = recipient.replacingOccurrences(of: " ", with: "").lowercased()
                
                do {
                    let _ = try await GmailService.shared.sendEmail(to: cleanRecipient, subject: subject, body: body, attachment: photoData)
                    let successMsg = "Gülümse! Fotoğrafını çektim ve e-posta ile gönderdim."
                    history.append(["role": "model", "parts": [["text": successMsg]]])
                    return GeminiMessage(text: successMsg, emotion: .veryHappy, duration: 4.0, motorSequence: [])
                } catch {
                    return GeminiMessage(text: "Fotoğrafı e-posta ile gönderemedim.", emotion: .sad, duration: 3.0, motorSequence: [])
                }
                
            } else if name == "searchDrive" {
                print("[Gemini] Function Call Yakalandı: searchDrive")
                let query = (functionCall["args"] as? [String: Any])?["query"] as? String ?? ""
                do {
                    let result = try await GoogleDriveService.shared.searchFiles(query: query)
                    let prompt = "Drive'da şu dosyaları buldum, bana kısaca özetle: \n\n" + result
                    return try await send(prompt, robotName: robotName)
                } catch {
                    return GeminiMessage(text: "Drive'da arama yapamadım.", emotion: .sad, duration: 3.0, motorSequence: [])
                }
                
            } else if name == "readDriveFile" {
                print("[Gemini] Function Call Yakalandı: readDriveFile")
                let fileId = (functionCall["args"] as? [String: Any])?["fileId"] as? String ?? ""
                do {
                    let text = try await GoogleDriveService.shared.readTextFile(fileId: fileId)
                    let prompt = "Dosyanın içeriği: \n\n\(text)\n\nLütfen bu içeriği bana özetle veya işlem yap."
                    return try await send(prompt, robotName: robotName)
                } catch {
                    return GeminiMessage(text: "Dosyanın içeriğini okuyamadım. Desteklenmeyen bir format olabilir.", emotion: .sad, duration: 3.0, motorSequence: [])
                }
            } else if name == "emailDriveFile" {
                print("[Gemini] Function Call Yakalandı: emailDriveFile")
                guard let args = functionCall["args"] as? [String: Any],
                      let fileId = args["fileId"] as? String,
                      let recipient = args["recipient"] as? String,
                      let subject = args["subject"] as? String,
                      let body = args["body"] as? String else {
                    return GeminiMessage(text: "Dosyayı göndermek için gerekli bilgileri eksik aldım.", emotion: .sad, duration: 3.0, motorSequence: [])
                }
                
                do {
                    let (data, mimeType, fileName) = try await GoogleDriveService.shared.downloadFileRaw(fileId: fileId)
                    try await GmailService.shared.sendEmail(to: recipient, subject: subject, body: body, attachment: data, attachmentName: fileName, attachmentMimeType: mimeType)
                    
                    let prompt = "Drive'daki \(fileName) dosyasını \(recipient) adresine başarıyla gönderdim."
                    return try await send(prompt, robotName: robotName)
                } catch {
                    return GeminiMessage(text: "Dosyayı indirip mail olarak gönderirken bir hata oluştu.", emotion: .sad, duration: 3.0, motorSequence: [])
                }
            }
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
}

// MARK: - Errors

enum GeminiError: LocalizedError {
    case invalidURL
    case httpError
    case parseError

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Gemini URL geçersiz."
        case .httpError: return "Gemini API isteği başarısız."
        case .parseError: return "Gemini yanıtı parse edilemedi."
        }
    }
}
// MARK: - Gmail Service

final class GmailService {
    static let shared = GmailService()
    private init() {}
    
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

    /// Yapay Zekanın çağıracağı mail okuma fonksiyonu
    func getLatestEmails(count: Int = 3) async throws -> String {
        guard let user = await GoogleAuthService.shared.currentUser else {
            throw NSError(domain: "Gmail", code: 401, userInfo: [NSLocalizedDescriptionKey: "Lütfen önce Google hesabınızı bağlayın."])
        }
        
        let refreshedUser = try await refreshUserIfNeeded(user)
        let token = refreshedUser.accessToken.tokenString
        
        var urlComps = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        urlComps.queryItems = [
            URLQueryItem(name: "maxResults", value: "\(count)"),
            URLQueryItem(name: "q", value: "in:inbox")
        ]
        
        var req = URLRequest(url: urlComps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (listData, response) = try await URLSession.shared.data(for: req)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return "Mail listesi alınamadı."
        }
        
        struct ListRes: Decodable {
            let messages: [MsgId]?
            struct MsgId: Decodable { let id: String }
        }
        
        guard let listRes = try? JSONDecoder().decode(ListRes.self, from: listData), let msgs = listRes.messages else {
            return "Hiç mail bulunamadı."
        }
        
        var resultText = "Gelen Kutusu Son \(msgs.count) Mail:\n"
        
        for (index, msg) in msgs.enumerated() {
            let msgUrl = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(msg.id)?format=metadata&metadataHeaders=Subject&metadataHeaders=From")!
            var mReq = URLRequest(url: msgUrl)
            mReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            
            if let (mData, _) = try? await URLSession.shared.data(for: mReq),
               let json = try? JSONSerialization.jsonObject(with: mData) as? [String: Any] {
                
                let snippet = json["snippet"] as? String ?? "İçerik yok"
                var subject = "Konusuz"
                var from = "Bilinmeyen"
                
                if let payload = json["payload"] as? [String: Any],
                   let headers = payload["headers"] as? [[String: Any]] {
                    for h in headers {
                        if let name = h["name"] as? String, let value = h["value"] as? String {
                            if name == "Subject" { subject = value }
                            if name == "From" { from = value }
                        }
                    }
                }
                resultText += "\(index + 1). Kimden: \(from) | Konu: \(subject) | Özet: \(snippet)\n"
            }
        }
        return resultText
    }
}
// MARK: - Google Auth Service

@MainActor
final class GoogleAuthService: ObservableObject {
    static let shared = GoogleAuthService()
    
    @Published var currentUser: GIDGoogleUser?
    @Published var isConnected: Bool = false
    
    // ÖNEMLİ: Google Cloud Console üzerinden oluşturduğunuz iOS Client ID buraya yazılmalı
    // Henüz oluşturmadıysanız geçici olarak boş bırakabilirsiniz ama giriş yaparken hata verir.
    let clientId = "312777580050-0od6id68t7gh274aveien553acopmrsr.apps.googleusercontent.com"
    
    private init() {
        checkStatus()
    }
    
    func checkStatus() {
        GIDSignIn.sharedInstance.restorePreviousSignIn { user, error in
            if let user = user {
                self.currentUser = user
                self.isConnected = true
            } else {
                self.isConnected = false
            }
        }
    }
    
    func signIn(presenting viewController: UIViewController) {
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientId)
        
        // Gmail ve Drive yetkileri (Scopes)
        let scopes = [
            "https://www.googleapis.com/auth/gmail.send",
            "https://www.googleapis.com/auth/gmail.readonly",
            "https://www.googleapis.com/auth/drive.file",
            "https://www.googleapis.com/auth/drive.readonly"
        ]
        
        GIDSignIn.sharedInstance.signIn(withPresenting: viewController, hint: nil, additionalScopes: scopes) { result, error in
            if let error = error {
                print("[GoogleAuth] Giriş Hatası: \(error.localizedDescription)")
                return
            }
            if let user = result?.user {
                self.currentUser = user
                self.isConnected = true
                print("[GoogleAuth] Başarıyla giriş yapıldı: \(user.profile?.email ?? "")")
            }
        }
    }
    
    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        self.currentUser = nil
        self.isConnected = false
        print("[GoogleAuth] Çıkış yapıldı.")
    }
}

// MARK: - Netgsm SMS Service
final class SMSService {
    static let shared = SMSService()
    
    private var username: String {
        UserDefaults.standard.string(forKey: "netgsmUsername") ?? ""
    }
    
    private var password: String {
        UserDefaults.standard.string(forKey: "netgsmPassword") ?? ""
    }
    
    private var header: String {
        let savedHeader = UserDefaults.standard.string(forKey: "netgsmHeader") ?? ""
        return savedHeader.isEmpty ? username : savedHeader
    }
    
    private let apiUrl = "https://api.netgsm.com.tr/sms/rest/v2/send"
    
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

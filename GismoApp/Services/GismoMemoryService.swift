import Foundation
import UIKit

// MARK: - Gismo Kalıcı Hafıza Modeli

struct GismoMemoryItem: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var category: String   // "owner" | "person" | "topic" | "note"
    var subject: String    // Örn: "Sahibim", "Mert (Arkadaş)", "Kahve Tercihi", "Yedek Anahtar"
    var content: String    // Örn: "Adı Deniz, kahvesini şekersiz sever."
    var updatedAt: Date

    var categoryTitle: String {
        switch category {
        case "owner":  return "Sahibim"
        case "person": return "Tanışılan Kişi"
        case "topic":  return "Konuşulan Konu"
        default:       return "Kalıcı Not"
        }
    }
}

// MARK: - GismoMemoryService (Yerel + PostgreSQL Bulut Senkronizasyonlu Kalıcı Hafıza)

final class GismoMemoryService: @unchecked Sendable {
    static let shared = GismoMemoryService()

    private let legacyStorageKey = "gismo_permanent_memories_v1"
    private let deviceIdKey = "gismo_memory_device_id"
    private let lock = NSLock()
    private var items: [GismoMemoryItem] = []

    /// Aktif konuşulan robotun adı (kullanıcının verdiği isim)
    var activeRobotNameOverride: String?

    /// Yeni bir hafıza eklendiğinde Gemini Live oturumunun güncellenmesi için sayaç
    private(set) var revision: Int = 0

    var deviceId: String {
        if let saved = UserDefaults.standard.string(forKey: deviceIdKey), !saved.isEmpty {
            return saved
        }
        let fresh = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: deviceIdKey)
        return fresh
    }

    private var currentUserId: String? {
        guard let data = UserDefaults.standard.data(forKey: "gismo_auth_current_user"),
              let user = try? JSONDecoder().decode(GismoUser.self, from: data) else {
            return nil
        }
        return user.id
    }

    private var currentUserName: String? {
        guard let data = UserDefaults.standard.data(forKey: "gismo_auth_current_user"),
              let user = try? JSONDecoder().decode(GismoUser.self, from: data),
              !user.fullName.isEmpty else {
            return nil
        }
        return user.fullName
    }

    /// Her kullanıcının hafızasını kendi kullanıcı ID'si altında izole tutar
    private var activeStorageKey: String {
        if let uid = currentUserId, !uid.isEmpty {
            return "gismo_permanent_memories_v1_\(uid)"
        }
        return "gismo_permanent_memories_v1_guest"
    }

    /// Kullanıcının robotuna verdiği aktif isim
    var activeRobotName: String {
        if let override = activeRobotNameOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        if let uid = currentUserId,
           let saved = UserDefaults.standard.string(forKey: "user_custom_robot_name_\(uid)")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !saved.isEmpty {
            return saved
        }
        return "Robot"
    }

    private init() {
        loadFromDisk()
        seedOwnerFromAuthIfNeeded()
        Task {
            await syncFromServer()
        }
    }

    // MARK: - User Session Switching & Disk Persistence

    func reloadForCurrentUser() {
        loadFromDisk()
        seedOwnerFromAuthIfNeeded()
        Task {
            await syncFromServer()
        }
    }

    func clearCurrentUserLocalMemories() {
        let key = activeStorageKey
        lock.lock()
        items = []
        revision &+= 1
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: legacyStorageKey)
        lock.unlock()
    }

    private func loadFromDisk() {
        lock.lock()
        defer { lock.unlock() }

        guard currentUserId != nil else {
            items = []
            return
        }

        let key = activeStorageKey
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([GismoMemoryItem].self, from: data) {
            items = decoded.sorted { $0.updatedAt > $1.updatedAt }
            return
        }

        // Tek seferlik eski anahtardan aktif kullanıcıya taşıma
        if let legacyData = UserDefaults.standard.data(forKey: legacyStorageKey),
           let decoded = try? JSONDecoder().decode([GismoMemoryItem].self, from: legacyData) {
            items = decoded.sorted { $0.updatedAt > $1.updatedAt }
            saveToDiskLocked()
            UserDefaults.standard.removeObject(forKey: legacyStorageKey)
            return
        }

        items = []
    }

    private func saveToDiskLocked() {
        guard currentUserId != nil else { return }
        if let encoded = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(encoded, forKey: activeStorageKey)
        }
    }

    func seedOwnerFromAuthIfNeeded() {
        guard let name = currentUserName, !name.isEmpty, name != "Gismo Kullanıcısı", name != "Kullanıcı" else { return }
        lock.lock()
        let hasOwnerName = items.contains { $0.category == "owner" && $0.subject.lowercased().contains("sahibimin ismi") }
        lock.unlock()
        if !hasOwnerName {
            _ = upsertMemory(
                category: "owner",
                subject: "Sahibimin İsmi",
                content: "Sahibimin adı \(name).",
                syncRemote: true
            )
        }
    }

    // MARK: - CRUD Operations

    func allMemories() -> [GismoMemoryItem] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    @discardableResult
    func upsertMemory(
        category: String,
        subject: String,
        content: String,
        id: String? = nil,
        syncRemote: Bool = true
    ) -> GismoMemoryItem {
        let cleanCategory = ["owner", "person", "topic", "note"].contains(category.lowercased())
            ? category.lowercased()
            : "note"
        let cleanSubject = String(subject.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let cleanContent = String(content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))

        lock.lock()
        let savedItem: GismoMemoryItem
        if let idx = items.firstIndex(where: {
            $0.category == cleanCategory && $0.subject.caseInsensitiveCompare(cleanSubject) == .orderedSame
        }) {
            var existing = items[idx]
            existing.content = cleanContent
            existing.updatedAt = Date()
            if let id, !id.isEmpty { existing.id = id }
            items.remove(at: idx)
            items.insert(existing, at: 0)
            savedItem = existing
        } else {
            let newItem = GismoMemoryItem(
                id: id ?? UUID().uuidString,
                category: cleanCategory,
                subject: cleanSubject.isEmpty ? "Bilgi" : cleanSubject,
                content: cleanContent,
                updatedAt: Date()
            )
            items.insert(newItem, at: 0)
            // Yerel önbellekte en güncel 300 kaydı tut (tüm geçmiş PostgreSQL'de korunur)
            if items.count > 300 {
                items = Array(items.prefix(300))
            }
            savedItem = newItem
        }
        revision &+= 1
        saveToDiskLocked()
        lock.unlock()

        if syncRemote {
            Task {
                await pushMemoryToServer(savedItem)
            }
        }
        return savedItem
    }

    func searchMemories(query: String?) -> [GismoMemoryItem] {
        let q = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        lock.lock()
        let snapshot = items
        lock.unlock()

        guard !q.isEmpty else { return snapshot }
        return snapshot.filter {
            $0.subject.lowercased().contains(q)
                || $0.content.lowercased().contains(q)
                || $0.category.lowercased().contains(q)
        }
    }

    func deleteMemories(matching query: String) -> Int {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return 0 }

        lock.lock()
        let beforeCount = items.count
        items.removeAll {
            $0.subject.lowercased().contains(q) || $0.content.lowercased().contains(q)
        }
        let removed = beforeCount - items.count
        if removed > 0 {
            revision &+= 1
            saveToDiskLocked()
        }
        lock.unlock()

        if removed > 0 {
            Task {
                await deleteFromServer(query: q)
            }
        }
        return removed
    }

    // MARK: - Prompt Context (L1 Sabit Bütçeli Özet + L2 Derin Arşiv Arama)

    /// Hafızada binlerce kayıt olsa bile sistemin ASLA yavaşlamaması için:
    /// - Prompt içine yalnızca en güncel/çekirdek kayıtlar (maksimum ~1.800 karakter / ~350 token bütçesiyle) eklenir.
    /// - Daha eski kayıtlar prompt'u şişirmez; Gismo ihtiyaç duyduğunda `recallMemories(query:)` aracıyla arşivden arar.
    func promptContext() -> String {
        seedOwnerFromAuthIfNeeded()
        lock.lock()
        let snapshot = items
        lock.unlock()

        let ownerFacts  = Array(snapshot.filter { $0.category == "owner" }.prefix(8))
        let peopleFacts = Array(snapshot.filter { $0.category == "person" }.prefix(10))
        let notes       = Array(snapshot.filter { $0.category == "note" }.prefix(10))
        let topics      = Array(snapshot.filter { $0.category == "topic" }.prefix(6))

        let includedCount = ownerFacts.count + peopleFacts.count + notes.count + topics.count
        let archivedExtraCount = max(0, snapshot.count - includedCount)
        let currentRobotName = activeRobotName

        var lines: [String] = [
            "ROBOT KİMLİĞİ VE KALICI HAFIZA (BELLEK) SİSTEMİ:",
            "- SENİN ADIN: Kullanıcının sana verdiği özel isim \"\(currentRobotName)\". Adın sorulduğunda, kendini tanıtırken veya konuşurken her zaman adının \"\(currentRobotName)\" olduğunu bil ve söyle (asla Gismo deme).",
            "- Sahibini, konuştuğunuz konuları, tanıştığın kişileri ve 'bunu aklında tut / unutma' denilen her şeyi kullanıcının hesabına özel kalıcı hafızanda tutarsın.",
            "- Kullanıcı sana kendisiyle ilgili bir bilgi söylediğinde (`category: 'owner'`), bir kişiyi tanıttığında (`category: 'person'`), önemli bir konudan konuştuğunuzda (`category: 'topic'`) ya da 'bunu aklında tut / unutma / hafızana kaydet' dediğinde (`category: 'note'`) `saveMemory` aracını çağır.",
            "- Aşağıdaki listede olmayan daha eski bir kişi, konu veya not sorulursa `recallMemories` aracını çağırarak tüm hafıza arşivinde ara.",
            "- Kullanıcı 'bunu unut / hafızandan sil' derse `forgetMemory` aracını çağır."
        ]

        let maxPromptBodyChars = 1800
        var usedChars = 0

        func appendSection(title: String, list: [GismoMemoryItem]) {
            guard !list.isEmpty, usedChars < maxPromptBodyChars else { return }
            lines.append(title)
            for item in list {
                let compactContent = String(item.content.prefix(140))
                let entry = "  - [\(item.subject)]: \(compactContent)"
                if usedChars + entry.count > maxPromptBodyChars { break }
                lines.append(entry)
                usedChars += entry.count
            }
        }

        appendSection(title: "• SAHİBİN HAKKINDA BİLDİKLERİN:", list: ownerFacts)
        appendSection(title: "• TANIŞTIĞIN / BİLDİĞİN KİŞİLER:", list: peopleFacts)
        appendSection(title: "• AKLINDA TUTMAN İSTENEN KALICI NOTLAR:", list: notes)
        appendSection(title: "• SON KONUŞULAN KONULAR:", list: topics)

        if archivedExtraCount > 0 {
            lines.append("• NOT: Arşivde +\(archivedExtraCount) adet daha eski hafıza kaydı var. Gerekirse `recallMemories` ile sorgula.")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - AI Function Calling Declarations & Execution

    static let functionDeclarations: [[String: Any]] = [
        [
            "name": "saveMemory",
            "description": "Sahibin (kullanıcı) hakkında bir bilgiyi, tanışılan bir kişiyi, konuşulan önemli bir konuyu veya kullanıcının 'bunu aklında tut / unutma / kaydet' dediği bir notu Gismo'nun kalıcı hafızasına kaydeder.",
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "category": [
                        "type": "STRING",
                        "description": "Hafıza kategorisi: 'owner' (sahibi hakkında bilgi/tercih), 'person' (tanışılan veya bahsedilen kişi), 'topic' (konuşulan konu), 'note' ('bunu aklında tut' denilen özel bilgi)."
                    ],
                    "subject": [
                        "type": "STRING",
                        "description": "Kısa başlık veya kişi adı (Örn: 'Sahibimin Mesleği', 'Ahmet (Arkadaş)', 'Yedek Anahtar Yeri', 'Tatil Planı')."
                    ],
                    "content": [
                        "type": "STRING",
                        "description": "Hatırlanacak detaylı bilgi (Örn: 'Ahmet yazılım mühendisi ve İzmir'de yaşıyor.')."
                    ]
                ],
                "required": ["category", "subject", "content"]
            ]
        ],
        [
            "name": "recallMemories",
            "description": "Gismo'nun kalıcı hafızasında kayıtlı olan bilgileri (sahibi, kişiler, önceki konular, notlar) arar ve getirir.",
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "query": [
                        "type": "STRING",
                        "description": "Aranacak kişi, konu veya anahtar kelime (tüm hafızayı görmek için boş bırakılabilir)."
                    ]
                ]
            ]
        ],
        [
            "name": "forgetMemory",
            "description": "Kullanıcı 'bunu unut' veya 'hafızandan sil' dediğinde ilgili bilgiyi kalıcı hafızadan siler.",
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "query": [
                        "type": "STRING",
                        "description": "Silinecek bilginin başlığı veya anahtar kelimesi."
                    ]
                ],
                "required": ["query"]
            ]
        ]
    ]

    func executeTool(name: String, args: [String: Any]) -> String? {
        switch name {
        case "saveMemory":
            let category = (args["category"] as? String ?? "note").trimmingCharacters(in: .whitespacesAndNewlines)
            let subject  = (args["subject"] as? String ?? "Bilgi").trimmingCharacters(in: .whitespacesAndNewlines)
            let content  = (args["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                return "Kaydedilecek bilgi boş olamaz."
            }
            let saved = upsertMemory(category: category, subject: subject, content: content)
            return "Kalıcı hafızaya kaydedildi: [\(saved.categoryTitle) - \(saved.subject)] \(saved.content)"

        case "recallMemories":
            let query = args["query"] as? String
            let matches = searchMemories(query: query)
            if matches.isEmpty {
                return "Kalıcı hafızada bu aramayla eşleşen bir kayıt bulunamadı."
            }
            let formatted = matches.prefix(25).map {
                "- [\($0.categoryTitle) | \($0.subject)]: \($0.content)"
            }.joined(separator: "\n")
            return "Kalıcı Hafıza Kayıtları:\n\(formatted)"

        case "forgetMemory":
            let query = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let count = deleteMemories(matching: query)
            if count > 0 {
                return "'\(query)' ile ilgili \(count) kayıt kalıcı hafızadan silindi."
            } else {
                return "Hafızada '\(query)' ile eşleşen bir kayıt bulunamadı."
            }

        default:
            return nil
        }
    }

    // MARK: - Otomatik Arka Plan Hafıza Çıkarımı (Konuşulan Konular, Tanışılan Kişiler, Sahibi ve "Aklında Tut")

    /// Her konuşma turundan sonra arka planda (0 gecikmeyle) çalışarak:
    /// 1) Kullanıcı "aklında tut / unutma" dediyse veya kendisi/tanıştığı kişiler hakkında bilgi verdiyse çıkarır,
    /// 2) Konuşulan önemli konuları otomatik olarak kalıcı hafızaya özetler.
    func analyzeAndMemorizeTurn(userText: String, assistantText: String, apiKey: String) async {
        let trimmedUser = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedUser.count >= 4 else { return }
        if trimmedUser.hasPrefix("[SİSTEM BİLDİRİMİ") { return }

        // 1. Hızlı yerel kural: "aklinda tut", "unutma", "hafızana kaydet" ifadelerini anında yakala (çevrimdışı bile çalışır)
        let lower = trimmedUser.lowercased()
        let explicitTriggers = [
            "aklında tut", "aklinda tut", "bunu unutma", "şunu unutma",
            "hafızana kaydet", "hafizana kaydet", "hafızanda tut", "hatırla ki"
        ]
        if explicitTriggers.contains(where: { lower.contains($0) }) {
            // Eğer aynı turda saveMemory aracı zaten kaydetmediyse yerel yedeği kaydet
            let existing = searchMemories(query: trimmedUser)
            if existing.isEmpty {
                upsertMemory(
                    category: "note",
                    subject: "Kullanıcı Notu",
                    content: trimmedUser
                )
            }
        }

        // 2. Gemini ile akıllı varlık/kişi/sahip/konu çıkarımı (arka planda sessizce)
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else { return }

        let extractionPrompt = """
        Aşağıdaki kullanıcı-robot konuşmasını incele.
        Eğer kullanıcının söylediklerinde:
        1. Sahibi (kullanıcı) hakkında kalıcı bir bilgi, isim, meslek, alışkanlık, tercih varsa -> category: "owner"
        2. Tanıştırılan veya bahsedilen bir kişi (arkadaş, aile, iş arkadaşı vb.) varsa -> category: "person"
        3. Kullanıcının özellikle "aklında tut", "unutma", "hatırla" dediği bir bilgi varsa -> category: "note"
        4. Üzerinde konuşulan anlamlı bir sohbet konusu, plan veya olay varsa -> category: "topic"

        Sıradan selamlaşma veya basit komutlarda ("merhaba", "ileri git", "saat kaç") boş dizi `[]` döndür.
        SADECE geçerli bir JSON dizisi döndür (başka metin yazma):
        [{"category":"owner|person|note|topic","subject":"Kısa Başlık","content":"Özlü bilgi cümlesi"}]

        Kullanıcı: \(trimmedUser)
        Gismo: \(assistantText)
        """

        let body: [String: Any] = [
            "contents": [
                ["role": "user", "parts": [["text": extractionPrompt]]]
            ],
            "generationConfig": [
                "temperature": 0.1,
                "maxOutputTokens": 250,
                "responseMimeType": "application/json"
            ]
        ]

        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=\(cleanKey)"),
              let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let parts = (candidates.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]],
              let rawText = parts.first?["text"] as? String else {
            return
        }

        let cleanedJSON = rawText
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        struct ExtractedFact: Decodable {
            let category: String
            let subject: String
            let content: String
        }

        guard let jsonData = cleanedJSON.data(using: .utf8),
              let extracted = try? JSONDecoder().decode([ExtractedFact].self, from: jsonData) else {
            return
        }

        for fact in extracted {
            let subj = fact.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            let cont = fact.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !subj.isEmpty, !cont.isEmpty else { continue }
            upsertMemory(category: fact.category, subject: subj, content: cont)
            print("[Memory] Otomatik hafızaya alındı: [\(fact.category)] \(subj) -> \(cont)")
        }
    }

    // MARK: - Remote PostgreSQL Sync (/api/memories)

    func syncFromServer() async {
        guard let uid = currentUserId, !uid.isEmpty else { return }
        var components = URLComponents(string: "\(Config.baseURL)/api/memories")
        components?.queryItems = [
            URLQueryItem(name: "user_id", value: uid),
            URLQueryItem(name: "device_id", value: deviceId)
        ]
        guard let url = components?.url else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(Config.apiKey, forHTTPHeaderField: "x-api-key")
        req.timeoutInterval = 10

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["memories"] as? [[String: Any]] else {
            return
        }

        for row in rows {
            guard let subject = row["subject"] as? String,
                  let content = row["content"] as? String else { continue }
            let category = row["category"] as? String ?? "note"
            let id = row["id"] as? String
            _ = upsertMemory(
                category: category,
                subject: subject,
                content: content,
                id: id,
                syncRemote: false
            )

            // Bulut hafızada "Robotun İsmi" kayıtlıysa ve bu cihazda henüz yoksa otomatik geri yükle
            if subject.caseInsensitiveCompare("Robotun İsmi") == .orderedSame {
                let extractedName = content
                    .replacingOccurrences(of: "Benim adım ", with: "")
                    .replacingOccurrences(of: ".", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !extractedName.isEmpty {
                    let key = "user_custom_robot_name_\(uid)"
                    if (UserDefaults.standard.string(forKey: key) ?? "").isEmpty {
                        UserDefaults.standard.set(extractedName, forKey: key)
                        await MainActor.run {
                            AuthService.shared.refreshCustomRobotNameState()
                        }
                    }
                }
            }
        }
    }

    private func pushMemoryToServer(_ item: GismoMemoryItem) async {
        guard let url = URL(string: "\(Config.baseURL)/api/memories") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Config.apiKey, forHTTPHeaderField: "x-api-key")
        req.timeoutInterval = 10

        var body: [String: Any] = [
            "device_id": deviceId,
            "category": item.category,
            "subject": item.subject,
            "content": item.content
        ]
        if let uid = currentUserId {
            body["user_id"] = uid
        }

        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }

    private func deleteFromServer(query: String) async {
        guard let url = URL(string: "\(Config.baseURL)/api/memories") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Config.apiKey, forHTTPHeaderField: "x-api-key")
        req.timeoutInterval = 10

        var body: [String: Any] = [
            "device_id": deviceId,
            "query": query
        ]
        if let uid = currentUserId {
            body["user_id"] = uid
        }

        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }
}

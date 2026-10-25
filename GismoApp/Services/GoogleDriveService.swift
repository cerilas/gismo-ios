import Foundation
import GoogleSignIn
import PDFKit
import UIKit

final class GoogleDriveService {
    static let shared = GoogleDriveService()
    private init() {}

    struct DriveFileItem {
        let id: String
        let name: String
        let mimeType: String
        let modifiedTime: String
    }

    /// Son aramada önerilen benzer dosyalar ("birincisi", "ikincisi" veya kısa isimle seçim için)
    private(set) var lastSuggestedFiles: [DriveFileItem] = []

    private func getValidAccessToken() async throws -> String {
        guard let user = await GoogleAuthService.shared.currentUser else {
            throw NSError(
                domain: "Drive",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "Lütfen önce Entegrasyonlar menüsünden Google hesabınızı bağlayın."]
            )
        }
        let refreshedUser = try await refreshUserIfNeeded(user)
        return refreshedUser.accessToken.tokenString
    }

    private func refreshUserIfNeeded(_ user: GIDGoogleUser) async throws -> GIDGoogleUser {
        return try await withCheckedThrowingContinuation { continuation in
            user.refreshTokensIfNeeded { refreshedUser, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let refreshedUser = refreshedUser {
                    continuation.resume(returning: refreshedUser)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "Drive",
                        code: 500,
                        userInfo: [NSLocalizedDescriptionKey: "Google oturum anahtarı yenilenemedi."]
                    ))
                }
            }
        }
    }

    // MARK: - Upload Binary / Photo / Document File (multipart/related)

    func uploadFile(name: String, data: Data, mimeType: String, folderId: String? = nil) async throws -> String {
        let token = try await getValidAccessToken()

        let url = URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,name,webViewLink")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 25.0

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var metadata: [String: Any] = ["name": name]
        if let folderId, !folderId.isEmpty {
            metadata["parents"] = [folderId]
        }
        let metadataData = try JSONSerialization.data(withJSONObject: metadata)

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metadataData)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let errString = String(data: responseData, encoding: .utf8) ?? "Bilinmeyen API Hatası"
            print("[Drive] Upload Error: \(errString)")
            throw NSError(domain: "Drive", code: 500, userInfo: [NSLocalizedDescriptionKey: "Drive'a dosya yüklenemedi: \(errString)"])
        }

        if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
           let id = json["id"] as? String {
            print("[Drive] Dosya yüklendi ID: \(id)")
            return id
        }

        return "Yüklendi"
    }

    // MARK: - Create / Save Text or Note File to Drive

    func createTextFile(name: String, content: String) async throws -> String {
        let safeName: String
        if name.lowercased().hasSuffix(".txt") || name.lowercased().hasSuffix(".md") {
            safeName = name
        } else {
            safeName = "\(name).txt"
        }
        guard let data = content.data(using: .utf8) else {
            throw NSError(domain: "Drive", code: 400, userInfo: [NSLocalizedDescriptionKey: "Metin verisi oluşturulamadı."])
        }
        return try await uploadFile(name: safeName, data: data, mimeType: "text/plain; charset=utf-8")
    }

    // MARK: - Search / List Files in Drive

    func fetchDriveFiles(query: String, pageSize: Int = 8, onlyImages: Bool = false) async throws -> [DriveFileItem] {
        let token = try await getValidAccessToken()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let escaped = trimmed.replacingOccurrences(of: "'", with: "\\'")

        var qParts: [String] = ["trashed = false"]
        if onlyImages {
            qParts.append("mimeType contains 'image/'")
        }
        if !escaped.isEmpty && escaped != "*" && escaped.lowercased() != "hepsi" && escaped.lowercased() != "tümü" && escaped.lowercased() != "son" {
            qParts.append("name contains '\(escaped)'")
        }

        var urlComps = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        urlComps.queryItems = [
            URLQueryItem(name: "q", value: qParts.joined(separator: " and ")),
            URLQueryItem(name: "fields", value: "files(id, name, mimeType, modifiedTime)"),
            URLQueryItem(name: "orderBy", value: "modifiedTime desc"),
            URLQueryItem(name: "pageSize", value: "\(pageSize)")
        ]

        var request = URLRequest(url: urlComps.url!)
        request.timeoutInterval = 15.0
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errText = String(data: data, encoding: .utf8) ?? ""
            print("[Drive] Search Error: \(errText)")
            throw NSError(domain: "Drive", code: 500, userInfo: [NSLocalizedDescriptionKey: "Drive araması başarısız oldu."])
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = json["files"] as? [[String: Any]] else {
            return []
        }

        return files.compactMap { dict in
            guard let id = dict["id"] as? String,
                  let name = dict["name"] as? String else { return nil }
            let mime = dict["mimeType"] as? String ?? "application/octet-stream"
            let modified = dict["modifiedTime"] as? String ?? ""
            return DriveFileItem(id: id, name: name, mimeType: mime, modifiedTime: modified)
        }
    }

    func searchFiles(query: String) async throws -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let isListAll = trimmed.isEmpty || trimmed == "*" || ["hepsi", "tümü", "son", "son dosyalar"].contains(trimmed.lowercased())

        if isListAll {
            let items = try await fetchDriveFiles(query: "", pageSize: 8)
            guard !items.isEmpty else {
                return "Google Drive'ında henüz hiç dosya bulunamadı."
            }
            lastSuggestedFiles = items
            var resultText = "Google Drive Son Dosyalar (\(items.count) sonuç):\n"
            for (index, item) in items.enumerated() {
                let readableType = Self.humanReadableMimeType(item.mimeType)
                resultText += "\(index + 1). İsim: \(item.name) | ID: \(item.id) | Tür: \(readableType)\n"
            }
            return resultText
        }

        let (exactMatch, similarFiles, recentFiles) = try await findBestAndSimilarFiles(query: trimmed, limit: 5)

        if let exact = exactMatch, similarFiles.count <= 1 {
            lastSuggestedFiles = [exact]
            let readableType = Self.humanReadableMimeType(exact.mimeType)
            return "Google Drive'da aranan dosya bulundu:\n1. İsim: \(exact.name) | ID: \(exact.id) | Tür: \(readableType)"
        }

        if !similarFiles.isEmpty {
            lastSuggestedFiles = similarFiles
            var resultText = "[BENZER DRIVE DOSYALARI BULUNDU]\nAranan: '\(trimmed)' — Birebir aynı isim yerine Drive'da şu benzer dosyalar bulundu (\(similarFiles.count) adet):\n"
            for (index, item) in similarFiles.enumerated() {
                let readableType = Self.humanReadableMimeType(item.mimeType)
                resultText += "\(index + 1). İsim: \(item.name) | ID: \(item.id) | Tür: \(readableType)\n"
            }
            resultText += "Lütfen kullanıcıya bu benzer dosya isimlerini söyleyip 'Şu dosya mı yoksa bu dosya mı?' diye sor."
            return resultText
        }

        if !recentFiles.isEmpty {
            let topRecent = Array(recentFiles.prefix(4))
            lastSuggestedFiles = topRecent
            var resultText = "[DRIVE DOSYASI BULUNAMADI]\nGoogle Drive'da '\(trimmed)' adına benzer bir dosya bulunamadı. Ancak Drive'daki son dosyalar şunlar:\n"
            for (index, item) in topRecent.enumerated() {
                let readableType = Self.humanReadableMimeType(item.mimeType)
                resultText += "\(index + 1). İsim: \(item.name) | ID: \(item.id) | Tür: \(readableType)\n"
            }
            return resultText
        }

        return "[DRIVE DOSYASI BULUNAMADI] Google Drive'da '\(trimmed)' aramasına uygun hiçbir dosya bulunamadı."
    }

    // MARK: - Akıllı Bulanık (Fuzzy) Dosya Eşleştirme ve Benzer Dosya Bulucu

    /// Kullanıcının sesli söylediği dosya adını (birebir tutmasa bile) Türkçe normalize edilmiş kelime kökü ve karakter benzerliği ile Drive dosyaları arasında arar.
    func findBestAndSimilarFiles(query: String, limit: Int = 5) async throws -> (exactMatch: DriveFileItem?, similarFiles: [DriveFileItem], allRecentFiles: [DriveFileItem]) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Kullanıcı "birincisi", "ikincisi", "ilk dosya" dediyse son önerilenlerden çöz
        if let ordinalMatch = resolveOrdinalSelection(from: trimmed), !lastSuggestedFiles.isEmpty {
            return (ordinalMatch, [ordinalMatch], lastSuggestedFiles)
        }

        // 2. Hem doğrudan sorguyu hem de kullanıcının son 50 Drive dosyasını çekip birleştir
        async let directFetch = (try? fetchDriveFiles(query: trimmed, pageSize: 12)) ?? []
        async let recentFetch = (try? fetchDriveFiles(query: "", pageSize: 50)) ?? []

        let directItems = await directFetch
        let recentItems = await recentFetch

        var seenIds = Set<String>()
        var pool: [DriveFileItem] = []
        for item in (directItems + recentItems + lastSuggestedFiles) {
            if !seenIds.contains(item.id) {
                seenIds.insert(item.id)
                pool.append(item)
            }
        }

        guard !pool.isEmpty else {
            return (nil, [], [])
        }

        // 3. Her dosyayı bulanık benzerlik (Fuzzy Similarity) ile puanla
        let scored: [(file: DriveFileItem, score: Double)] = pool.map { file in
            let s = Self.similarityScore(query: trimmed, fileName: file.name)
            return (file, s)
        }.sorted { $0.score > $1.score }

        guard let best = scored.first else {
            return (nil, [], recentItems)
        }

        let secondScore = scored.count > 1 ? scored[1].score : 0.0

        // Tek ve çok net bir eşleşme varsa exactMatch olarak döndür
        let isClearExactMatch = (best.score >= 0.92 && (best.score - secondScore >= 0.12))
            || (best.score >= 0.98 && secondScore < 0.95)

        let similar = scored
            .filter { $0.score >= 0.28 }
            .prefix(limit)
            .map { $0.file }

        if isClearExactMatch {
            return (best.file, similar.isEmpty ? [best.file] : similar, recentItems)
        }

        return (nil, similar, recentItems)
    }

    private func resolveOrdinalSelection(from raw: String) -> DriveFileItem? {
        let norm = Self.normalizeText(raw)
        guard !lastSuggestedFiles.isEmpty else { return nil }
        if norm == "1" || norm.contains("birinci") || norm.contains("ilk dosya") || norm == "ilki" {
            return lastSuggestedFiles.first
        }
        if (norm == "2" || norm.contains("ikinci")) && lastSuggestedFiles.count >= 2 {
            return lastSuggestedFiles[1]
        }
        if (norm == "3" || norm.contains("ucuncu")) && lastSuggestedFiles.count >= 3 {
            return lastSuggestedFiles[2]
        }
        if (norm == "4" || norm.contains("dorduncu")) && lastSuggestedFiles.count >= 4 {
            return lastSuggestedFiles[3]
        }
        return nil
    }

    static func normalizeText(_ text: String) -> String {
        let map: [Character: String] = [
            "ı": "i", "İ": "i", "I": "i",
            "ş": "s", "Ş": "s",
            "ğ": "g", "Ğ": "g",
            "ü": "u", "Ü": "u",
            "ö": "o", "Ö": "o",
            "ç": "c", "Ç": "c"
        ]
        var converted = ""
        for ch in text {
            if let rep = map[ch] {
                converted.append(rep)
            } else {
                converted.append(ch.lowercased())
            }
        }
        let cleaned = converted.replacingOccurrences(
            of: "[^a-z0-9\\s]",
            with: " ",
            options: .regularExpression
        )
        return cleaned
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripStopWords(_ normalized: String) -> String {
        let stopWords: Set<String> = [
            "drive", "drivedan", "drivedaki", "google", "dosya", "dosyasi", "dosyasini",
            "dosyayi", "dosyalar", "belge", "belgesi", "belgesini", "dokuman", "dokumani",
            "tablo", "tabloyu", "pdf", "txt", "klasor", "isimli", "adli", "adindaki",
            "olan", "bul", "ac", "oku", "ozetle", "gonder", "bana", "su", "bu"
        ]
        let tokens = normalized.split(separator: " ").map(String.init).filter { !stopWords.contains($0) }
        return tokens.isEmpty ? normalized : tokens.joined(separator: " ")
    }

    static func similarityScore(query: String, fileName: String) -> Double {
        let baseFileName: String
        if let dotIdx = fileName.lastIndex(of: "."), dotIdx != fileName.startIndex {
            baseFileName = String(fileName[..<dotIdx])
        } else {
            baseFileName = fileName
        }

        let qRawNorm = normalizeText(query)
        let qNorm = stripStopWords(qRawNorm)
        let fNorm = normalizeText(baseFileName)

        guard !qNorm.isEmpty, !fNorm.isEmpty else { return 0.0 }

        if qNorm == fNorm || qRawNorm == fNorm {
            return 1.0
        }

        if fNorm.contains(qNorm) || qNorm.contains(fNorm) {
            let ratio = Double(min(qNorm.count, fNorm.count)) / Double(max(1, max(qNorm.count, fNorm.count)))
            return 0.84 + (0.14 * ratio)
        }

        let qTokens = qNorm.split(separator: " ").map(String.init)
        let fTokens = fNorm.split(separator: " ").map(String.init)

        var tokenScoreSum = 0.0
        for qt in qTokens {
            var bestForToken = 0.0
            for ft in fTokens {
                if qt == ft {
                    bestForToken = max(bestForToken, 1.0)
                } else if qt.count >= 3 && ft.count >= 3 && (ft.hasPrefix(qt) || qt.hasPrefix(ft)) {
                    bestForToken = max(bestForToken, 0.90)
                } else {
                    let dice = diceBigramSimilarity(qt, ft)
                    bestForToken = max(bestForToken, dice)
                }
            }
            tokenScoreSum += bestForToken
        }

        let avgTokenScore = qTokens.isEmpty ? 0.0 : (tokenScoreSum / Double(qTokens.count))
        let wholeDice = diceBigramSimilarity(qNorm, fNorm)

        return max(avgTokenScore * 0.88, wholeDice * 0.85, (avgTokenScore * 0.65 + wholeDice * 0.35))
    }

    private static func diceBigramSimilarity(_ a: String, _ b: String) -> Double {
        let s1 = a.replacingOccurrences(of: " ", with: "")
        let s2 = b.replacingOccurrences(of: " ", with: "")
        if s1 == s2 { return 1.0 }
        if s1.count < 2 || s2.count < 2 { return 0.0 }

        func bigrams(_ s: String) -> [String] {
            let chars = Array(s)
            return (0..<(chars.count - 1)).map { String([chars[$0], chars[$0 + 1]]) }
        }

        let b1 = bigrams(s1)
        var b2 = bigrams(s2)
        var intersection = 0
        for bg in b1 {
            if let idx = b2.firstIndex(of: bg) {
                intersection += 1
                b2.remove(at: idx)
            }
        }
        return (2.0 * Double(intersection)) / Double(b1.count + bigrams(s2).count)
    }

    /// Verilen referans bir dosya ID'si mi yoksa dosya adı mı kontrol eder; dosya adıysa Drive'da arayıp gerçek ID'sini bulur.
    func resolveFileId(fileIdOrName: String) async throws -> String {
        let trimmed = fileIdOrName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "Drive", code: 400, userInfo: [NSLocalizedDescriptionKey: "Dosya adı veya ID belirtilmedi."])
        }

        // Eğer boşluk içermiyorsa ve 18+ karakterli tipik bir Drive ID gibiyse önce doğrudan dene
        let looksLikeId = !trimmed.contains(" ") && trimmed.count >= 18 && !trimmed.contains(".")
        if looksLikeId {
            return trimmed
        }

        let (exactMatch, similarFiles, _) = try await findBestAndSimilarFiles(query: trimmed, limit: 5)
        if let exact = exactMatch {
            return exact.id
        }
        if similarFiles.count == 1, let only = similarFiles.first, Self.similarityScore(query: trimmed, fileName: only.name) >= 0.55 {
            return only.id
        }

        return trimmed
    }

    // MARK: - Read & Extract File Content (Docs, Sheets, Slides, PDF, TXT, CSV, JSON, Markdown)

    func readTextFile(fileId: String, fileName: String? = nil) async throws -> String {
        let cleanId = fileId.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = (fileName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let targetCandidate = !cleanId.isEmpty ? cleanId : cleanName

        let looksLikeId = !cleanId.isEmpty && !cleanId.contains(" ") && cleanId.count >= 18 && !cleanId.contains(".")
        var resolvedId = targetCandidate

        if !looksLikeId {
            let (exactMatch, similarFiles, recentFiles) = try await findBestAndSimilarFiles(query: targetCandidate, limit: 4)
            if let exact = exactMatch {
                resolvedId = exact.id
            } else if similarFiles.count == 1, let only = similarFiles.first, Self.similarityScore(query: targetCandidate, fileName: only.name) >= 0.62 {
                resolvedId = only.id
            } else if !similarFiles.isEmpty {
                lastSuggestedFiles = similarFiles
                let optionsList = similarFiles.enumerated().map { idx, item in
                    "\(idx + 1)) \(item.name) (ID: \(item.id))"
                }.joined(separator: "\n")
                return """
                [BENZER DRIVE DOSYALARI BULUNDU - KULLANICIYA SOR]
                '\(targetCandidate)' adıyla birebir tek bir dosya yerine şu benzer dosyalar bulundu:
                \(optionsList)
                Lütfen kullanıcıya bu dosya isimlerini söyleyip "Şu dosya mı yoksa bu dosya mı, hangisini okumamı istersin?" diye sor. Kullanıcı seçtiğinde ilgili dosyanın ID'si ile `readDriveFile` aracını çağır.
                """
            } else {
                if !recentFiles.isEmpty {
                    let topRecent = Array(recentFiles.prefix(3))
                    lastSuggestedFiles = topRecent
                }
                throw NSError(domain: "Drive", code: 404, userInfo: [NSLocalizedDescriptionKey: "Drive'da '\(targetCandidate)' ismine benzer bir dosya bulunamadı."])
            }
        }

        let data: Data
        let mimeType: String
        let actualName: String

        do {
            (data, mimeType, actualName) = try await downloadFileRaw(fileId: resolvedId, asText: true)
        } catch {
            // Eğer fileId olarak geçilen değer aslında bir dosya ismi idiyse arama yaparak tekrar dene
            let searchKey = (fileName?.isEmpty == false) ? fileName! : fileId
            let matches = try await fetchDriveFiles(query: searchKey, pageSize: 3)
            guard let first = matches.first else {
                throw error
            }
            (data, mimeType, actualName) = try await downloadFileRaw(fileId: first.id, asText: true)
        }

        // 1. PDF ise PDFKit ile metnini çıkar
        if mimeType.lowercased().contains("pdf") {
            if let pdfDoc = PDFDocument(data: data), let extracted = pdfDoc.string, !extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let clipped = String(extracted.prefix(4000))
                return "Dosya Adı: \(actualName) (PDF)\nİçerik:\n\(clipped)"
            }
            return "Dosya Adı: \(actualName) (PDF) — Taranmış görüntü formatında olduğu için metin katmanı okunamadı."
        }

        // 2. UTF-8 / Türkçe metin olarak çözümle
        if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedText.isEmpty {
                let clipped = String(trimmedText.prefix(4000))
                return "Dosya Adı: \(actualName)\nİçerik:\n\(clipped)"
            }
        }

        return "Dosya Adı: \(actualName) (\(mimeType)) — Bu dosya ikili (binary/görsel) formatta olduğu için düz metin olarak okunamadı, ancak e-posta ile gönderilebilir."
    }

    // MARK: - Raw Download / Export File

    func downloadFileRaw(fileId: String, asText: Bool = false) async throws -> (Data, String, String) {
        let token = try await getValidAccessToken()
        let resolvedId = try await resolveFileId(fileIdOrName: fileId)

        let metaUrl = URL(string: "https://www.googleapis.com/drive/v3/files/\(resolvedId)?fields=id,mimeType,name")!
        var metaReq = URLRequest(url: metaUrl)
        metaReq.timeoutInterval = 15.0
        metaReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (metaData, metaResp) = try await URLSession.shared.data(for: metaReq)
        guard let httpMetaResp = metaResp as? HTTPURLResponse, httpMetaResp.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
              let mimeType = json["mimeType"] as? String,
              let name = json["name"] as? String else {
            throw NSError(domain: "Drive", code: 404, userInfo: [NSLocalizedDescriptionKey: "Drive'da '\(fileId)' dosyası bulunamadı."])
        }

        let url: URL
        let finalMimeType: String
        let finalName: String

        if mimeType == "application/vnd.google-apps.spreadsheet" {
            let expMime = asText ? "text/csv" : "application/pdf"
            var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(resolvedId)/export")!
            comps.queryItems = [URLQueryItem(name: "mimeType", value: expMime)]
            url = comps.url!
            finalMimeType = expMime
            finalName = asText ? "\(name).csv" : "\(name).pdf"
        } else if mimeType == "application/vnd.google-apps.document" || mimeType == "application/vnd.google-apps.presentation" {
            let expMime = asText ? "text/plain" : "application/pdf"
            var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(resolvedId)/export")!
            comps.queryItems = [URLQueryItem(name: "mimeType", value: expMime)]
            url = comps.url!
            finalMimeType = expMime
            finalName = asText ? "\(name).txt" : "\(name).pdf"
        } else {
            url = URL(string: "https://www.googleapis.com/drive/v3/files/\(resolvedId)?alt=media")!
            finalMimeType = mimeType
            finalName = name
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 25.0
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "Drive", code: 500, userInfo: [NSLocalizedDescriptionKey: "'\(name)' dosyasının içeriği indirilemedi."])
        }

        return (data, finalMimeType, finalName)
    }

    private static func humanReadableMimeType(_ mime: String) -> String {
        switch mime {
        case "application/vnd.google-apps.document": return "Google Doküman"
        case "application/vnd.google-apps.spreadsheet": return "Google E-Tablo"
        case "application/vnd.google-apps.presentation": return "Google Sunu"
        case "application/vnd.google-apps.folder": return "Klasör"
        case "application/pdf": return "PDF Belgesi"
        default:
            if mime.hasPrefix("image/") { return "Fotoğraf (\(mime))" }
            if mime.hasPrefix("text/") { return "Metin Dosyası" }
            return mime
        }
    }
}

// MARK: - Google Photos Service (Google Photos Library API + Drive Image Sync)

final class GooglePhotosService {
    static let shared = GooglePhotosService()
    private init() {}

    struct PhotoItem {
        let id: String
        let filename: String
        let baseUrl: String?
        let creationTime: String
        let isFromDrive: Bool
    }

    private func getValidAccessToken() async throws -> String {
        guard let user = await GoogleAuthService.shared.currentUser else {
            throw NSError(
                domain: "GooglePhotos",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "Lütfen önce Entegrasyonlar menüsünden Google hesabınızı bağlayın."]
            )
        }
        return try await withCheckedThrowingContinuation { continuation in
            user.refreshTokensIfNeeded { refreshedUser, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let refreshedUser = refreshedUser {
                    continuation.resume(returning: refreshedUser.accessToken.tokenString)
                } else {
                    continuation.resume(throwing: NSError(domain: "GooglePhotos", code: 500, userInfo: [NSLocalizedDescriptionKey: "Token yenilenemedi."]))
                }
            }
        }
    }

    /// Kameradan çekilen veya verilen fotoğrafı Google Photos'a yükler (ve yedek olarak Google Drive'a da kaydeder)
    func uploadPhoto(data: Data, fileName: String, description: String = "Gismo Robot ile çekildi") async throws -> String {
        let token = try await getValidAccessToken()
        let cleanName = fileName.lowercased().hasSuffix(".jpg") || fileName.lowercased().hasSuffix(".jpeg")
            ? fileName
            : "\(fileName).jpg"

        var uploadedToPhotosAPI = false

        // 1. Google Photos Library API Upload
        if let uploadURL = URL(string: "https://photoslibrary.googleapis.com/v1/uploads") {
            var uploadReq = URLRequest(url: uploadURL)
            uploadReq.httpMethod = "POST"
            uploadReq.timeoutInterval = 25.0
            uploadReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            uploadReq.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            uploadReq.setValue("image/jpeg", forHTTPHeaderField: "X-Goog-Upload-Content-Type")
            uploadReq.setValue("raw", forHTTPHeaderField: "X-Goog-Upload-Protocol")
            uploadReq.httpBody = data

            if let (tokenData, uploadResp) = try? await URLSession.shared.data(for: uploadReq),
               let httpUpload = uploadResp as? HTTPURLResponse,
               (200...299).contains(httpUpload.statusCode),
               let uploadToken = String(data: tokenData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !uploadToken.isEmpty {

                let createURL = URL(string: "https://photoslibrary.googleapis.com/v1/mediaItems:batchCreate")!
                var createReq = URLRequest(url: createURL)
                createReq.httpMethod = "POST"
                createReq.timeoutInterval = 20.0
                createReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                createReq.setValue("application/json", forHTTPHeaderField: "Content-Type")

                let payload: [String: Any] = [
                    "newMediaItems": [
                        [
                            "description": description,
                            "simpleMediaItem": [
                                "fileName": cleanName,
                                "uploadToken": uploadToken
                            ]
                        ]
                    ]
                ]
                createReq.httpBody = try? JSONSerialization.data(withJSONObject: payload)

                if let (_, createResp) = try? await URLSession.shared.data(for: createReq),
                   let httpCreate = createResp as? HTTPURLResponse,
                   (200...299).contains(httpCreate.statusCode) {
                    uploadedToPhotosAPI = true
                }
            }
        }

        // 2. Aynı zamanda Google Drive'a da kaydet (hem Drive hem Photos üzerinden erişilebilsin)
        let driveId = try? await GoogleDriveService.shared.uploadFile(name: cleanName, data: data, mimeType: "image/jpeg")

        if uploadedToPhotosAPI && driveId != nil {
            return "Fotoğraf hem Google Fotoğraflar'a hem de Google Drive'a ('\(cleanName)') başarıyla yüklendi."
        } else if uploadedToPhotosAPI {
            return "Fotoğraf Google Fotoğraflar albümüne ('\(cleanName)') başarıyla yüklendi."
        } else if let driveId {
            return "Fotoğraf Google bulut hesabına ('\(cleanName)', ID: \(driveId)) başarıyla kaydedildi."
        } else {
            throw NSError(domain: "GooglePhotos", code: 500, userInfo: [NSLocalizedDescriptionKey: "Fotoğraf Google hesabına yüklenemedi."])
        }
    }

    /// Google Photos ve Google Drive'daki fotoğrafları listeler / arar
    func listOrSearchPhotos(query: String = "", count: Int = 5) async throws -> String {
        let token = try await getValidAccessToken()
        var items: [PhotoItem] = []

        // 1. Google Photos Library API'den son fotoğrafları getir
        if let url = URL(string: "https://photoslibrary.googleapis.com/v1/mediaItems?pageSize=\(max(1, min(20, count)))") {
            var req = URLRequest(url: url)
            req.timeoutInterval = 15.0
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            if let (data, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse, http.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let mediaItems = json["mediaItems"] as? [[String: Any]] {
                for m in mediaItems {
                    let id = m["id"] as? String ?? ""
                    let filename = m["filename"] as? String ?? "Fotoğraf"
                    let baseUrl = m["baseUrl"] as? String
                    let meta = m["mediaMetadata"] as? [String: Any]
                    let creationTime = meta?["creationTime"] as? String ?? ""
                    if query.isEmpty || filename.localizedCaseInsensitiveContains(query) {
                        items.append(PhotoItem(id: id, filename: filename, baseUrl: baseUrl, creationTime: creationTime, isFromDrive: false))
                    }
                }
            }
        }

        // 2. Google Drive'daki görüntü dosyalarını da dahil et
        if let driveImages = try? await GoogleDriveService.shared.fetchDriveFiles(query: query, pageSize: count, onlyImages: true) {
            for img in driveImages {
                items.append(PhotoItem(id: img.id, filename: img.name, baseUrl: nil, creationTime: img.modifiedTime, isFromDrive: true))
            }
        }

        if items.isEmpty {
            return query.isEmpty
                ? "Google Fotoğraflar ve Drive hesabında hiç fotoğraf bulunamadı."
                : "'\(query)' aramasına uygun fotoğraf bulunamadı."
        }

        var result = "Bulunan Fotoğraflar (\(items.count) adet):\n"
        for (idx, item) in items.prefix(count).enumerated() {
            let source = item.isFromDrive ? "Drive Fotoğrafı" : "Google Photos"
            result += "\(idx + 1). \(item.filename) | ID: \(item.id) | Kaynak: \(source)\n"
        }
        return result
    }

    /// Google Photos veya Drive'daki bir fotoğrafı indirir (e-posta göndermek veya galeriye kaydetmek için)
    func downloadPhoto(photoIdOrName: String) async throws -> (Data, String) {
        let token = try await getValidAccessToken()
        let trimmed = photoIdOrName.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Önce Google Photos mediaItem olarak dene
        if !trimmed.contains(" "),
           let metaURL = URL(string: "https://photoslibrary.googleapis.com/v1/mediaItems/\(trimmed)") {
            var req = URLRequest(url: metaURL)
            req.timeoutInterval = 15.0
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            if let (data, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse, http.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let baseUrl = json["baseUrl"] as? String,
               let downloadURL = URL(string: "\(baseUrl)=d") {
                let filename = json["filename"] as? String ?? "google_photo.jpg"
                if let (imgData, imgResp) = try? await URLSession.shared.data(from: downloadURL),
                   let httpImg = imgResp as? HTTPURLResponse, httpImg.statusCode == 200 {
                    return (imgData, filename)
                }
            }
        }

        // 2. Drive üzerinden fotoğraf/görsel olarak indir
        let resolvedId: String
        if trimmed.isEmpty || trimmed.lowercased() == "son" || trimmed.lowercased() == "en son" {
            let recent = try await GoogleDriveService.shared.fetchDriveFiles(query: "", pageSize: 1, onlyImages: true)
            guard let first = recent.first else {
                throw NSError(domain: "GooglePhotos", code: 404, userInfo: [NSLocalizedDescriptionKey: "İndirilecek fotoğraf bulunamadı."])
            }
            resolvedId = first.id
        } else {
            resolvedId = try await GoogleDriveService.shared.resolveFileId(fileIdOrName: trimmed)
        }

        let (data, _, name) = try await GoogleDriveService.shared.downloadFileRaw(fileId: resolvedId, asText: false)
        return (data, name)
    }
}

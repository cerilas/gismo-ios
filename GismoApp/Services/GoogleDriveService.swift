import Foundation
import GoogleSignIn

final class GoogleDriveService {
    static let shared = GoogleDriveService()
    private init() {}
    
    private func refreshUserIfNeeded(_ user: GIDGoogleUser) async throws -> GIDGoogleUser {
        return try await withCheckedThrowingContinuation { continuation in
            user.refreshTokensIfNeeded { refreshedUser, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let refreshedUser = refreshedUser {
                    continuation.resume(returning: refreshedUser)
                } else {
                    continuation.resume(throwing: NSError(domain: "Drive", code: 500, userInfo: [NSLocalizedDescriptionKey: "Token yenilenemedi."]))
                }
            }
        }
    }
    
    // Upload a file using multipart/related
    func uploadFile(name: String, data: Data, mimeType: String) async throws -> String {
        guard let user = await GoogleAuthService.shared.currentUser else {
            throw NSError(domain: "Drive", code: 401, userInfo: [NSLocalizedDescriptionKey: "Lütfen önce Google hesabınızı bağlayın."])
        }
        
        let refreshedUser = try await refreshUserIfNeeded(user)
        let token = refreshedUser.accessToken.tokenString
        
        let url = URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        let boundary = UUID().uuidString
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        // Metadata part
        let metadata = ["name": name]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata)
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metadataData)
        body.append("\r\n".data(using: .utf8)!)
        
        // File data part
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
        
        // End boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        
        let (responseData, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errString = String(data: responseData, encoding: .utf8) ?? "Bilinmeyen API Hatası"
            print("[Drive] Upload Error: \(errString)")
            throw NSError(domain: "Drive", code: 500, userInfo: [NSLocalizedDescriptionKey: "Drive'a dosya yüklenemedi."])
        }
        
        if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
           let id = json["id"] as? String {
            print("[Drive] Dosya yüklendi ID: \(id)")
            return id
        }
        
        return "Bilinmeyen ID"
    }
    
    // Search files
    func searchFiles(query: String) async throws -> String {
        guard let user = await GoogleAuthService.shared.currentUser else {
            throw NSError(domain: "Drive", code: 401, userInfo: [NSLocalizedDescriptionKey: "Lütfen önce Google hesabınızı bağlayın."])
        }
        
        let refreshedUser = try await refreshUserIfNeeded(user)
        let token = refreshedUser.accessToken.tokenString
        
        var urlComps = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        urlComps.queryItems = [
            URLQueryItem(name: "q", value: "name contains '\(query)'"),
            URLQueryItem(name: "fields", value: "files(id, name, mimeType)"),
            URLQueryItem(name: "pageSize", value: "5")
        ]
        
        var request = URLRequest(url: urlComps.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "Drive", code: 500, userInfo: [NSLocalizedDescriptionKey: "Drive araması başarısız."])
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = json["files"] as? [[String: Any]] else {
            return "Hiç dosya bulunamadı."
        }
        
        if files.isEmpty { return "Aramana uygun dosya bulamadım." }
        
        var resultText = "Drive Arama Sonuçları:\n"
        for (index, file) in files.enumerated() {
            let name = file["name"] as? String ?? "İsimsiz"
            let id = file["id"] as? String ?? ""
            let mime = file["mimeType"] as? String ?? ""
            resultText += "\(index + 1). İsim: \(name) (ID: \(id), Tür: \(mime))\n"
        }
        
        return resultText
    }
    
    // Download text file content
    func readTextFile(fileId: String) async throws -> String {
        let (data, _, _) = try await downloadFileRaw(fileId: fileId, asText: true)
        return String(data: data, encoding: .utf8) ?? "Dosya içeriği metin formatında değil veya okunamadı."
    }
    
    // Raw Download File
    func downloadFileRaw(fileId: String, asText: Bool = false) async throws -> (Data, String, String) {
        guard let user = await GoogleAuthService.shared.currentUser else {
            throw NSError(domain: "Drive", code: 401, userInfo: [NSLocalizedDescriptionKey: "Lütfen önce Google hesabınızı bağlayın."])
        }
        
        let refreshedUser = try await refreshUserIfNeeded(user)
        let token = refreshedUser.accessToken.tokenString
        
        // Metadata to get name and mimeType
        let metaUrl = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileId)?fields=mimeType,name")!
        var metaReq = URLRequest(url: metaUrl)
        metaReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (metaData, metaResp) = try await URLSession.shared.data(for: metaReq)
        guard let httpMetaResp = metaResp as? HTTPURLResponse, httpMetaResp.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
              let mimeType = json["mimeType"] as? String,
              let name = json["name"] as? String else {
            throw NSError(domain: "Drive", code: 404, userInfo: [NSLocalizedDescriptionKey: "Dosya bulunamadı."])
        }
        
        // Export logic if it's a Workspace file
        let url: URL
        let finalMimeType: String
        let finalName: String
        
        if mimeType == "application/vnd.google-apps.spreadsheet" {
            let expMime = asText ? "text/csv" : "application/pdf"
            url = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileId)/export?mimeType=\(expMime)")!
            finalMimeType = expMime
            finalName = asText ? "\(name).csv" : "\(name).pdf"
        } else if mimeType == "application/vnd.google-apps.document" || mimeType == "application/vnd.google-apps.presentation" {
            let expMime = asText ? "text/plain" : "application/pdf"
            url = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileId)/export?mimeType=\(expMime)")!
            finalMimeType = expMime
            finalName = asText ? "\(name).txt" : "\(name).pdf"
        } else {
            url = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileId)?alt=media")!
            finalMimeType = mimeType
            finalName = name
        }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "Drive", code: 500, userInfo: [NSLocalizedDescriptionKey: "Dosya içeriği okunamadı."])
        }
        
        return (data, finalMimeType, finalName)
    }
}

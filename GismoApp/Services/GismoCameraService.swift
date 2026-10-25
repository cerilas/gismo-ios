import AVFoundation
import Photos
import SwiftUI

// MARK: - GismoCameraService

@MainActor
final class GismoCameraService: NSObject, ObservableObject {

    @Published var capturedImage: UIImage?
    @Published var isCapturing = false
    @Published var showPreview = false
    @Published var lensMode   = false   // Sol göz → lens animasyonu
    @Published var shutterFlash = false // Fotoğraf çekilme flaşı

    /// Son çekilen fotoğrafın JPEG verisi ("son çektiğin fotoyu yükle / gönder" komutları için)
    private static var lastCapturedPhotoData: Data?

    private static var lastPhotoCacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("gismo_last_captured_photo.jpg")
    }

    private let session     = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var continuation: CheckedContinuation<UIImage?, Never>?

    // MARK: - Public

    /// - saveToGallery: false ise (örn. yapay zekanın "ne görüyorsun" analizi) galeriye kaydedilmez
    @discardableResult
    func takePhoto(saveToGallery: Bool = true) async -> UIImage? {
        guard !isCapturing else { return nil }

        let camOK  = await requestCamera()
        let photoOK = saveToGallery ? await requestPhotoLibrary() : false
        guard camOK else {
            print("[Camera] Kamera izni yok")
            return nil
        }

        isCapturing = true
        defer { isCapturing = false }

        // 1. Sol göz lens'e dönüşsün
        withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) { lensMode = true }
        try? await Task.sleep(for: .milliseconds(600))

        // Session kur
        setupSession()

        // Session başlat (background thread)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                self.session.startRunning()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    cont.resume()
                }
            }
        }

        // Fotoğraf çek (cihazın mevcut landscape yönünü uygula)
        let currentOrientation = Self.currentVideoOrientation()
        let image = await withCheckedContinuation { cont in
            self.continuation = cont
            if let connection = self.photoOutput.connection(with: .video) {
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = currentOrientation
                }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = true
                }
            }
            let settings = AVCapturePhotoSettings()
            settings.flashMode = .off
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }

        // Session durdur
        DispatchQueue.global().async { self.session.stopRunning() }

        guard let image else {
            withAnimation { lensMode = false }
            return nil
        }

        // 2. Shutter flaşı
        withAnimation(.easeIn(duration: 0.05)) { shutterFlash = true }
        try? await Task.sleep(for: .milliseconds(120))
        withAnimation(.easeOut(duration: 0.25)) { shutterFlash = false }

        // 3. Göz normale dönsün
        try? await Task.sleep(for: .milliseconds(200))
        withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { lensMode = false }

        // Önizleme göster
        capturedImage = image
        showPreview   = true

        // Galeriye kaydet
        if !saveToGallery {
            // Yalnızca analiz amaçlı çekim — galeriye kaydetme
        } else {
            if let jpeg = image.jpegData(compressionQuality: 0.88) {
                Self.cacheLastCapturedPhoto(jpeg)
            }
            if photoOK {
                await Self.saveToPhotoLibrary(image)
            } else {
                // İzin durumu belirsizse fallback olarak dene
                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            }
        }

        // 3 sn sonra kapat
        Task {
            try? await Task.sleep(for: .seconds(3))
            await MainActor.run {
                showPreview   = false
                capturedImage = nil
            }
        }
        
        return image
    }

    // MARK: - Private

    private static func currentVideoOrientation() -> AVCaptureVideoOrientation {
        let interfaceOrientation = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.interfaceOrientation ?? .landscapeRight

        switch interfaceOrientation {
        case .landscapeLeft:
            return .landscapeLeft
        case .landscapeRight:
            return .landscapeRight
        case .portraitUpsideDown:
            return .portraitUpsideDown
        default:
            return .landscapeRight
        }
    }

    private func setupSession() {
        guard session.inputs.isEmpty else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo

        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }

        if let connection = photoOutput.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = Self.currentVideoOrientation()
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        }

        session.commitConfiguration()
    }

    static func cacheLastCapturedPhoto(_ data: Data) {
        lastCapturedPhotoData = data
        if let url = lastPhotoCacheURL {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func saveToPhotoLibrary(_ image: UIImage) async {
        if let jpeg = image.jpegData(compressionQuality: 0.88) {
            cacheLastCapturedPhoto(jpeg)
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }) { success, error in
                if success {
                    print("[Camera] Galeriye kaydedildi")
                } else {
                    print("[Camera] PHPhotoLibrary kayıt hatası (\(error?.localizedDescription ?? "")), fallback deneniyor...")
                    DispatchQueue.main.async {
                        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                    }
                }
                cont.resume()
            }
        }
    }

    /// Kullanıcının telefon galerisindeki (Film Rulosu) en son fotoğrafı veya Gismo ile çekilen son fotoğrafı getirir (yeni fotoğraf ÇEKMEZ).
    static func getLatestGalleryOrCapturedPhotoData() async -> Data? {
        // 1. Önce telefon galerisinden (PHAsset) en son fotoğrafı okumayı dene
        if let galleryData = await fetchLatestPhotoFromLibrary() {
            return galleryData
        }
        // 2. Galeriden okuma izni kısıtlıysa Gismo'nun son çekip kaydettiği fotoğrafı döndür
        if let memData = lastCapturedPhotoData {
            return memData
        }
        if let url = lastPhotoCacheURL, let diskData = try? Data(contentsOf: url), !diskData.isEmpty {
            lastCapturedPhotoData = diskData
            return diskData
        }
        return nil
    }

    private static func fetchLatestPhotoFromLibrary() async -> Data? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let authorized: Bool
        if status == .authorized || status == .limited {
            authorized = true
        } else if status == .notDetermined {
            let newStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            authorized = (newStatus == .authorized || newStatus == .limited)
        } else {
            authorized = false
        }

        guard authorized else { return nil }

        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.fetchLimit = 1

        let fetchResult = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        guard let latestAsset = fetchResult.firstObject else { return nil }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            let reqOptions = PHImageRequestOptions()
            reqOptions.isNetworkAccessAllowed = true
            reqOptions.deliveryMode = .highQualityFormat
            reqOptions.version = .current
            reqOptions.isSynchronous = false

            var didResume = false
            PHImageManager.default().requestImageDataAndOrientation(for: latestAsset, options: reqOptions) { data, _, _, _ in
                guard !didResume else { return }
                didResume = true
                if let data, let uiImage = UIImage(data: data), let jpeg = uiImage.jpegData(compressionQuality: 0.88) {
                    continuation.resume(returning: jpeg)
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
    }

    // MARK: - Permissions

    private func requestCamera() async -> Bool {
        await withCheckedContinuation { cont in
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:      cont.resume(returning: true)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { cont.resume(returning: $0) }
            default:               cont.resume(returning: false)
            }
        }
    }

    static func requestPhotoLibraryPermission() async -> Bool {
        await withCheckedContinuation { cont in
            let addStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            let rwStatus  = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if addStatus == .authorized || addStatus == .limited || rwStatus == .authorized || rwStatus == .limited {
                cont.resume(returning: true)
                return
            }
            if addStatus == .notDetermined {
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { s in
                    cont.resume(returning: s == .authorized || s == .limited)
                }
            } else {
                cont.resume(returning: false)
            }
        }
    }

    private func requestPhotoLibrary() async -> Bool {
        await Self.requestPhotoLibraryPermission()
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension GismoCameraService: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                  didFinishProcessingPhoto photo: AVCapturePhoto,
                                  error: Error?) {
        let image: UIImage?
        if let data = photo.fileDataRepresentation() {
            image = UIImage(data: data)
        } else {
            image = nil
        }
        Task { @MainActor in
            self.continuation?.resume(returning: image)
            self.continuation = nil
        }
    }
}

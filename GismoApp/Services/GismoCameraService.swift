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

    private let session     = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var continuation: CheckedContinuation<UIImage?, Never>?

    // MARK: - Public

    @discardableResult
    func takePhoto() async -> UIImage? {
        guard !isCapturing else { return nil }

        let camOK  = await requestCamera()
        let photoOK = await requestPhotoLibrary()
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

        // Fotoğraf çek
        let image = await withCheckedContinuation { cont in
            self.continuation = cont
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
        if photoOK {
            await saveToLibrary(image)
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

        // Ayna efektini kaldır (selfie doğal görünsün)
        photoOutput.connection(with: .video)?.isVideoMirrored = true

        session.commitConfiguration()
    }

    private func saveToLibrary(_ image: UIImage) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }) { success, error in
                if success { print("[Camera] Galeriye kaydedildi") }
                else { print("[Camera] Kayıt hatası: \(error?.localizedDescription ?? "")") }
                cont.resume()
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

    private func requestPhotoLibrary() async -> Bool {
        await withCheckedContinuation { cont in
            let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            switch status {
            case .authorized, .limited:  cont.resume(returning: true)
            case .notDetermined:
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { s in
                    cont.resume(returning: s == .authorized || s == .limited)
                }
            default:  cont.resume(returning: false)
            }
        }
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

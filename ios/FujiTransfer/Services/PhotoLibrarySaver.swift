import Foundation
import Photos

/// Speichert heruntergeladene Original-JPEGs verlustfrei (inkl. Fujifilm-EXIF)
/// direkt in der Apple Fotos-Mediathek.
enum PhotoLibrarySaver {
    enum SaveError: LocalizedError {
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Kein Zugriff auf die Fotos-Mediathek. Bitte in den iOS-Einstellungen fuer FujiTransfer erlauben."
            }
        }
    }

    static func ensureAuthorization() async throws {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if current == .authorized || current == .limited {
            return
        }
        let granted = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard granted == .authorized || granted == .limited else {
            throw SaveError.permissionDenied
        }
    }

    static func saveJPEG(at fileURL: URL) async throws {
        try await ensureAuthorization()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false
            request.addResource(with: .photo, fileURL: fileURL, options: options)
        }
    }
}

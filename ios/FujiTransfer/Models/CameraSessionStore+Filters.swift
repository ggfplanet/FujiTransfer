import Foundation
import Darwin
import FujiCore

/// Import-Status-Filter fuer die Galerie.
enum GalleryImportFilter: String, CaseIterable, Identifiable {
    case all = "Alle"
    case notImported = "Neu"
    case imported = "Importiert"

    var id: String { rawValue }
}

/// Kombiniert clientseitige Galerie-Filter (Datum, Import-Status) mit dem XApp-Sternfilter der Kamera.
struct GalleryFilterState: Equatable {
    var selectedDateKey: String? = nil
    var importFilter: GalleryImportFilter = .all
    var starFilter: FujiStarRatingFilter = .all
    var starFilterNotice: String? = nil

    var hasActiveFilter: Bool {
        selectedDateKey != nil || importFilter != .all || starFilter != .all
    }

    mutating func resetLocalFilters() {
        selectedDateKey = nil
        importFilter = .all
    }

    mutating func resetAll() {
        selectedDateKey = nil
        importFilter = .all
        starFilter = .all
        starFilterNotice = nil
    }
}

/// Ein einzelner auswählbarer Aufnahmetag fuer die Galerie-Filterleiste.
struct GalleryDateOption: Identifiable, Hashable {
    var id: String { key }
    let key: String       // "YYYYMMDD"
    let label: String     // "22.11.2026"
    let count: Int
}

@MainActor
extension CameraSessionStore {
    /// Alle in den bisher geladenen Fotos vorkommenden Aufnahmedaten (neueste zuerst).
    var availableDateOptions: [GalleryDateOption] {
        var counts: [String: (label: String, count: Int)] = [:]
        for photo in photos {
            guard let key = photo.captureDateKey, let label = photo.formattedCaptureDate else { continue }
            if let existing = counts[key] {
                counts[key] = (existing.label, existing.count + 1)
            } else {
                counts[key] = (label, 1)
            }
        }
        return counts
            .map { GalleryDateOption(key: $0.key, label: $0.value.label, count: $0.value.count) }
            .sorted { $0.key > $1.key }
    }

    /// Gefilterte Fotoliste fuer die Anzeige im Grid (Aufnahmedatum + Import-Status).
    var filteredPhotos: [FujiPhotoInfo] {
        photos.filter { photo in
            if let dateKey = galleryFilter.selectedDateKey, photo.captureDateKey != dateKey {
                return false
            }
            switch galleryFilter.importFilter {
            case .all:
                return true
            case .notImported:
                return !importedFilenames.contains(photo.filename)
            case .imported:
                return importedFilenames.contains(photo.filename)
            }
        }
    }

    /// Wendet den XApp-Sternfilter (PTP 0xD603) direkt auf der Kamera an und laedt die gefilterte Liste neu.
    func applyCameraStarFilter(_ filter: FujiStarRatingFilter) async {
        guard let client = wifiClient, !isApplyingFilter else { return }
        if galleryFilter.starFilter == filter && galleryFilter.starFilterNotice == nil {
            return
        }

        let previousFilter = galleryFilter.starFilter
        isApplyingFilter = true
        galleryFilter.starFilterNotice = nil
        errorMessage = nil
        pauseGalleryBackgroundWork()

        do {
            let newInfo = try await runOnPTPQueue {
                try client.applyCameraStarFilter(filter)
            }
            galleryFilter.starFilter = filter
            galleryFilter.selectedDateKey = nil
            sessionInfo = newInfo
            photos = []
            thumbnails = [:]
            previewImages = [:]
            selectedHandles = []
            appendLog("[Filter] Kamera-Sternfilter '\(filter.label)' aktiv (\(newInfo.totalObjectCount) Treffer)")
            isApplyingFilter = false
            await loadNextPhotoPage()
        } catch {
            galleryFilter.starFilter = previousFilter
            galleryFilter.starFilterNotice = "Kamera-Sternfilter wird von deiner X-T4 in diesem Modus nicht akzeptiert (\(error.localizedDescription)). Datums- und Import-Filter funktionieren weiterhin lokal."
            appendLog("[Filter ERR] \(error.localizedDescription)")
            isApplyingFilter = false
        }
    }

    /// Laedt alle verbleibenden Metadaten-Seiten der aktiven Karte fuer vollstaendige Datums-Filterung.
    func loadAllRemainingMetadata() async {
        guard wifiClient != nil, !isLoadingMorePhotos else { return }
        while hasMorePhotos && wifiClient != nil && transferState == nil {
            await loadNextPhotoPage()
            if errorMessage != nil { break }
        }
    }

    /// Setzt alle aktiven Galerie-Filter zurueck (inkl. Kamera-Sternfilter, falls aktiv).
    func resetGalleryFilters() async {
        galleryFilter.resetLocalFilters()
        if galleryFilter.starFilter != .all {
            await applyCameraStarFilter(.all)
        }
    }

    /// Liest die aktuelle IPv4-Adresse des iPhone-WLAN-Interfaces (`en0`) aus.
    func currentWiFiIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) == IFF_UP
            let isRunning = (flags & IFF_RUNNING) == IFF_RUNNING
            if isUp && isRunning,
               let addr = current.pointee.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_INET),
               String(cString: current.pointee.ifa_name) == "en0" {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let res = getnameinfo(
                    addr,
                    socklen_t(addr.pointee.sa_len),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if res == 0 {
                    return String(cString: hostname)
                }
            }
            ptr = current.pointee.ifa_next
        }
        return nil
    }
}

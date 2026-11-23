import Foundation
import Observation
import UIKit
import Darwin
import FujiCore

/// Aktueller Zustand der laufenden Foto-Uebertragung.
struct TransferProgressState: Equatable {
    var currentIndex: Int
    var totalCount: Int
    var currentFilename: String
    var bytesReceived: Int
    var totalBytes: Int
    var lastSpeedMBps: Double
    var completedCount: Int
    var failedFilenames: [String]
    var isFinished: Bool
    var wasCancelled: Bool

    var currentFileFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(bytesReceived) / Double(totalBytes))
    }
}

/// Zentraler Zustand fuer BLE-Wecken, WLAN-Session, Galerie und Foto-Download.
/// Alle PTP/IP-Aufrufe laufen strikt seriell ueber `ptpQueue`, damit sich
/// Thumbnails und Downloads niemals gegenseitig blockieren.
@MainActor
@Observable
final class CameraSessionStore {
    // Persistierte BLE-Einstellungen
    private enum StorageKeys {
        static let bleToken = "fuji.ble.savedTokenHex"
        static let cameraSSID = "fuji.ble.savedSSID"
        static let importedFilenames = "fuji.imported.filenames"
    }

    var savedTokenHex: String {
        didSet { UserDefaults.standard.set(savedTokenHex, forKey: StorageKeys.bleToken) }
    }
    var savedSSID: String {
        didSet { UserDefaults.standard.set(savedSSID, forKey: StorageKeys.cameraSSID) }
    }
    private(set) var importedFilenames: Set<String>

    // Verbindungs- & UI-Zustand
    var isBusyBLE: Bool = false
    var isConnectingWiFi: Bool = false
    var bleStatusMessage: String?
    var errorMessage: String?
    var sessionInfo: FujiSessionInfo?
    var photos: [FujiPhotoInfo] = []
    var thumbnails: [UInt32: UIImage] = [:]
    var previewImages: [UInt32: UIImage] = [:]
    var isLoadingPreviewHandle: UInt32?
    var selectedHandles: Set<UInt32> = []
    var isLoadingMorePhotos: Bool = false
    var isApplyingFilter: Bool = false
    var galleryFilter = GalleryFilterState()
    var transferState: TransferProgressState?
    var logs: [String] = []

    var isConnected: Bool { sessionInfo != nil }
    var hasMorePhotos: Bool {
        guard let info = sessionInfo else { return false }
        return photos.count < info.totalObjectCount
    }

    internal let ptpQueue = DispatchQueue(label: "fuji.ios.ptp.serial", qos: .userInitiated)
    internal var wifiClient: FujiWiFiClient?
    internal var thumbnailTask: Task<Void, Never>?
    private let pageSize = 36

    init() {
        self.savedTokenHex = UserDefaults.standard.string(forKey: StorageKeys.bleToken) ?? ""
        self.savedSSID = UserDefaults.standard.string(forKey: StorageKeys.cameraSSID) ?? "FUJIFILM-X-T4"
        let saved = UserDefaults.standard.stringArray(forKey: StorageKeys.importedFilenames) ?? []
        self.importedFilenames = Set(saved)
    }

    // MARK: - Bluetooth LE (Koppeln & WLAN wecken)

    func pairOverBLE(activeBLERemote: BLERemoteStore? = nil) async {
        guard !isBusyBLE else { return }
        isBusyBLE = true
        errorMessage = nil
        if activeBLERemote?.isConnected == true {
            bleStatusMessage = "Trenne laufende BLE-Steuerung..."
            await activeBLERemote?.disconnectAndWait()
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        bleStatusMessage = "Suche X-T4 im Kopplungsmodus..."
        appendLog("[BLE] Starte Erstkopplung (Kopplungsregistrierung)...")

        let ble = FujiBLEManager { [weak self] msg in
            Task { @MainActor in self?.appendLog("[BLE] \(msg)") }
        }

        do {
            let result = try await ble.connectAndPrepareWiFi(
                clientName: UIDevice.current.name,
                savedTokenHex: nil,
                triggerWiFi: false,
                scanSeconds: 12.0
            )
            if let token = result.pairingTokenHex, !token.isEmpty {
                savedTokenHex = token
            }
            if !result.ssid.isEmpty {
                savedSSID = result.ssid
            }
            bleStatusMessage = "Gekoppelt mit \(result.cameraName) (WLAN: \(savedSSID)). Verlasse das Menue in Liveview."
            appendLog("[BLE] Kopplung gespeichert (Token: \(savedTokenHex), SSID: \(savedSSID))")
        } catch {
            errorMessage = error.localizedDescription
            bleStatusMessage = nil
            appendLog("[BLE ERR] \(error.localizedDescription)")
        }
        isBusyBLE = false
    }

    func wakeWiFiOverBLE(activeBLERemote: BLERemoteStore? = nil) async {
        guard !isBusyBLE else { return }
        isBusyBLE = true
        errorMessage = nil

        // Falls BLE-Steuerung bereits verbunden ist, genau diese Verbindung zum WLAN-Wecken nutzen!
        if let activeBLERemote, activeBLERemote.isConnected {
            bleStatusMessage = "Starte Kamera-WLAN ueber aktive Bluetooth-Verbindung..."
            appendLog("[BLE] Uebergabe aus BLE-Steuerung: wecke Kamera-WLAN direkt...")
            do {
                if let ssid = try await activeBLERemote.wakeWiFiUsingActiveSession(), !ssid.isEmpty {
                    savedSSID = ssid
                }
                bleStatusMessage = "Kamera-WLAN '\(savedSSID)' gestartet und BLE freigegeben! Jetzt im iOS-WLAN verbinden und unten auf 'Mit Kamera verbinden' tippen."
                appendLog("[BLE] WLAN ueber bestehende BLE-Session gestartet (BLE getrennt).")
            } catch {
                errorMessage = error.localizedDescription
                bleStatusMessage = nil
                appendLog("[BLE ERR] \(error.localizedDescription)")
            }
            isBusyBLE = false
            return
        }

        bleStatusMessage = "Verbinde per Bluetooth und starte Kamera-WLAN..."
        appendLog("[BLE] Wecke Kamera-WLAN (Token: \(savedTokenHex.isEmpty ? "neu" : savedTokenHex))...")

        let ble = FujiBLEManager { [weak self] msg in
            Task { @MainActor in self?.appendLog("[BLE] \(msg)") }
        }

        do {
            let tokenToUse = savedTokenHex.isEmpty ? nil : savedTokenHex
            let result = try await ble.connectAndPrepareWiFi(
                clientName: UIDevice.current.name,
                savedTokenHex: tokenToUse,
                triggerWiFi: true,
                scanSeconds: 10.0
            )
            if let token = result.pairingTokenHex, !token.isEmpty {
                savedTokenHex = token
            }
            if !result.ssid.isEmpty {
                savedSSID = result.ssid
            }
            bleStatusMessage = "Kamera-WLAN '\(savedSSID)' gestartet! Jetzt kurz im iOS-WLAN verbinden und unten auf 'Mit Kamera verbinden' tippen."
            appendLog("[BLE] \(result.wifiReadyState)")
        } catch {
            errorMessage = error.localizedDescription
            bleStatusMessage = nil
            appendLog("[BLE ERR] \(error.localizedDescription)")
        }
        isBusyBLE = false
    }

    // MARK: - WLAN PTP/IP Verbindung

    func connectWiFi(activeBLERemote: BLERemoteStore? = nil) async {
        guard !isConnectingWiFi else { return }
        isConnectingWiFi = true
        errorMessage = nil

        if activeBLERemote?.isConnected == true {
            appendLog("[Wi-Fi] Trenne aktive BLE-Steuerung vor WLAN-Verbindung...")
            await activeBLERemote?.disconnectAndWait()
        }

        let en0IP = currentWiFiIPv4Address()
        appendLog("[Wi-Fi] Aktuelle en0-IP: \(en0IP ?? "keine")")
        if let ip = en0IP, !ip.hasPrefix("192.168.0.") {
            appendLog("[Wi-Fi WARN] en0 ist nicht im Kamera-Subnetz 192.168.0.x (aktuell \(ip))")
        }
        appendLog("[Wi-Fi] Verbinde zu 192.168.0.1:55740...")

        let clientName = UIDevice.current.name
        let logCallback: FujiWiFiClient.LogHandler = { [weak self] level, msg in
            Task { @MainActor in
                self?.appendLog("[\(level)] \(msg)")
            }
        }

        do {
            let (client, info) = try await runOnPTPQueue { () throws -> (FujiWiFiClient, FujiSessionInfo) in
                let modes: [FujiTransportMode] = [.xapp, .wirelessComm]
                var lastErr: Error?
                for mode in modes {
                    let c = FujiWiFiClient(verbose: true, onLog: logCallback)
                    #if !targetEnvironment(simulator)
                    if let ip = en0IP, ip.hasPrefix("192.168.0.") {
                        c.setNetworkInterface("en0")
                    }
                    #endif
                    do {
                        let session = try c.connect(host: "192.168.0.1", port: 55740, mode: mode, clientName: clientName)
                        return (c, session)
                    } catch {
                        c.disconnect()
                        lastErr = error
                    }
                }
                throw lastErr ?? FujiError.notConnected
            }

            self.wifiClient = client
            self.sessionInfo = info
            self.photos = []
            self.thumbnails = [:]
            self.previewImages = [:]
            self.selectedHandles = []
            self.galleryFilter.resetAll()
            self.bleStatusMessage = nil
            appendLog("[Wi-Fi] Verbunden mit \(info.cameraName) (\(info.totalObjectCount) Fotos, Modus \(info.effectiveMode.rawValue))")
            await loadNextPhotoPage()
        } catch {
            let ipHint: String
            if let ip = en0IP, !ip.hasPrefix("192.168.0.") {
                ipHint = "Dein iPhone ist aktuell noch im falschen WLAN (IP: \(ip) statt 192.168.0.x). Bitte mit '\(savedSSID)' verbinden."
            } else if en0IP == nil {
                ipHint = "Kein aktives WLAN erkannt. Bitte mit '\(savedSSID)' verbinden."
            } else {
                ipHint = "iPhone-IP ist \(en0IP!), aber Kamera (192.168.0.1:55740) lehnt ab oder iOS-Zugriff 'Lokales Netzwerk' fehlt. Details im Diagnose-Protokoll unten."
            }
            errorMessage = "\(error.localizedDescription)\n\n\(ipHint)"
            appendLog("[Wi-Fi ERR] \(error.localizedDescription)")
        }

        isConnectingWiFi = false
    }

    func disconnect() {
        Task { await disconnectAndWait() }
    }

    /// Trennt die WLAN-Session sauber und wartet auf CloseSession + Goodbye auf `ptpQueue`,
    /// damit die X-T4 direkt in den normalen Liveview zurueckkehrt (z. B. vor BLE-Wechsel).
    func disconnectAndWait() async {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        let clientToClose = wifiClient
        wifiClient = nil
        sessionInfo = nil
        photos = []
        thumbnails = [:]
        previewImages = [:]
        isLoadingPreviewHandle = nil
        selectedHandles = []
        galleryFilter.resetAll()
        transferState = nil

        if let clientToClose {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                ptpQueue.async {
                    clientToClose.disconnect()
                    cont.resume()
                }
            }
            appendLog("[Wi-Fi] Verbindung sauber getrennt.")
        }
    }

    func switchCard(to cardID: Int) async {
        guard let client = wifiClient, sessionInfo?.activeCardID != cardID else { return }
        thumbnailTask?.cancel()
        isLoadingMorePhotos = true
        errorMessage = nil

        do {
            let newInfo = try await runOnPTPQueue {
                try client.switchCard(cardID: cardID)
            }
            sessionInfo = newInfo
            photos = []
            thumbnails = [:]
            previewImages = [:]
            selectedHandles = []
            galleryFilter.resetAll()
            appendLog("[Wi-Fi] Gewechselt auf Slot \(cardID) (\(newInfo.totalObjectCount) Fotos)")
            isLoadingMorePhotos = false
            await loadNextPhotoPage()
        } catch {
            errorMessage = error.localizedDescription
            isLoadingMorePhotos = false
        }
    }

    // MARK: - Fotoliste & Thumbnails

    func loadNextPhotoPage() async {
        guard let client = wifiClient, !isLoadingMorePhotos, hasMorePhotos else { return }
        isLoadingMorePhotos = true
        let offset = photos.count
        let limit = pageSize

        do {
            let newItems = try await runOnPTPQueue {
                try client.listPhotos(offset: offset, limit: limit)
            }
            photos.append(contentsOf: newItems)
            startThumbnailLoading(for: newItems)
        } catch {
            errorMessage = "Fotoliste konnte nicht geladen werden: \(error.localizedDescription)"
            appendLog("[ERR] listPhotos: \(error.localizedDescription)")
        }
        isLoadingMorePhotos = false
    }

    private func startThumbnailLoading(for items: [FujiPhotoInfo]) {
        guard let client = wifiClient else { return }
        let handlesToLoad = items.map(\.handle).filter { thumbnails[$0] == nil }
        guard !handlesToLoad.isEmpty else { return }

        let previousTask = thumbnailTask
        thumbnailTask = Task {
            await previousTask?.value
            for handle in handlesToLoad {
                if Task.isCancelled || self.transferState != nil {
                    break
                }
                let data: Data? = try? await self.runOnPTPQueue {
                    try client.fetchThumbnail(handle: handle)
                }
                if let data, let image = UIImage(data: data) {
                    self.thumbnails[handle] = image
                }
            }
        }
    }

    // MARK: - Vollbild-Vorschau (schnelle Smartphone-Vorschau ~500 KB)

    func loadPreviewImage(for photo: FujiPhotoInfo) async {
        guard let client = wifiClient else { return }
        if previewImages[photo.handle] != nil { return }
        isLoadingPreviewHandle = photo.handle

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FujiTransferPreviews", isDirectory: true)

        do {
            let result = try await runOnPTPQueue {
                try client.downloadPhoto(
                    handle: photo.handle,
                    toDirectory: tempDir,
                    compressForSmartphone: true
                )
            }
            if let data = try? Data(contentsOf: result.outputURL),
               let image = UIImage(data: data) {
                // RAM-Cache kompakt halten (max. 12 hochaufloesende Vorschauen)
                if previewImages.count >= 12, let firstKey = previewImages.keys.first {
                    previewImages.removeValue(forKey: firstKey)
                }
                previewImages[photo.handle] = image
            }
            try? FileManager.default.removeItem(at: result.outputURL)
        } catch {
            appendLog("[Vorschau] \(photo.filename): \(error.localizedDescription)")
        }

        if isLoadingPreviewHandle == photo.handle {
            isLoadingPreviewHandle = nil
        }
    }

    /// Laedt ein einzelnes Foto direkt aus der Vollbildvorschau in Original-Aufloesung in Apple Fotos.
    func downloadSinglePhoto(_ photo: FujiPhotoInfo) async {
        selectedHandles.insert(photo.handle)
        let savedSelection = selectedHandles
        selectedHandles = [photo.handle]
        await downloadSelectedPhotos()
        var restored = savedSelection
        restored.remove(photo.handle)
        selectedHandles = restored
    }

    // MARK: - Auswahl & Original-JPEG-Transfer

    func toggleSelection(_ handle: UInt32) {
        if selectedHandles.contains(handle) {
            selectedHandles.remove(handle)
        } else {
            selectedHandles.insert(handle)
        }
    }

    func selectLatest(_ count: Int) {
        let handles = photos.prefix(count).map(\.handle)
        selectedHandles.formUnion(handles)
    }

    func clearSelection() {
        selectedHandles.removeAll()
    }

    func downloadSelectedPhotos() async {
        guard let client = wifiClient else { return }
        let queueItems = photos.filter { selectedHandles.contains($0.handle) }
        guard !queueItems.isEmpty else { return }

        // Thumbnail-Laden pausieren, damit der Transfer volle Bandbreite hat
        thumbnailTask?.cancel()
        thumbnailTask = nil

        do {
            try await PhotoLibrarySaver.ensureAuthorization()
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FujiTransferDownloads", isDirectory: true)

        transferState = TransferProgressState(
            currentIndex: 1,
            totalCount: queueItems.count,
            currentFilename: queueItems[0].filename,
            bytesReceived: 0,
            totalBytes: 0,
            lastSpeedMBps: 0,
            completedCount: 0,
            failedFilenames: [],
            isFinished: false,
            wasCancelled: false
        )

        var completed = 0
        var failed: [String] = []

        for (idx, photo) in queueItems.enumerated() {
            if transferState?.wasCancelled == true {
                break
            }
            transferState?.currentIndex = idx + 1
            transferState?.currentFilename = photo.filename
            transferState?.bytesReceived = 0
            transferState?.totalBytes = 0

            do {
                let result = try await runOnPTPQueue {
                    try client.downloadPhoto(
                        handle: photo.handle,
                        toDirectory: tempDir,
                        compressForSmartphone: false // Immer volle Original-Aufloesung (6240x4160)
                    ) { [weak self] received, total in
                        Task { @MainActor in
                            self?.transferState?.bytesReceived = received
                            self?.transferState?.totalBytes = total
                        }
                    }
                }

                try await PhotoLibrarySaver.saveJPEG(at: result.outputURL)
                try? FileManager.default.removeItem(at: result.outputURL)

                completed += 1
                markAsImported(result.filename)
                selectedHandles.remove(photo.handle)
                transferState?.completedCount = completed
                transferState?.lastSpeedMBps = result.megabytesPerSecond
                appendLog(String(format: "[OK] %@ (%.1f MB, %.2f MB/s) in Fotos gespeichert", result.filename, Double(result.bytesWritten) / 1_048_576.0, result.megabytesPerSecond))
            } catch {
                if transferState?.wasCancelled == true {
                    break
                }
                failed.append(photo.filename)
                transferState?.failedFilenames = failed
                appendLog("[ERR] \(photo.filename): \(error.localizedDescription)")
            }
        }

        transferState?.isFinished = true
    }

    func cancelTransfer() {
        transferState?.wasCancelled = true
        wifiClient?.cancelCurrentOperation()
        appendLog("[Wi-Fi] Download-Abbruch angefordert...")
    }

    func dismissTransferSummary() {
        transferState = nil
        // Fehlende Thumbnails der aktuellen Ansicht nachladen
        startThumbnailLoading(for: photos)
    }

    // MARK: - Live-View Koordination (geteilte WLAN-Session)

    /// Pausiert laufendes Thumbnail-Laden, bevor Live-View den PTP-Socket uebernimmt.
    func pauseGalleryBackgroundWork() {
        thumbnailTask?.cancel()
        thumbnailTask = nil
    }

    /// Aktualisiert die Galerie nach Beenden von Live-View (inkl. neu aufgenommener Fotos).
    func resumeGalleryAfterLiveView(updatedInfo: FujiSessionInfo) async {
        let previousTotal = sessionInfo?.totalObjectCount ?? 0
        sessionInfo = updatedInfo
        if updatedInfo.totalObjectCount != previousTotal {
            photos = []
            thumbnails = [:]
            previewImages = [:]
            selectedHandles = []
            await loadNextPhotoPage()
        } else {
            startThumbnailLoading(for: photos)
        }
    }

    /// Fuehrt eine PTP/IP-Operation sicher auf derselben seriellen Queue wie die Galerie aus.
    func performWithWiFiClient<T>(_ work: @escaping (FujiWiFiClient) throws -> T) async throws -> T {
        guard let client = wifiClient else { throw FujiError.notConnected }
        return try await runOnPTPQueue {
            try work(client)
        }
    }

    func logExternal(_ line: String) {
        appendLog(line)
    }

    // MARK: - Helpers

    private func markAsImported(_ filename: String) {
        importedFilenames.insert(filename)
        UserDefaults.standard.set(Array(importedFilenames), forKey: StorageKeys.importedFilenames)
    }

    internal func appendLog(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logs.append("[\(formatter.string(from: Date()))] \(line)")
        if logs.count > 120 {
            logs.removeFirst(logs.count - 120)
        }
    }

    internal func runOnPTPQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            ptpQueue.async {
                do {
                    cont.resume(returning: try work())
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}

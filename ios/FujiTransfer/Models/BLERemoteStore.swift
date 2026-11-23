import Foundation
import Observation
import CoreLocation
import UIKit
import FujiCore

/// Zustand fuer die dauerhafte Bluetooth-Fernsteuerung (Tab "Steuerung"):
/// - Fernausloeser (Einzelbild, Autofokus, Bulb mit Timer)
/// - Intervallometer / Zeitraffer
/// - GPS-Geotagging (automatisch auf X-T4-Anfrage & manuell)
/// - Objektiv- & Kamera-Informationen
@MainActor
@Observable
final class BLERemoteStore {
    var isConnecting: Bool = false
    var cameraStatus: FujiBLECameraStatus?
    var errorMessage: String?
    var statusBanner: String?
    var logs: [String] = []

    // Ausloeser & Bulb
    var isShutterBusy: Bool = false
    var isBulbActive: Bool = false
    var bulbElapsedSeconds: Int = 0
    var shotsFiredCount: Int = 0

    // Intervallometer
    var intervalSeconds: Int = 5
    var intervalTargetShots: Int = 10 // 0 = unendlich
    var isIntervalRunning: Bool = false
    var intervalShotsTaken: Int = 0
    var intervalCountdown: Int = 0

    // GPS-Geotagging
    var isAutoGeotagEnabled: Bool = false {
        didSet { updateLocationTracking() }
    }
    var lastSentLocationText: String?
    var lastSentTimeText: String?
    var geotagSendCount: Int = 0

    var isConnected: Bool { cameraStatus != nil }

    private var session: FujiBLESession?
    private let locationService = LocationService()
    private var bulbTimerTask: Task<Void, Never>?
    private var intervalTask: Task<Void, Never>?

    init() {
        locationService.onLocationUpdated = { [weak self] _ in
            _ = self
        }
    }

    // MARK: - BLE-Verbindung

    func connect(savedTokenHex: String) async {
        guard !isConnecting, !isConnected else { return }
        isConnecting = true
        errorMessage = nil
        statusBanner = "Verbinde per Bluetooth mit X-T4..."

        let ble = FujiBLESession { [weak self] msg in
            Task { @MainActor in self?.appendLog("[BLE] \(msg)") }
        }

        ble.onGeotagRequested = { [weak self] in
            Task { @MainActor in
                guard let self, self.isAutoGeotagEnabled else { return }
                await self.sendCurrentLocationToCamera(silent: true)
            }
        }
        ble.onTimeSynced = { [weak self] in
            Task { @MainActor in
                let f = DateFormatter()
                f.dateFormat = "HH:mm:ss"
                self?.lastSentTimeText = f.string(from: Date())
            }
        }
        ble.onDisconnected = { [weak self] reason in
            Task { @MainActor in
                self?.handleUnexpectedDisconnect(reason: reason)
            }
        }

        do {
            let status = try await ble.connect(
                savedTokenHex: savedTokenHex.isEmpty ? nil : savedTokenHex,
                clientName: UIDevice.current.name,
                scanSeconds: 10.0
            )
            self.session = ble
            self.cameraStatus = status
            self.statusBanner = nil
            appendLog("Verbunden: \(status.cameraName) (FW \(status.firmwareVersion ?? "?"))")
            if let lens = status.lensName {
                appendLog("Objektiv: \(lens) (FW \(status.lensFirmwareVersion ?? "?"))")
            }
            if isAutoGeotagEnabled {
                locationService.startUpdating()
            }
        } catch {
            ble.disconnect()
            errorMessage = error.localizedDescription
            statusBanner = nil
            appendLog("[ERR] \(error.localizedDescription)")
        }

        isConnecting = false
    }

    func disconnect() {
        Task { await disconnectAndWait() }
    }

    /// Trennt Bluetooth sauber und wartet auf die Bestaetigung von CoreBluetooth,
    /// damit die X-T4 sofort wieder frei fuer andere Tabs (z. B. WLAN-Wecken) ist.
    func disconnectAndWait() async {
        stopIntervalometer()
        bulbTimerTask?.cancel()
        bulbTimerTask = nil
        isBulbActive = false
        bulbElapsedSeconds = 0
        locationService.stopUpdating()

        let activeSession = session
        activeSession?.onDisconnected = nil
        session = nil
        cameraStatus = nil
        statusBanner = nil

        if let activeSession {
            await activeSession.disconnectAndWait(timeoutSeconds: 2.0)
            appendLog("Bluetooth-Verbindung sauber getrennt.")
        }
    }

    /// Nutzt eine bereits offene BLE-Fernsteuerungs-Verbindung, um das Kamera-WLAN
    /// direkt aufzuwecken (ohne konkurrierenden zweiten BLE-Scan) und trennt BLE danach sauber.
    func wakeWiFiUsingActiveSession() async throws -> String? {
        guard let activeSession = session, isConnected else { return nil }
        let ssid = cameraStatus?.wifiSSID
        appendLog("Nutze aktive BLE-Verbindung, um Kamera-WLAN zu starten...")
        try await activeSession.triggerWiFiHotspot()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await disconnectAndWait()
        return ssid
    }

    private func handleUnexpectedDisconnect(reason: String?) {
        stopIntervalometer()
        bulbTimerTask?.cancel()
        isBulbActive = false
        cameraStatus = nil
        session = nil
        errorMessage = reason ?? "Bluetooth-Verbindung zur X-T4 wurde getrennt."
        appendLog("[BLE] Getrennt: \(reason ?? "Kamera hat Verbindung beendet")")
    }

    // MARK: - Fernausloeser & Bulb

    func triggerSingleShot() async {
        guard let session, !isShutterBusy, !isBulbActive else { return }
        isShutterBusy = true
        errorMessage = nil
        do {
            try await session.triggerSingleShot()
            shotsFiredCount += 1
        } catch {
            errorMessage = error.localizedDescription
        }
        isShutterBusy = false
    }

    func focusOnly() async {
        guard let session, !isShutterBusy else { return }
        isShutterBusy = true
        errorMessage = nil
        do {
            try await session.focusPress()
            try await Task.sleep(nanoseconds: 600_000_000)
            try await session.shutterRelease()
        } catch {
            errorMessage = error.localizedDescription
        }
        isShutterBusy = false
    }

    func toggleBulb() async {
        guard let session else { return }
        errorMessage = nil
        if isBulbActive {
            bulbTimerTask?.cancel()
            bulbTimerTask = nil
            do {
                try await session.shutterRelease()
                shotsFiredCount += 1
            } catch {
                errorMessage = error.localizedDescription
            }
            isBulbActive = false
        } else {
            do {
                try await session.shutterPress()
                isBulbActive = true
                bulbElapsedSeconds = 0
                bulbTimerTask = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        if Task.isCancelled { break }
                        self.bulbElapsedSeconds += 1
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Intervallometer / Zeitraffer

    func startIntervalometer() {
        guard session != nil, !isIntervalRunning, !isBulbActive else { return }
        isIntervalRunning = true
        intervalShotsTaken = 0
        errorMessage = nil
        let interval = max(2, intervalSeconds)
        let target = intervalTargetShots

        appendLog("Intervallometer gestartet: alle \(interval)s (\(target == 0 ? "endlos" : "\(target) Fotos")).")
        intervalTask = Task {
            while !Task.isCancelled && self.isConnected {
                do {
                    try await self.session?.triggerSingleShot()
                    self.intervalShotsTaken += 1
                    self.shotsFiredCount += 1
                } catch {
                    self.errorMessage = "Intervall abgebrochen: \(error.localizedDescription)"
                    break
                }

                if target > 0 && self.intervalShotsTaken >= target {
                    self.statusBanner = "Intervallometer fertig (\(self.intervalShotsTaken) Fotos)."
                    break
                }

                for sec in stride(from: interval, through: 1, by: -1) {
                    if Task.isCancelled { break }
                    self.intervalCountdown = sec
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                self.intervalCountdown = 0
            }
            self.isIntervalRunning = false
            self.intervalCountdown = 0
        }
    }

    func stopIntervalometer() {
        intervalTask?.cancel()
        intervalTask = nil
        isIntervalRunning = false
        intervalCountdown = 0
    }

    // MARK: - GPS Geotagging

    private func updateLocationTracking() {
        if isAutoGeotagEnabled {
            locationService.startUpdating()
            if isConnected {
                Task { await sendCurrentLocationToCamera(silent: false) }
            }
        } else {
            locationService.stopUpdating()
        }
    }

    func sendCurrentLocationToCamera(silent: Bool = false) async {
        guard let session else { return }
        locationService.startUpdating()

        // Kurz warten, falls CoreLocation gerade den ersten Fix holt
        if locationService.latestLocation == nil {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
        }
        guard let loc = locationService.latestLocation else {
            if !silent {
                errorMessage = "Noch kein GPS-Signal vom iPhone erhalten. Bitte Standortfreigabe erlauben und kurz warten."
            }
            return
        }

        do {
            try await session.sendGeotag(
                latitude: loc.coordinate.latitude,
                longitude: loc.coordinate.longitude,
                altitudeMeters: loc.altitude,
                date: loc.timestamp
            )
            geotagSendCount += 1
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            lastSentLocationText = String(
                format: "%.5f, %.5f (%.0fm · ±%.0fm · %@)",
                loc.coordinate.latitude,
                loc.coordinate.longitude,
                loc.altitude,
                loc.horizontalAccuracy,
                f.string(from: Date())
            )
            if !silent {
                statusBanner = "GPS-Standort an X-T4 gesendet."
            }
        } catch {
            if !silent {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func appendLog(_ line: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        logs.append("[\(f.string(from: Date()))] \(line)")
        if logs.count > 100 {
            logs.removeFirst(logs.count - 100)
        }
    }
}

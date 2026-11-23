import Foundation
import Observation
import UIKit
import FujiCore

/// Zustand und Stream-Steuerung fuer den WLAN-Live-View-Tab (getrennt von BLE!).
/// Teilt sich die bestehende `FujiWiFiClient`-Session und serielle `ptpQueue`
/// mit `CameraSessionStore`, damit die Kamera ihr WLAN beim Tab-Wechsel nie abschaltet.
@MainActor
@Observable
final class WiFiLiveViewStore {
    var liveImage: UIImage?
    var status: FujiLiveViewStatus?
    var isoOptions: [FujiPropOption] = []
    var filmSimOptions: [FujiPropOption] = []

    var isStarting: Bool = false
    var isStreaming: Bool = false
    var isCapturing: Bool = false
    var isRecordingMovie: Bool = false
    var isUpdatingSetting: Bool = false
    var fps: Double = 0
    var errorMessage: String?
    var statusNote: String?

    private var streamTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?

    /// Startet den WLAN-Live-View-Modus auf der bereits verbundenen X-T4.
    func startLiveView(using store: CameraSessionStore) async {
        guard store.isConnected else { return }
        guard store.transferState == nil else {
            statusNote = "Foto-Transfer laeuft noch – Live-View startet danach."
            return
        }
        if let existing = startTask {
            await existing.value
            return
        }
        guard !isStreaming else { return }

        let task = Task { [weak self] in
            guard let self else { return }
            self.isStarting = true
            self.errorMessage = nil
            self.statusNote = "Wechsle X-T4 in den Live-View-Modus..."
            store.pauseGalleryBackgroundWork()

            do {
                let (initialStatus, isos, films) = try await store.performWithWiFiClient { client in
                    try client.enterLiveView()
                    let st = try client.fetchLiveViewStatus()
                    let isoOpts = client.supportedISOOptions()
                    let filmOpts = client.supportedFilmSimulationOptions()
                    return (st, isoOpts, filmOpts)
                }

                self.status = initialStatus
                self.isoOptions = isos
                self.filmSimOptions = films
                self.isStreaming = true
                self.statusNote = nil
                store.logExternal("[Live-View] Aktiv (ISO-Optionen: \(isos.count), Filmsimulationen: \(films.count))")
                self.startFrameLoop(using: store)
            } catch {
                self.errorMessage = "Live-View konnte nicht gestartet werden: \(error.localizedDescription)"
                self.statusNote = nil
                self.isStreaming = false
                store.logExternal("[Live-View ERR] \(error.localizedDescription)")
            }

            self.isStarting = false
            self.startTask = nil
        }
        startTask = task
        await task.value
    }

    /// Beendet Live-View sauber und wechselt die X-T4 zurueck in den Galerie-Modus.
    func stopLiveView(using store: CameraSessionStore) async {
        if let pendingStart = startTask {
            await pendingStart.value
        }

        let taskToCancel = streamTask
        streamTask = nil
        taskToCancel?.cancel()
        await taskToCancel?.value

        let wasActive = isStreaming || isRecordingMovie
        isStreaming = false
        isRecordingMovie = false
        fps = 0

        guard wasActive, store.isConnected else { return }

        do {
            let updatedInfo = try await store.performWithWiFiClient { client in
                try client.exitLiveView()
            }
            store.logExternal("[Live-View] Beendet, zurueck im Galerie-Modus (\(updatedInfo.totalObjectCount) Fotos)")
            await store.resumeGalleryAfterLiveView(updatedInfo: updatedInfo)
        } catch {
            store.logExternal("[Live-View WARN] Rueckkehr in Galerie: \(error.localizedDescription)")
        }
    }

    // MARK: - Ausloeser & Video

    func capturePhoto(using store: CameraSessionStore) async {
        guard isStreaming, !isCapturing else { return }
        isCapturing = true
        errorMessage = nil

        do {
            let updated = try await store.performWithWiFiClient { client in
                try client.capturePhoto()
                return try client.fetchLiveViewStatus()
            }
            status = updated
            statusNote = "Foto aufgenommen!"
            store.logExternal("[Live-View] Foto ueber WLAN ausgeloest.")
        } catch {
            errorMessage = "Ausloesen fehlgeschlagen: \(error.localizedDescription)"
            store.logExternal("[Live-View ERR] Capture: \(error.localizedDescription)")
        }

        isCapturing = false
    }

    func toggleMovieRecording(using store: CameraSessionStore) async {
        guard isStreaming, !isCapturing else { return }
        let targetStart = !isRecordingMovie
        isCapturing = true
        errorMessage = nil

        do {
            let updated = try await store.performWithWiFiClient { client in
                try client.setMovieRecording(targetStart)
                return try client.fetchLiveViewStatus()
            }
            isRecordingMovie = targetStart
            status = updated
            statusNote = targetStart ? "Videoaufnahme laeuft..." : "Videoaufnahme gestoppt."
            store.logExternal("[Live-View] Video \(targetStart ? "gestartet" : "gestoppt").")
        } catch {
            errorMessage = "Video-\(targetStart ? "Start" : "Stopp") fehlgeschlagen: \(error.localizedDescription)\nHinweis: Steht der X-T4 Still/Movie-Schalter auf MOVIE?"
            store.logExternal("[Live-View ERR] Movie: \(error.localizedDescription)")
        }

        isCapturing = false
    }

    // MARK: - Belichtungs- & Filmsimulations-Steuerung

    func step(_ kind: FujiStepControlKind, up: Bool, using store: CameraSessionStore) async {
        guard isStreaming, !isUpdatingSetting else { return }
        isUpdatingSetting = true
        errorMessage = nil

        do {
            let updated = try await store.performWithWiFiClient { client in
                try client.stepControl(kind, up: up)
                return try client.fetchLiveViewStatus()
            }
            status = updated
        } catch {
            errorMessage = "Wert konnte nicht verstellt werden: \(error.localizedDescription)\nHinweis: Pruefe ob das entsprechende Wahlrad an der X-T4 auf 'A' bzw. 'T'/'C' steht."
        }

        isUpdatingSetting = false
    }

    func selectISO(_ rawValue: UInt32, using store: CameraSessionStore) async {
        guard isStreaming, !isUpdatingSetting else { return }
        isUpdatingSetting = true
        errorMessage = nil

        do {
            let updated = try await store.performWithWiFiClient { client in
                try client.setISO(rawValue)
                return try client.fetchLiveViewStatus()
            }
            status = updated
            store.logExternal("[Live-View] ISO gesetzt: \(FujiLiveViewStatus.formatISO(rawValue))")
        } catch {
            errorMessage = "ISO konnte nicht geaendert werden: \(error.localizedDescription)"
        }

        isUpdatingSetting = false
    }

    func selectFilmSimulation(_ rawValue: UInt32, using store: CameraSessionStore) async {
        guard isStreaming, !isUpdatingSetting else { return }
        isUpdatingSetting = true
        errorMessage = nil

        do {
            let updated = try await store.performWithWiFiClient { client in
                try client.setFilmSimulation(UInt16(rawValue & 0xFFFF))
                return try client.fetchLiveViewStatus()
            }
            status = updated
            store.logExternal("[Live-View] Filmsimulation: \(FujiLiveViewStatus.formatFilmSimulation(rawValue))")
        } catch {
            errorMessage = "Filmsimulation konnte nicht geaendert werden: \(error.localizedDescription)"
        }

        isUpdatingSetting = false
    }

    // MARK: - MJPEG Frame Loop

    private func startFrameLoop(using store: CameraSessionStore) {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            var framesInWindow = 0
            var windowStart = Date()
            var lastStatusPoll = Date()
            var consecutiveErrors = 0

            while !Task.isCancelled && self.isStreaming && store.isConnected {
                do {
                    let frameData = try await store.performWithWiFiClient { client in
                        try client.readLiveViewFrame()
                    }
                    consecutiveErrors = 0

                    if let data = frameData, let image = UIImage(data: data) {
                        self.liveImage = image
                        framesInWindow += 1
                        let elapsed = Date().timeIntervalSince(windowStart)
                        if elapsed >= 1.0 {
                            self.fps = Double(framesInWindow) / elapsed
                            framesInWindow = 0
                            windowStart = Date()
                        }
                    } else {
                        // Kein neuer Frame im Socket-Puffer -> kurz warten statt CPU zu verbrennen
                        try? await Task.sleep(for: .milliseconds(25))
                    }

                    // Alle ~1.2 Sekunden Status-Events abfragen (fängt auch physische Rad-Drehungen ab)
                    if Date().timeIntervalSince(lastStatusPoll) >= 1.2 {
                        lastStatusPoll = Date()
                        if let st = try? await store.performWithWiFiClient({ try $0.fetchLiveViewStatus() }) {
                            self.status = st
                        }
                    }
                } catch {
                    if Task.isCancelled { break }
                    consecutiveErrors += 1
                    if consecutiveErrors >= 5 {
                        self.errorMessage = "Live-View-Stream unterbrochen: \(error.localizedDescription)"
                        self.isStreaming = false
                        store.logExternal("[Live-View ERR] Stream abgebrochen: \(error.localizedDescription)")
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }
        }
    }
}

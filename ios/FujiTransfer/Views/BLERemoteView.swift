import SwiftUI
import FujiCore

/// Tab 2: Bluetooth-Fernsteuerung fuer die Fujifilm X-T4 (ohne WLAN-Verbrauch):
/// Fernausloeser, Bulb, Intervallometer, GPS-Geotagging, Objektiv-Info & Kamera-Backup.
struct BLERemoteView: View {
    let remote: BLERemoteStore
    let store: CameraSessionStore
    let liveView: WiFiLiveViewStore
    @State private var showLogs = false
    @State private var isSwitchingFromWiFi = false

    private var savedTokenHex: String { store.savedTokenHex }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    connectionHeaderCard

                    if let banner = remote.statusBanner {
                        Text(banner)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.blue)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }

                    if let err = remote.errorMessage {
                        errorCard(err)
                    }

                    if let status = remote.cameraStatus {
                        cameraAndLensCard(status)
                        shutterCard(enabled: status.supportsShutter)
                        intervalometerCard(enabled: status.supportsShutter)
                        geotagCard(enabled: status.supportsGeotag)
                    }

                    DisclosureGroup("Bluetooth-Protokoll (\(remote.logs.count))", isExpanded: $showLogs) {
                        VStack(alignment: .leading, spacing: 4) {
                            if remote.logs.isEmpty {
                                Text("Noch keine Eintraege.").foregroundStyle(.secondary)
                            } else {
                                ForEach(Array(remote.logs.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.caption2.monospaced())
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding(.top, 8)
                    }
                    .padding()
                    .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                }
                .padding()
            }
            .navigationTitle("BLE-Steuerung")
        }
    }

    // MARK: - Cards

    private var connectionHeaderCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            ConnectionModeBadge(style: .bluetoothFast)

            HStack {
                Label(
                    remote.isConnected ? "Verbunden per Bluetooth" : "Nicht verbunden",
                    systemImage: remote.isConnected ? "bolt.horizontal.circle.fill" : "dot.radiowaves.left.and.right"
                )
                .font(.headline)
                .foregroundStyle(remote.isConnected ? .green : .primary)
                Spacer()
            }

            if store.isConnected && !remote.isConnected {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "wifi.exclamationmark")
                        .foregroundStyle(.orange)
                    Text("Aktive WLAN-Verbindung belegt die X-T4. Solange Kamera-WLAN laeuft, schaltet die Kamera Bluetooth stumm. Ein Tipp unten trennt WLAN sauber und wechselt zu Bluetooth.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            } else if savedTokenHex.isEmpty && !remote.isConnected {
                Text("Bitte kopple deine X-T4 zuerst einmalig im Tab 'Fotos'.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if !remote.isConnected {
                Text("Sofort startklar ohne WLAN-Wechsel: Kamera einfach im normalen Liveview einschalten. Fuer Sucherbild & Belichtung nutze den Tab 'Live-View' (WLAN).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if remote.isConnected {
                Button("Bluetooth trennen", role: .destructive) {
                    Task { await remote.disconnectAndWait() }
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            } else {
                Button {
                    Task {
                        if store.isConnected {
                            isSwitchingFromWiFi = true
                            remote.statusBanner = "Trenne Kamera-WLAN und warte kurz bis die X-T4 Bluetooth wieder freigibt..."
                            await liveView.stopLiveView(using: store)
                            await store.disconnectAndWait()
                            try? await Task.sleep(nanoseconds: 2_500_000_000)
                            isSwitchingFromWiFi = false
                        }
                        await remote.connect(savedTokenHex: savedTokenHex)
                    }
                } label: {
                    HStack {
                        if remote.isConnecting || isSwitchingFromWiFi {
                            ProgressView().tint(.white)
                        }
                        Text(
                            isSwitchingFromWiFi
                            ? "Wechsle von WLAN zu Bluetooth..."
                            : (remote.isConnecting
                               ? "Verbinde mit X-T4..."
                               : (store.isConnected
                                  ? "WLAN trennen & per Bluetooth verbinden"
                                  : "Per Bluetooth verbinden"))
                        )
                        .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(remote.isConnecting || isSwitchingFromWiFi || savedTokenHex.isEmpty)
            }
        }
        .padding()
        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
    }

    private func cameraAndLensCard(_ status: FujiBLECameraStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Kamera & Objektiv", systemImage: "camera.metering.center.weighted")
                .font(.headline)

            infoRow("Kamera", value: "\(status.cameraName) (FW \(status.firmwareVersion ?? "–"))")
            infoRow("Objektiv", value: status.lensName ?? "Nicht ausgelesen / manuell")
            if let lensFW = status.lensFirmwareVersion {
                infoRow("Objektiv-FW", value: lensFW)
            }
            if let timeSync = remote.lastSentTimeText {
                infoRow("Uhrzeit-Sync", value: "Automatisch um \(timeSync)")
            }
        }
        .padding()
        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
    }

    private func shutterCard(enabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Fernausloeser", systemImage: "camera.shutter.button")
                    .font(.headline)
                Spacer()
                if remote.shotsFiredCount > 0 {
                    Text("\(remote.shotsFiredCount) Ausloesungen")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                Task { await remote.triggerSingleShot() }
            } label: {
                HStack {
                    if remote.isShutterBusy {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "camera.circle.fill").font(.title2)
                    }
                    Text("Foto ausloesen")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!enabled || remote.isShutterBusy || remote.isBulbActive || remote.isIntervalRunning)

            HStack(spacing: 10) {
                Button {
                    Task { await remote.focusOnly() }
                } label: {
                    Label("Fokus (AF)", systemImage: "viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!enabled || remote.isShutterBusy || remote.isBulbActive)

                Button {
                    Task { await remote.toggleBulb() }
                } label: {
                    Label(
                        remote.isBulbActive ? "Bulb stoppen (\(remote.bulbElapsedSeconds)s)" : "Bulb / Halten",
                        systemImage: remote.isBulbActive ? "stop.circle.fill" : "timer"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(remote.isBulbActive ? .red : .orange)
                .disabled(!enabled || remote.isIntervalRunning)
            }
        }
        .padding()
        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
    }

    private func intervalometerCard(enabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Intervallometer / Zeitraffer", systemImage: "timelapse")
                .font(.headline)

            Stepper("Intervall: \(remote.intervalSeconds) Sekunden", value: Bindable(remote).intervalSeconds, in: 2...300)
                .disabled(remote.isIntervalRunning)

            Stepper(
                remote.intervalTargetShots == 0 ? "Anzahl: Endlos" : "Anzahl: \(remote.intervalTargetShots) Fotos",
                value: Bindable(remote).intervalTargetShots,
                in: 0...500,
                step: 5
            )
            .disabled(remote.isIntervalRunning)

            if remote.isIntervalRunning {
                HStack {
                    Text("Aufgenommen: \(remote.intervalShotsTaken)\(remote.intervalTargetShots > 0 ? " / \(remote.intervalTargetShots)" : "")")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if remote.intervalCountdown > 0 {
                        Text("Naechstes in \(remote.intervalCountdown)s")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Button("Intervall stoppen", role: .destructive) {
                    remote.stopIntervalometer()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .frame(maxWidth: .infinity)
            } else {
                Button("Intervall starten") {
                    remote.startIntervalometer()
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .disabled(!enabled || remote.isBulbActive)
            }
        }
        .padding()
        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
    }

    private func geotagCard(enabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("GPS-Geotagging", systemImage: "location.fill")
                .font(.headline)

            Toggle("Automatisch bei Kamera-Anfrage senden", isOn: Bindable(remote).isAutoGeotagEnabled)
                .disabled(!enabled)

            if let loc = remote.lastSentLocationText {
                Text("Zuletzt gesendet (\(remote.geotagSendCount)×): \(loc)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                Text("Schreibt iPhone-GPS (Koordinaten & Hoehe) direkt in die EXIF-Daten neuer Fotos.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await remote.sendCurrentLocationToCamera(silent: false) }
            } label: {
                Label("Aktuellen Standort jetzt senden", systemImage: "location.north.line")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!enabled)
        }
        .padding()
        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
    }

    private func infoRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.footnote.weight(.medium))
                .multilineTextAlignment(.trailing)
        }
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
    }
}

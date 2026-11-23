import SwiftUI
import FujiCore

/// Tab 3: Bluetooth-Fernsteuerung für die Fujifilm X-T4 (ohne WLAN-Verbrauch):
/// Fernauslöser, Bulb, Intervallometer, GPS-Geotagging & Objektiv-/Kamera-Info.
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
                            .foregroundStyle(.tint)
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
                                Text("Noch keine Einträge.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
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
                    .background(
                        Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Bluetooth")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    // MARK: - Cards

    private var connectionHeaderCard: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                        .accessibilityHidden(true)
                    Text("Aktive WLAN-Verbindung belegt die X-T4. Solange Kamera-WLAN läuft, schaltet die Kamera Bluetooth stumm. Ein Tipp unten trennt WLAN sauber und wechselt zu Bluetooth.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if savedTokenHex.isEmpty && !remote.isConnected {
                Text("Bitte kopple deine X-T4 zuerst einmalig im Tab „Fotos“.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if !remote.isConnected {
                Text("Sofort startklar ohne WLAN-Wechsel: Kamera einfach im normalen Liveview einschalten. Für Sucherbild & Belichtung nutze den Tab „Live-View“ (WLAN).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if remote.isConnected {
                Button("Bluetooth trennen", role: .destructive) {
                    Task { await remote.disconnectAndWait() }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            } else {
                Button {
                    Task {
                        if store.isConnected {
                            isSwitchingFromWiFi = true
                            remote.statusBanner = "Trenne Kamera-WLAN und warte kurz, bis die X-T4 Bluetooth wieder freigibt…"
                            await liveView.stopLiveView(using: store)
                            await store.disconnectAndWait()
                            try? await Task.sleep(nanoseconds: 2_500_000_000)
                            isSwitchingFromWiFi = false
                        }
                        await remote.connect(savedTokenHex: savedTokenHex)
                    }
                } label: {
                    HStack(spacing: 8) {
                        if remote.isConnecting || isSwitchingFromWiFi {
                            ProgressView().tint(.white)
                        }
                        Text(
                            isSwitchingFromWiFi
                            ? "Wechsle von WLAN zu Bluetooth…"
                            : (remote.isConnecting
                               ? "Verbinde mit X-T4…"
                               : (store.isConnected
                                  ? "WLAN trennen & per Bluetooth verbinden"
                                  : "Per Bluetooth verbinden"))
                        )
                        .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(remote.isConnecting || isSwitchingFromWiFi || savedTokenHex.isEmpty)
            }
        }
        .padding()
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private func cameraAndLensCard(_ status: FujiBLECameraStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Kamera & Objektiv", systemImage: "camera.metering.center.weighted")
                .font(.headline)

            LabeledContent("Kamera") {
                HStack(spacing: 6) {
                    Text("\(status.cameraName) (FW \(status.firmwareVersion ?? "–"))")
                    if case .upToDate = remote.cameraFirmwareStatus {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityLabel("Kamera-Firmware aktuell")
                    }
                }
            }
            .font(.subheadline)

            if case .updateAvailable(_, let latest, let url) = remote.cameraFirmwareStatus {
                firmwareUpdateNotice(
                    title: "Kamera-Update verfügbar: Ver. \(latest)",
                    url: url
                )
            }

            Divider()

            LabeledContent("Objektiv", value: status.lensName ?? "Nicht ausgelesen / manuell")
                .font(.subheadline)

            if let lensFW = status.lensFirmwareVersion {
                Divider()
                LabeledContent("Objektiv-FW") {
                    HStack(spacing: 6) {
                        Text(lensFW)
                        if case .upToDate = remote.lensFirmwareStatus {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .accessibilityLabel("Objektiv-Firmware aktuell")
                        }
                    }
                }
                .font(.subheadline)

                if case .updateAvailable(_, let latest, let url) = remote.lensFirmwareStatus {
                    firmwareUpdateNotice(
                        title: "Objektiv-Update verfügbar: Ver. \(latest)",
                        url: url
                    )
                }
            }

            if let timeSync = remote.lastSentTimeText {
                Divider()
                LabeledContent("Uhrzeit-Sync", value: "Automatisch um \(timeSync)")
                    .font(.subheadline)
            }
        }
        .padding()
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private func firmwareUpdateNotice(title: String, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .accessibilityHint("Öffnet die offizielle Fujifilm-Downloadseite")
    }

    private func shutterCard(enabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Fernauslöser", systemImage: "camera.shutter.button")
                    .font(.headline)
                Spacer()
                if remote.shotsFiredCount > 0 {
                    Text("\(remote.shotsFiredCount) Auslösungen")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                Task { await remote.triggerSingleShot() }
            } label: {
                HStack(spacing: 8) {
                    if remote.isShutterBusy {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "camera.circle.fill").font(.title3)
                    }
                    Text("Foto auslösen")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!enabled || remote.isShutterBusy || remote.isBulbActive || remote.isIntervalRunning)
            .sensoryFeedback(.impact(flexibility: .solid), trigger: remote.shotsFiredCount)

            HStack(spacing: 10) {
                Button {
                    Task { await remote.focusOnly() }
                } label: {
                    Label("Fokus (AF)", systemImage: "viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!enabled || remote.isShutterBusy || remote.isBulbActive)

                Button {
                    Task { await remote.toggleBulb() }
                } label: {
                    Label(
                        remote.isBulbActive ? "Stopp (\(remote.bulbElapsedSeconds)s)" : "Bulb / Halten",
                        systemImage: remote.isBulbActive ? "stop.circle.fill" : "timer"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(remote.isBulbActive ? .red : .orange)
                .disabled(!enabled || remote.isIntervalRunning)
            }
        }
        .padding()
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private func intervalometerCard(enabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Intervallometer / Zeitraffer", systemImage: "timelapse")
                .font(.headline)

            Stepper("Intervall: \(remote.intervalSeconds) Sekunden", value: Bindable(remote).intervalSeconds, in: 2...300)
                .disabled(remote.isIntervalRunning)

            Divider()

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
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                    Spacer()
                    if remote.intervalCountdown > 0 {
                        Text("Nächstes in \(remote.intervalCountdown)s")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Button("Intervall stoppen", role: .destructive) {
                    remote.stopIntervalometer()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            } else {
                Button("Intervall starten") {
                    remote.startIntervalometer()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(!enabled || remote.isBulbActive)
            }
        }
        .padding()
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private func geotagCard(enabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("GPS-Geotagging", systemImage: "location.fill")
                .font(.headline)

            Toggle("Automatisch bei Kamera-Anfrage senden", isOn: Bindable(remote).isAutoGeotagEnabled)
                .disabled(!enabled)

            if let loc = remote.lastSentLocationText {
                Text("Zuletzt gesendet (\(remote.geotagSendCount)×): \(loc)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                Text("Schreibt iPhone-GPS (Koordinaten & Höhe) direkt in die EXIF-Daten neuer Fotos.")
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
            .controlSize(.large)
            .disabled(!enabled)
        }
        .padding()
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

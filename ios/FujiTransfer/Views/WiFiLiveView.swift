import SwiftUI
import UIKit
import FujiCore

/// Tab 2: WLAN-Live-View, Foto/Video-Aufnahme & Belichtungssteuerung.
/// Bewusst komplett getrennt vom Bluetooth-Tab, damit immer klar ist,
/// wann Kamera-WLAN nötig ist und wann schnelles Bluetooth reicht.
struct WiFiLiveView: View {
    let store: CameraSessionStore
    let liveView: WiFiLiveViewStore
    let remote: BLERemoteStore
    let isTabActive: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var heroIconSize: CGFloat = 46

    var body: some View {
        NavigationStack {
            Group {
                if store.isConnected {
                    connectedLiveViewBody
                } else {
                    disconnectedPromptView
                }
            }
            .navigationTitle("Live-View")
            .navigationBarTitleDisplayMode(store.isConnected ? .inline : .large)
            .toolbar {
                if store.isConnected {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Trennen", role: .destructive) {
                            Task {
                                await liveView.stopLiveView(using: store)
                                store.disconnect()
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task {
                                if liveView.isStreaming {
                                    await liveView.stopLiveView(using: store)
                                } else {
                                    await liveView.startLiveView(using: store)
                                }
                            }
                        } label: {
                            Image(systemName: liveView.isStreaming ? "pause.circle" : "play.circle")
                        }
                        .accessibilityLabel(liveView.isStreaming ? "Live-View pausieren" : "Live-View starten")
                        .disabled(liveView.isStarting)
                    }
                }
            }
            .task(id: "\(isTabActive)-\(store.isConnected)") {
                if isTabActive && store.isConnected {
                    await liveView.startLiveView(using: store)
                }
            }
        }
    }

    // MARK: - Nicht verbunden (WLAN erforderlich)

    private var disconnectedPromptView: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 10) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: heroIconSize, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.primary)
                        .accessibilityHidden(true)

                    Text("Live-View & Belichtung über WLAN")
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)

                    Text("Für das Live-Sucherbild, Video-Aufnahme sowie ISO, Blende, Verschlusszeit und Filmsimulation wird eine aktive WLAN-Verbindung zur X-T4 benötigt.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    ConnectionModeBadge(style: .wifiRequired)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)

                // Kontrast-Hinweis zu Bluetooth
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "bolt.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Nur schnell auslösen oder GPS senden?")
                            .font(.subheadline.weight(.semibold))
                        Text("Dafür brauchst du kein WLAN – nutze einfach den Tab „Bluetooth“ rechts. Das spart Akku und klappt sofort.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(
                    Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )

                // Direkte WLAN-Verbindungsaktionen
                VStack(alignment: .leading, spacing: 12) {
                    Label("Kamera-WLAN starten & verbinden", systemImage: "wifi")
                        .font(.headline)

                    if let status = store.bleStatusMessage {
                        Text(status)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.tint)
                    }

                    Button {
                        Task { await store.wakeWiFiOverBLE(activeBLERemote: remote) }
                    } label: {
                        HStack(spacing: 8) {
                            if store.isBusyBLE { ProgressView().tint(.white) }
                            Text(remote.isConnected
                                 ? "1. WLAN direkt per BLE starten (\(store.savedSSID))"
                                 : "1. WLAN per BLE wecken (\(store.savedSSID))")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(store.isBusyBLE || store.savedTokenHex.isEmpty)

                    Button {
                        Task { await store.connectWiFi(activeBLERemote: remote) }
                    } label: {
                        HStack(spacing: 8) {
                            if store.isConnectingWiFi { ProgressView() }
                            Text(store.isConnectingWiFi ? "Verbinde mit X-T4…" : "2. Mit Kamera-WLAN verbinden")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(store.isConnectingWiFi)

                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("iOS-WLAN-Einstellungen öffnen", systemImage: "gear")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(
                    Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )

                if let err = store.errorMessage {
                    errorBanner(err)
                }
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    // MARK: - Verbunden (Live-View & Steuerung)

    private var connectedLiveViewBody: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack {
                    ConnectionModeBadge(
                        style: .wifiActive(label: liveView.isStreaming ? "WLAN · Live-View aktiv" : "WLAN · Verbunden")
                    )
                    Spacer()
                    if let shots = liveView.status?.shotsRemaining, shots > 0 {
                        Label("\(shots)", systemImage: "photo.stack")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("\(shots) verbleibende Aufnahmen")
                    }
                }

                viewfinderCanvas
                telemetryHUD
                captureButtonsRow

                if let note = liveView.statusNote {
                    Text(note)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.tint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let err = liveView.errorMessage {
                    errorBanner(err)
                }

                exposureControlsCard
                lookControlsCard
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var viewfinderCanvas: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black)

            if let img = liveView.liveImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                VStack(spacing: 10) {
                    if liveView.isStarting || liveView.isStreaming {
                        ProgressView().tint(.white)
                        Text(liveView.isStarting ? "Starte Live-View…" : "Warte auf Sucherbild…")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.8))
                    } else {
                        Image(systemName: "video.slash")
                            .font(.title)
                            .foregroundStyle(.white.opacity(0.7))
                            .accessibilityHidden(true)
                        Button("Live-View starten") {
                            Task { await liveView.startLiveView(using: store) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(24)
            }

            // Overlay oben links/rechts: REC-Indikator & FPS
            VStack {
                HStack {
                    if liveView.isRecordingMovie {
                        HStack(spacing: 5) {
                            Circle().fill(.red).frame(width: 8, height: 8)
                            Text("REC")
                                .font(.caption2.bold().monospaced())
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.65), in: Capsule())
                        .accessibilityLabel("Videoaufnahme aktiv")
                    }
                    Spacer()
                    if liveView.fps > 0.5 {
                        Text(String(format: "%.0f fps", liveView.fps))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.55), in: Capsule())
                    }
                }
                Spacer()
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(3.0 / 2.0, contentMode: .fit)
    }

    private var telemetryHUD: some View {
        HStack(spacing: 8) {
            hudPill(title: "Blende", value: liveView.status?.formattedFNumber ?? "–")
            hudPill(title: "Zeit", value: liveView.status?.formattedShutterSpeed ?? "–")
            hudPill(title: "ISO", value: liveView.status?.formattedISO ?? "–")
            hudPill(title: "EV", value: liveView.status?.formattedExposureBias ?? "–")
        }
    }

    private func hudPill(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.bold().monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    private var captureButtonsRow: some View {
        HStack(spacing: 12) {
            Button {
                Task { await liveView.capturePhoto(using: store) }
            } label: {
                HStack(spacing: 8) {
                    if liveView.isCapturing {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "camera.circle.fill").font(.title3)
                    }
                    Text("Foto auslösen")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!liveView.isStreaming || liveView.isCapturing || liveView.isRecordingMovie)
            .sensoryFeedback(.impact(flexibility: .solid), trigger: liveView.isCapturing)

            if liveView.isRecordingMovie {
                Button(role: .destructive) {
                    Task { await liveView.toggleMovieRecording(using: store) }
                } label: {
                    Label("Stopp", systemImage: "stop.circle.fill")
                        .fontWeight(.semibold)
                        .frame(minWidth: 105)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(!liveView.isStreaming || liveView.isCapturing)
            } else {
                Button {
                    Task { await liveView.toggleMovieRecording(using: store) }
                } label: {
                    Label("Video", systemImage: "record.circle")
                        .fontWeight(.semibold)
                        .frame(minWidth: 105)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!liveView.isStreaming || liveView.isCapturing)
            }
        }
    }

    private var exposureControlsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Belichtung steuern", systemImage: "dial.medium")
                .font(.headline)

            stepControlRow(
                label: "Blende",
                value: liveView.status?.formattedFNumber ?? "–",
                kind: .fNumber
            )
            Divider()
            stepControlRow(
                label: "Verschlusszeit",
                value: liveView.status?.formattedShutterSpeed ?? "–",
                kind: .shutterSpeed
            )
            Divider()
            stepControlRow(
                label: "Belichtung (EV)",
                value: liveView.status?.formattedExposureBias ?? "–",
                kind: .exposureBias
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private func stepControlRow(label: String, value: String, kind: FujiStepControlKind) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.subheadline)
            Spacer()
            Button {
                Task { await liveView.step(kind, up: false, using: store) }
            } label: {
                Image(systemName: "minus")
                    .frame(minWidth: 36, minHeight: 28)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("\(label) verringern")
            .disabled(!liveView.isStreaming || liveView.isUpdatingSetting)

            Text(value)
                .font(.subheadline.bold().monospacedDigit())
                .frame(minWidth: 68, alignment: .center)

            Button {
                Task { await liveView.step(kind, up: true, using: store) }
            } label: {
                Image(systemName: "plus")
                    .frame(minWidth: 36, minHeight: 28)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("\(label) erhöhen")
            .disabled(!liveView.isStreaming || liveView.isUpdatingSetting)
        }
    }

    private var lookControlsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("ISO & Filmsimulation", systemImage: "film.stack")
                .font(.headline)

            HStack {
                Text("ISO")
                    .font(.subheadline)
                Spacer()
                if liveView.isoOptions.isEmpty {
                    Text(liveView.status?.formattedISO ?? "–")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Menu {
                        ForEach(liveView.isoOptions) { opt in
                            Button(opt.label) {
                                Task { await liveView.selectISO(opt.rawValue, using: store) }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(liveView.status?.formattedISO ?? "Wählen")
                                .fontWeight(.medium)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .disabled(!liveView.isStreaming || liveView.isUpdatingSetting)
                }
            }

            Divider()

            HStack {
                Text("Filmsimulation")
                    .font(.subheadline)
                Spacer()
                if liveView.filmSimOptions.isEmpty {
                    Text(liveView.status?.formattedFilmSimulation ?? "–")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Menu {
                        ForEach(liveView.filmSimOptions) { opt in
                            Button(opt.label) {
                                Task { await liveView.selectFilmSimulation(opt.rawValue, using: store) }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(liveView.status?.formattedFilmSimulation ?? "Wählen")
                                .fontWeight(.medium)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .disabled(!liveView.isStreaming || liveView.isUpdatingSetting)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(text).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

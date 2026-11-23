import SwiftUI
import UIKit
import FujiCore

/// Tab 2: WLAN-Live-View, Foto/Video-Aufnahme & Belichtungssteuerung.
/// Bewusst komplett getrennt vom Bluetooth-Tab, damit immer klar ist,
/// wann Kamera-WLAN noetig ist und wann schnelles Bluetooth reicht.
struct WiFiLiveView: View {
    let store: CameraSessionStore
    let liveView: WiFiLiveViewStore
    let remote: BLERemoteStore
    let isTabActive: Bool

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
            .navigationBarTitleDisplayMode(.inline)
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
            VStack(spacing: 18) {
                VStack(spacing: 10) {
                    ConnectionModeBadge(style: .wifiRequired)

                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 46))
                        .foregroundStyle(.primary)
                        .padding(.top, 4)

                    Text("Live-View & Belichtung ueber WLAN")
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)

                    Text("Fuer das Live-Sucherbild, Video-Aufnahme sowie ISO, Blende, Verschlusszeit und Filmsimulation wird eine aktive WLAN-Verbindung zur X-T4 benoetigt.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)

                // Kontrast-Hinweis zu Bluetooth
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "bolt.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Nur schnell ausloesen oder GPS senden?")
                            .font(.subheadline.weight(.semibold))
                        Text("Dafuer brauchst du kein WLAN – nutze einfach den Tab 'BLE-Steuerung' rechts. Das spart Akku und klappt sofort.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))

                // Direkte WLAN-Verbindungsaktionen
                VStack(alignment: .leading, spacing: 12) {
                    Label("Kamera-WLAN starten & verbinden", systemImage: "wifi")
                        .font(.headline)

                    if let status = store.bleStatusMessage {
                        Text(status)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.blue)
                    }

                    Button {
                        Task { await store.wakeWiFiOverBLE(activeBLERemote: remote) }
                    } label: {
                        HStack {
                            if store.isBusyBLE { ProgressView().tint(.white) }
                            Text(remote.isConnected
                                 ? "1. WLAN direkt per BLE starten (\(store.savedSSID))"
                                 : "1. WLAN per BLE wecken (\(store.savedSSID))")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isBusyBLE || store.savedTokenHex.isEmpty)

                    Button {
                        Task { await store.connectWiFi(activeBLERemote: remote) }
                    } label: {
                        HStack {
                            if store.isConnectingWiFi { ProgressView().tint(.white) }
                            Text(store.isConnectingWiFi ? "Verbinde mit X-T4..." : "2. Mit Kamera-WLAN verbinden")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(store.isConnectingWiFi)

                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("iOS-WLAN-Einstellungen oeffnen", systemImage: "gear")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))

                if let err = store.errorMessage {
                    errorBanner(err)
                }
            }
            .padding()
        }
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
                    }
                }

                viewfinderCanvas
                telemetryHUD
                captureButtonsRow

                if let note = liveView.statusNote {
                    Text(note)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.blue)
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
    }

    private var viewfinderCanvas: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black)

            if let img = liveView.liveImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                VStack(spacing: 10) {
                    if liveView.isStarting || liveView.isStreaming {
                        ProgressView().tint(.white)
                        Text(liveView.isStarting ? "Starte Live-View..." : "Warte auf Sucherbild...")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.8))
                    } else {
                        Image(systemName: "video.slash")
                            .font(.title)
                            .foregroundStyle(.white.opacity(0.7))
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
        .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
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
                    Text("Foto ausloesen")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!liveView.isStreaming || liveView.isCapturing || liveView.isRecordingMovie)

            Button {
                Task { await liveView.toggleMovieRecording(using: store) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: liveView.isRecordingMovie ? "stop.circle.fill" : "record.circle")
                        .font(.title3)
                    Text(liveView.isRecordingMovie ? "Stopp" : "Video")
                        .fontWeight(.semibold)
                }
                .frame(minWidth: 105)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(liveView.isRecordingMovie ? .red : .orange)
            .disabled(!liveView.isStreaming || liveView.isCapturing)
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
            stepControlRow(
                label: "Verschlusszeit",
                value: liveView.status?.formattedShutterSpeed ?? "–",
                kind: .shutterSpeed
            )
            stepControlRow(
                label: "Belichtung (EV)",
                value: liveView.status?.formattedExposureBias ?? "–",
                kind: .exposureBias
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
    }

    private func stepControlRow(label: String, value: String, kind: FujiStepControlKind) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
            Spacer()
            Button {
                Task { await liveView.step(kind, up: false, using: store) }
            } label: {
                Image(systemName: "minus")
                    .frame(width: 34, height: 28)
            }
            .buttonStyle(.bordered)
            .disabled(!liveView.isStreaming || liveView.isUpdatingSetting)

            Text(value)
                .font(.subheadline.bold().monospacedDigit())
                .frame(minWidth: 72, alignment: .center)

            Button {
                Task { await liveView.step(kind, up: true, using: store) }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 34, height: 28)
            }
            .buttonStyle(.bordered)
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
                            Text(liveView.status?.formattedISO ?? "Waehlen")
                                .fontWeight(.medium)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.secondary.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .disabled(!liveView.isStreaming || liveView.isUpdatingSetting)
                }
            }

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
                            Text(liveView.status?.formattedFilmSimulation ?? "Waehlen")
                                .fontWeight(.medium)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.secondary.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .disabled(!liveView.isStreaming || liveView.isUpdatingSetting)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
    }
}

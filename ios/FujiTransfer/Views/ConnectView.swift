import SwiftUI
import UIKit

struct ConnectView: View {
    let store: CameraSessionStore
    let remote: BLERemoteStore
    @State private var showLogs = false
    @ScaledMetric(relativeTo: .largeTitle) private var heroIconSize: CGFloat = 46

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerSection
                bluetoothCard
                wifiConnectCard

                if let error = store.errorMessage {
                    errorBanner(error)
                }

                DisclosureGroup("Diagnose-Protokoll (\(store.logs.count))", isExpanded: $showLogs) {
                    VStack(alignment: .leading, spacing: 4) {
                        if store.logs.isEmpty {
                            Text("Noch keine Einträge.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(store.logs.enumerated()), id: \.offset) { _, line in
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
        .navigationTitle("Fotos")
        .navigationBarTitleDisplayMode(.large)
    }

    private var headerSection: some View {
        VStack(spacing: 10) {
            Image(systemName: "camera.aperture")
                .font(.system(size: heroIconSize, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.primary)
                .accessibilityHidden(true)

            Text("Fujifilm X-T4 Direkt-Transfer")
                .font(.title3.bold())
                .multilineTextAlignment(.center)

            Text("Original-JPEGs (6240 × 4160) & Live-View über Kamera-WLAN. Für schnelles Auslösen & GPS reicht der Tab „Bluetooth“ ohne WLAN.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            ConnectionModeBadge(style: .wifiRequired)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var bluetoothCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Schritt 1: Kamera-WLAN per Bluetooth starten", systemImage: "dot.radiowaves.left.and.right")
                .font(.headline)

            if store.savedTokenHex.isEmpty {
                Text("Einmalig: Öffne an der X-T4 „Bluetooth/Smartphone → Kopplungsregistrierung“ und tippe auf Koppeln.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Gekoppelt (Token: \(store.savedTokenHex) · WLAN: \(store.savedSSID)). Kamera einfach im Liveview einschalten.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let status = store.bleStatusMessage {
                Text(status)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.tint)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    wakeWiFiButton
                    pairButton
                }
                VStack(spacing: 10) {
                    wakeWiFiButton
                    pairButton
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

    private var wakeWiFiButton: some View {
        Button {
            Task { await store.wakeWiFiOverBLE(activeBLERemote: remote) }
        } label: {
            HStack(spacing: 8) {
                if store.isBusyBLE {
                    ProgressView().tint(.white)
                }
                Text(remote.isConnected ? "WLAN direkt per BLE starten" : "WLAN per BLE wecken")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(store.isBusyBLE || store.savedTokenHex.isEmpty)
    }

    private var pairButton: some View {
        Button {
            Task { await store.pairOverBLE(activeBLERemote: remote) }
        } label: {
            Text(store.savedTokenHex.isEmpty ? "Koppeln" : "Neu koppeln")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(store.isBusyBLE)
    }

    private var wifiConnectCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Schritt 2: Mit Kamera verbinden", systemImage: "wifi")
                .font(.headline)

            Text("Verbinde dein iPhone im WLAN-Menü mit „\(store.savedSSID)“ und tippe dann auf Verbinden.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button {
                Task { await store.connectWiFi(activeBLERemote: remote) }
            } label: {
                HStack(spacing: 8) {
                    if store.isConnectingWiFi {
                        ProgressView().tint(.white)
                    }
                    Text(store.isConnectingWiFi ? "Verbinde mit X-T4…" : "Mit Kamera verbinden")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(store.isConnectingWiFi)

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("iOS-Einstellungen öffnen", systemImage: "gear")
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
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

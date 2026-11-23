import SwiftUI
import UIKit

struct ConnectView: View {
    let store: CameraSessionStore
    let remote: BLERemoteStore
    @State private var showLogs = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerCard
                bluetoothCard
                wifiConnectCard

                if let error = store.errorMessage {
                    errorBanner(error)
                }

                DisclosureGroup("Diagnose-Protokoll (\(store.logs.count))", isExpanded: $showLogs) {
                    VStack(alignment: .leading, spacing: 4) {
                        if store.logs.isEmpty {
                            Text("Noch keine Eintraege.")
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
                .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            }
            .padding()
        }
        .navigationTitle("FujiTransfer")
    }

    private var headerCard: some View {
        VStack(spacing: 8) {
            ConnectionModeBadge(style: .wifiRequired)
            Image(systemName: "camera.aperture")
                .font(.system(size: 46))
                .foregroundStyle(.primary)
                .padding(.top, 2)
            Text("Fujifilm X-T4 Direkt-Transfer")
                .font(.title3.bold())
            Text("Original-JPEGs (6240 × 4160) & Live-View ueber Kamera-WLAN. Fuer schnelles Ausloesen & GPS reicht der Tab 'BLE-Steuerung' ohne WLAN.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var bluetoothCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Schritt 1: Kamera-WLAN per Bluetooth starten", systemImage: "dot.radiowaves.left.and.right")
                .font(.headline)

            if store.savedTokenHex.isEmpty {
                Text("Einmalig: Stelle an der X-T4 'Bluetooth/Smartphone -> Kopplungsregistrierung' ein und tippe auf Koppeln.")
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
                    .foregroundStyle(.blue)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await store.wakeWiFiOverBLE(activeBLERemote: remote) }
                } label: {
                    HStack {
                        if store.isBusyBLE {
                            ProgressView().tint(.white)
                        }
                        Text(remote.isConnected ? "WLAN direkt per BLE starten" : "WLAN per BLE wecken")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isBusyBLE || store.savedTokenHex.isEmpty)

                Button {
                    Task { await store.pairOverBLE(activeBLERemote: remote) }
                } label: {
                    Text(store.savedTokenHex.isEmpty ? "Koppeln" : "Neu koppeln")
                }
                .buttonStyle(.bordered)
                .disabled(store.isBusyBLE)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
    }

    private var wifiConnectCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Schritt 2: Mit Kamera verbinden", systemImage: "wifi")
                .font(.headline)

            Text("Verbinde dein iPhone im WLAN-Menue mit '\(store.savedSSID)' und tippe dann auf Verbinden.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button {
                Task { await store.connectWiFi(activeBLERemote: remote) }
            } label: {
                HStack {
                    if store.isConnectingWiFi {
                        ProgressView().tint(.white)
                    }
                    Text(store.isConnectingWiFi ? "Verbinde mit X-T4..." : "Mit Kamera verbinden")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(store.isConnectingWiFi)

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("iOS-Einstellungen oeffnen", systemImage: "gear")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
    }
}

import SwiftUI

/// Hauptnavigation mit klarer 3-Tab-Trennung zwischen WLAN-Funktionen und schneller Bluetooth-Steuerung:
/// 1) Fotos (WLAN)   2) Live-View (WLAN)   3) BLE-Steuerung (nur Bluetooth, ohne WLAN)
enum AppTab: Hashable {
    case photos
    case liveView
    case bleRemote
}

struct ContentView: View {
    let store: CameraSessionStore
    let liveView: WiFiLiveViewStore
    let remote: BLERemoteStore

    @State private var selectedTab: AppTab = .photos

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                Group {
                    if store.isConnected {
                        GalleryView(store: store)
                    } else {
                        ConnectView(store: store, remote: remote)
                    }
                }
            }
            .tabItem {
                Label("Fotos", systemImage: "photo.on.rectangle.angled")
            }
            .tag(AppTab.photos)

            WiFiLiveView(
                store: store,
                liveView: liveView,
                remote: remote,
                isTabActive: selectedTab == .liveView
            )
            .tabItem {
                Label("Live-View", systemImage: "camera.viewfinder")
            }
            .tag(AppTab.liveView)

            BLERemoteView(
                remote: remote,
                store: store,
                liveView: liveView
            )
                .tabItem {
                    Label("BLE-Steuerung", systemImage: "dot.radiowaves.left.and.right")
                }
                .tag(AppTab.bleRemote)
        }
        .onChange(of: selectedTab) { oldTab, newTab in
            // Beim Verlassen des Live-View-Tabs sauber in den Galerie-Modus zurueckschalten
            if oldTab == .liveView && newTab != .liveView {
                Task { await liveView.stopLiveView(using: store) }
            }
        }
        .overlay {
            if let state = store.transferState {
                TransferOverlayView(
                    state: state,
                    onCancel: { store.cancelTransfer() },
                    onDismiss: { store.dismissTransferSummary() }
                )
            }
        }
    }
}

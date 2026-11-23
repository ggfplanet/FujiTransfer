import SwiftUI

@main
struct FujiTransferApp: App {
    @State private var store = CameraSessionStore()
    @State private var liveView = WiFiLiveViewStore()
    @State private var remote = BLERemoteStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store, liveView: liveView, remote: remote)
        }
    }
}

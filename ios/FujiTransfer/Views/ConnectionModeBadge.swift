import SwiftUI

/// Einheitliches Status-Badge, das ueber alle 3 Tabs hinweg sofort klar macht,
/// ob eine schnelle Bluetooth-Verbindung reicht oder Kamera-WLAN noetig ist.
struct ConnectionModeBadge: View {
    enum Style {
        case bluetoothFast
        case wifiRequired
        case wifiActive(label: String)
    }

    let style: Style

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.caption.weight(.bold))
            Text(title)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .foregroundStyle(tintColor)
        .background(tintColor.opacity(0.14), in: Capsule())
        .overlay(Capsule().stroke(tintColor.opacity(0.32), lineWidth: 1))
    }

    private var iconName: String {
        switch style {
        case .bluetoothFast: return "bolt.fill"
        case .wifiRequired: return "wifi"
        case .wifiActive: return "wifi.circle.fill"
        }
    }

    private var title: String {
        switch style {
        case .bluetoothFast: return "Schnell · nur Bluetooth (ohne WLAN)"
        case .wifiRequired: return "WLAN erforderlich"
        case .wifiActive(let label): return label
        }
    }

    private var tintColor: Color {
        switch style {
        case .bluetoothFast: return .blue
        case .wifiRequired: return .orange
        case .wifiActive: return .green
        }
    }
}

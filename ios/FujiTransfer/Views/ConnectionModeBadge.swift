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
                .accessibilityHidden(true)
            Text(title)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .foregroundStyle(tintColor)
        .background(tintColor.opacity(0.14), in: Capsule())
        .overlay(Capsule().stroke(tintColor.opacity(0.28), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Verbindungsmodus: \(title)")
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
        case .bluetoothFast: return "Nur Bluetooth · ohne WLAN"
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

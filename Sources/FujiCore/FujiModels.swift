import Foundation

/// Protokoll-Modus fuer die Fujifilm WLAN-Verbindung.
public enum FujiTransportMode: String, Sendable, CaseIterable {
    /// Manueller Kamera-Hotspot / "WIRELESS COMMUNICATION" (klassischer Camera-Remote-Modus).
    case wirelessComm = "wireless"
    /// Moderner FUJIFILM XApp-Modus (typisch nach BLE-Handover oder neuer Firmware).
    case xapp = "xapp"
}

/// Infos zu einem SD-Kartenslot der Kamera (X-T4 hat 2 Slots).
public struct FujiCardInfo: Sendable, Equatable {
    public let id: Int
    public let name: String
    public let objectCount: Int

    public init(id: Int, name: String, objectCount: Int) {
        self.id = id
        self.name = name
        self.objectCount = objectCount
    }
}

/// Diagnose-Zusammenfassung direkt nach dem Verbindungsaufbau.
public struct FujiSessionInfo: Sendable, Equatable {
    public let cameraName: String
    public let cameraState: Int
    public let remoteVersion: Int
    public let remoteImageViewVersion: Int
    public let remoteImageViewExVersion: Int
    public let activeCardID: Int
    public let totalObjectCount: Int
    public let hasExplicitHandleList: Bool
    public let effectiveMode: FujiTransportMode
    public let cards: [FujiCardInfo]

    public init(
        cameraName: String,
        cameraState: Int,
        remoteVersion: Int,
        remoteImageViewVersion: Int,
        remoteImageViewExVersion: Int,
        activeCardID: Int,
        totalObjectCount: Int,
        hasExplicitHandleList: Bool,
        effectiveMode: FujiTransportMode,
        cards: [FujiCardInfo]
    ) {
        self.cameraName = cameraName
        self.cameraState = cameraState
        self.remoteVersion = remoteVersion
        self.remoteImageViewVersion = remoteImageViewVersion
        self.remoteImageViewExVersion = remoteImageViewExVersion
        self.activeCardID = activeCardID
        self.totalObjectCount = totalObjectCount
        self.hasExplicitHandleList = hasExplicitHandleList
        self.effectiveMode = effectiveMode
        self.cards = cards
    }
}

/// Metadaten zu einem Foto oder Video auf der SD-Karte.
public struct FujiPhotoInfo: Sendable, Equatable, Identifiable {
    public var id: UInt32 { handle }
    public let index: Int
    public let handle: UInt32
    public let storageID: UInt32
    public let objectFormat: UInt16
    public let compressedSize: UInt32
    public let width: UInt32
    public let height: UInt32
    public let filename: String
    public let dateCreated: String

    /// PTP ObjectFormat 0x3801 entspricht JPEG (EXIF/JFIF).
    public var isJPEG: Bool {
        objectFormat == 0x3801
    }

    public var formatLabel: String {
        switch objectFormat {
        case 0x3801: return "JPEG"
        case 0x3800: return "RAW/RAF"
        case 0xB982, 0x300D: return "VIDEO"
        default: return String(format: "0x%04X", objectFormat)
        }
    }
}

/// Ergebnis eines einzelnen Foto-Downloads inklusive Geschwindigkeitsmessung.
public struct FujiDownloadResult: Sendable {
    public let handle: UInt32
    public let filename: String
    public let bytesWritten: Int
    public let expectedSize: Int
    public let durationSeconds: Double
    public let validJPEGHeader: Bool
    public let validJPEGFooter: Bool
    public let outputURL: URL

    public var megabytesPerSecond: Double {
        guard durationSeconds > 0 else { return 0 }
        return (Double(bytesWritten) / (1024.0 * 1024.0)) / durationSeconds
    }
}

/// Gefundenes Fujifilm-Geraet beim Bluetooth-LE-Scan.
public struct FujiBLEDevice: Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let rssi: Int
    public let manufacturerDataHex: String?
    public let pairingTokenHex: String?
    public let advertisedServices: [String]
}

/// Ausgelesene WLAN-Zugangsdaten und Status nach BLE-Verbindung.
public struct FujiBLEWiFiResult: Sendable {
    public let cameraName: String
    public let firmwareVersion: String?
    public let pairingMode: String
    public let pairingTokenHex: String?
    public let ssid: String
    public let password: String?
    public let isHiddenNetwork: Bool
    public let wifiTriggered: Bool
    public let wifiReadyState: String
}

/// Ausgelesene Kamera- & Objektiv-Infos einer laufenden BLE-Steuerungs-Session.
public struct FujiBLECameraStatus: Sendable, Equatable {
    public let cameraName: String
    public let firmwareVersion: String?
    public let lensName: String?
    public let lensFirmwareVersion: String?
    public let wifiSSID: String?
    public let supportsShutter: Bool
    public let supportsGeotag: Bool
    public let supportsFiles: Bool

    public init(
        cameraName: String,
        firmwareVersion: String?,
        lensName: String?,
        lensFirmwareVersion: String?,
        wifiSSID: String?,
        supportsShutter: Bool,
        supportsGeotag: Bool,
        supportsFiles: Bool
    ) {
        self.cameraName = cameraName
        self.firmwareVersion = firmwareVersion
        self.lensName = lensName
        self.lensFirmwareVersion = lensFirmwareVersion
        self.wifiSSID = wifiSSID
        self.supportsShutter = supportsShutter
        self.supportsGeotag = supportsGeotag
        self.supportsFiles = supportsFiles
    }
}

/// Dateityp fuer kleine BLE-Dateitransfers (Kamera-Backup oder Status).
public enum FujiBLEFileKind: String, Sendable {
    case backup
    case status
}

/// Ergebnis eines BLE-Datei-Downloads (Kamera-Backup oder Statusdaten).
public struct FujiBLEFileResult: Sendable {
    public let kind: FujiBLEFileKind
    public let filename: String
    public let data: Data
}

/// Fehler beim Verbinden oder Uebertragen mit der Fujifilm-Kamera.
public enum FujiError: LocalizedError, Sendable {
    case notConnected
    case connectionFailed(code: Int32, detail: String)
    case protocolError(operation: String, code: Int32, detail: String)
    case invalidData(String)
    case bleUnavailable(String)
    case bleTimeout(String)
    case bleError(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Keine aktive Verbindung zur Kamera."
        case .connectionFailed(let code, let detail):
            return "Verbindung fehlgeschlagen (Code \(code)): \(detail)"
        case .protocolError(let op, let code, let detail):
            return "Fehler bei \(op) (Code \(code)): \(detail)"
        case .invalidData(let reason):
            return "Ungueltige Daten: \(reason)"
        case .bleUnavailable(let reason):
            return "Bluetooth nicht verfuegbar: \(reason)"
        case .bleTimeout(let reason):
            return "Bluetooth-Timeout: \(reason)"
        case .bleError(let reason):
            return "Bluetooth-Fehler: \(reason)"
        }
    }
}

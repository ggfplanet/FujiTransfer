import Foundation

/// Ziel-Parameter fuer schrittweise Belichtungssteuerung ueber WLAN (0x902C..0x902E).
public enum FujiStepControlKind: Sendable {
    case shutterSpeed
    case fNumber
    case exposureBias
}

/// Kameraseitiger XApp-Sternbewertungs-Filter (Bitmaske fuer PTP Property 0xD603).
/// Bit 0 = 0 Sterne, Bit 1 = 1 Stern, ..., Bit 5 = 5 Sterne.
public enum FujiStarRatingFilter: UInt16, CaseIterable, Identifiable, Sendable {
    case all = 0x3F
    case oneOrMore = 0x3E
    case threeOrMore = 0x38
    case fourOrMore = 0x30
    case fiveOnly = 0x20

    public var id: UInt16 { rawValue }

    public var label: String {
        switch self {
        case .all: return "Alle ★"
        case .oneOrMore: return "≥ 1★"
        case .threeOrMore: return "≥ 3★"
        case .fourOrMore: return "≥ 4★"
        case .fiveOnly: return "5★"
        }
    }
}

/// Einzelne von der Kamera gemeldete Auswahloption (z. B. ISO oder Filmsimulation).
public struct FujiPropOption: Identifiable, Hashable, Sendable {
    public var id: UInt32 { rawValue }
    public let rawValue: UInt32
    public let label: String

    public init(rawValue: UInt32, label: String) {
        self.rawValue = rawValue
        self.label = label
    }
}

/// Live-Belichtungswerte und Status der Kamera waehrend einer WLAN-Live-View-Session.
public struct FujiLiveViewStatus: Equatable, Sendable {
    public let isoRaw: UInt32
    public let fNumberRaw: UInt32
    public let shutterSpeedRaw: UInt32
    public let filmSimulationRaw: UInt32
    public let exposureBiasMillistops: Int32?
    public let whiteBalanceRaw: UInt32
    public let batteryLevel: UInt32
    public let shotsRemaining: UInt32
    public let movieRemainingSeconds: UInt32
    public let isLiveViewActive: Bool

    public init(
        isoRaw: UInt32,
        fNumberRaw: UInt32,
        shutterSpeedRaw: UInt32,
        filmSimulationRaw: UInt32,
        exposureBiasMillistops: Int32?,
        whiteBalanceRaw: UInt32,
        batteryLevel: UInt32,
        shotsRemaining: UInt32,
        movieRemainingSeconds: UInt32,
        isLiveViewActive: Bool
    ) {
        self.isoRaw = isoRaw
        self.fNumberRaw = fNumberRaw
        self.shutterSpeedRaw = shutterSpeedRaw
        self.filmSimulationRaw = filmSimulationRaw
        self.exposureBiasMillistops = exposureBiasMillistops
        self.whiteBalanceRaw = whiteBalanceRaw
        self.batteryLevel = batteryLevel
        self.shotsRemaining = shotsRemaining
        self.movieRemainingSeconds = movieRemainingSeconds
        self.isLiveViewActive = isLiveViewActive
    }

    public var formattedFNumber: String {
        guard fNumberRaw > 0 else { return "–" }
        let f = Double(fNumberRaw) / 100.0
        return String(format: "f/%.1f", f)
    }

    public var formattedISO: String {
        Self.formatISO(isoRaw)
    }

    public var formattedShutterSpeed: String {
        Self.formatShutterSpeed(shutterSpeedRaw)
    }

    public var formattedExposureBias: String {
        guard let milli = exposureBiasMillistops else { return "–" }
        let ev = Double(milli) / 1000.0
        if abs(ev) < 0.05 { return "0.0 EV" }
        return String(format: "%+.1f EV", ev)
    }

    public var formattedFilmSimulation: String {
        Self.formatFilmSimulation(filmSimulationRaw)
    }

    /// Dekodiert Fujifilms 32-Bit-ISO-Wert (Bit 31 = AUTO, Bit 30 = Erweitert/Low).
    public static func formatISO(_ raw: UInt32) -> String {
        if raw == 0 || raw == 0xFFFF_FFFF { return "AUTO" }
        let isAuto = (raw & 0x8000_0000) != 0
        let isExtended = (raw & 0x4000_0000) != 0
        let numeric = raw & 0x00FF_FFFF
        if numeric == 0 { return "AUTO" }
        if isAuto { return "AUTO \(numeric)" }
        if isExtended && numeric <= 100 { return "L \(numeric)" }
        if isExtended && numeric >= 12800 { return "H \(numeric)" }
        return "\(numeric)"
    }

    /// Dekodiert Fujifilms 0xD240 Verschlusszeit-Wert (Bit 31 = 1/X in Millisekunden-Kehrwert).
    public static func formatShutterSpeed(_ raw: UInt32) -> String {
        if raw == 0 || raw == 0xFFFF_FFFF { return "AUTO" }
        let isFraction = (raw & 0x8000_0000) != 0
        let magnitude = raw & 0x7FFF_FFFF
        guard magnitude > 0 else { return "–" }
        if isFraction {
            let denom = Double(magnitude) / 1000.0
            if denom >= 1.5 {
                return "1/\(Int(denom.rounded()))"
            }
            return String(format: "1/%.1f", denom)
        } else {
            let seconds = Double(magnitude) / 1000.0
            if seconds >= 10 {
                return String(format: "%.0fs", seconds)
            }
            return String(format: "%.1fs", seconds)
        }
    }

    /// Mappt Fujifilm X-T4 Filmsimulations-IDs (PTP 0xD001) auf lesbare Namen.
    public static func formatFilmSimulation(_ raw: UInt32) -> String {
        switch raw {
        case 0: return "–"
        case 1: return "PROVIA / Standard"
        case 2: return "Velvia / Vivid"
        case 3: return "ASTIA / Soft"
        case 4: return "PRO Neg. Hi"
        case 5: return "PRO Neg. Std"
        case 6: return "Monochrome"
        case 7: return "Monochrome + Ye"
        case 8: return "Monochrome + R"
        case 9: return "Monochrome + G"
        case 10: return "Sepia"
        case 11: return "Classic Chrome"
        case 12: return "ACROS"
        case 13: return "ACROS + Ye"
        case 14: return "ACROS + R"
        case 15: return "ACROS + G"
        case 16: return "ETERNA / Cinema"
        case 17: return "Classic Neg."
        case 18: return "ETERNA Bleach Bypass"
        case 19: return "Nostalgic Neg."
        case 20: return "REALA ACE"
        default: return "Film #\(raw)"
        }
    }
}

public extension FujiPhotoInfo {
    /// Liefert den reinen Datums-Schluessel `YYYYMMDD` aus PTP `dateCreated` (z. B. `20261122T183412`).
    var captureDateKey: String? {
        let digits = dateCreated.prefix(8)
        guard digits.count == 8, digits.allSatisfy(\.isNumber) else { return nil }
        return String(digits)
    }

    /// Formatiert das Aufnahmedatum als `TT.MM.JJJJ` fuer die Galerie-Filterleiste.
    var formattedCaptureDate: String? {
        guard let key = captureDateKey else { return nil }
        let y = key.prefix(4)
        let m = key.dropFirst(4).prefix(2)
        let d = key.dropFirst(6).prefix(2)
        return "\(d).\(m).\(y)"
    }
}

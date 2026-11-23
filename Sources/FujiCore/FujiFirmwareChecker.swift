import Foundation

/// Einzelner Firmware-Eintrag von der offiziellen Fujifilm-Supportseite.
public struct FujiFirmwareEntry: Sendable, Equatable, Codable {
    public let modelName: String
    public let latestVersion: String
    public let downloadURL: URL

    public init(modelName: String, latestVersion: String, downloadURL: URL) {
        self.modelName = modelName
        self.latestVersion = latestVersion
        self.downloadURL = downloadURL
    }
}

/// Verifiziertes Ergebnis des Firmware-Vergleichs gegen fujifilm-x.com.
/// Ist eine Pruefung nicht moeglich (offline, nicht gelistet, Drittanbieter), wird `nil` geliefert.
public enum FujiFirmwareStatus: Sendable, Equatable {
    case upToDate(latestVersion: String, downloadURL: URL)
    case updateAvailable(installedVersion: String, latestVersion: String, downloadURL: URL)
}

/// Prueft Kamera- und Fujifilm-Objektiv-Firmware gegen die offiziellen
/// Fujifilm-Uebersichtsseiten (fujifilm-x.com) mit lokalem Cache.
public actor FujiFirmwareChecker {
    public enum Category: String, Sendable {
        case cameras
        case lenses

        public var pageURL: URL {
            switch self {
            case .cameras:
                return URL(string: "https://www.fujifilm-x.com/global/support/download/firmware/cameras/")!
            case .lenses:
                return URL(string: "https://www.fujifilm-x.com/global/support/download/firmware/lenses/")!
            }
        }
    }

    private struct CachedCatalog: Codable {
        let fetchedAt: Date
        let entries: [FujiFirmwareEntry]
    }

    private let session: URLSession
    private let cacheTTL: TimeInterval
    private let cacheDirectory: URL?
    private var memoryCache: [Category: CachedCatalog] = [:]

    public init(
        session: URLSession? = nil,
        cacheTTL: TimeInterval = 60 * 60 * 24,
        cacheDirectory: URL? = nil
    ) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 8
            config.timeoutIntervalForResource = 12
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
        self.cacheTTL = cacheTTL
        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else {
            self.cacheDirectory = FileManager.default
                .urls(for: .cachesDirectory, in: .userDomainMask)
                .first?
                .appendingPathComponent("FujiTransferFirmwareCache", isDirectory: true)
        }
    }

    // MARK: - Oeffentliche Pruef-API

    /// Prueft die Kamera-Firmware gegen die offizielle Fujifilm-Kamera-Liste.
    /// Gibt `nil` zurueck, wenn kein Internet/Cache vorhanden oder das Modell nicht eindeutig zuordenbar ist.
    public func checkCameraFirmware(
        modelName: String,
        installedVersion: String?
    ) async -> FujiFirmwareStatus? {
        guard let installedVersion,
              !installedVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard let entries = await fetchCatalog(for: .cameras),
              let match = Self.matchCamera(modelName: modelName, in: entries) else {
            return nil
        }
        return Self.compare(installed: installedVersion, against: match)
    }

    /// Prueft die Objektiv-Firmware ausschliesslich fuer Original-Fujifilm-Objektive (XF/XC/GF).
    /// Drittanbieter-Objektive oder nicht gelistete Modelle liefern bewusst `nil`.
    public func checkLensFirmware(
        lensName: String?,
        installedVersion: String?
    ) async -> FujiFirmwareStatus? {
        guard let lensName,
              let installedVersion,
              Self.isFujifilmLensName(lensName),
              !installedVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard let entries = await fetchCatalog(for: .lenses),
              let match = Self.matchLens(lensName: lensName, in: entries) else {
            return nil
        }
        return Self.compare(installed: installedVersion, against: match)
    }

    // MARK: - Abruf & lokaler Cache

    private func fetchCatalog(for category: Category) async -> [FujiFirmwareEntry]? {
        let now = Date()

        if let mem = memoryCache[category], now.timeIntervalSince(mem.fetchedAt) < cacheTTL {
            return mem.entries
        }
        if let disk = loadDiskCache(for: category), now.timeIntervalSince(disk.fetchedAt) < cacheTTL {
            memoryCache[category] = disk
            return disk.entries
        }

        var request = URLRequest(url: category.pageURL)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8) else {
                return nil
            }
            let entries = Self.parseSupportTableHTML(html)
            guard !entries.isEmpty else { return nil }

            let cached = CachedCatalog(fetchedAt: now, entries: entries)
            memoryCache[category] = cached
            saveDiskCache(cached, for: category)
            return entries
        } catch {
            return nil
        }
    }

    private func cacheFileURL(for category: Category) -> URL? {
        cacheDirectory?.appendingPathComponent("fujifilm-\(category.rawValue).json")
    }

    private func loadDiskCache(for category: Category) -> CachedCatalog? {
        guard let url = cacheFileURL(for: category),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(CachedCatalog.self, from: data)
    }

    private func saveDiskCache(_ cached: CachedCatalog, for category: Category) {
        guard let dir = cacheDirectory, let url = cacheFileURL(for: category) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cached) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - HTML-Parsing (deterministisch & testbar)

    /// Parst alle `<a href="..." class="support-table__row ...">`-Zeilen der offiziellen
    /// Fujifilm-Firmware-Uebersichtsseiten fuer Kameras und Objektive.
    public static func parseSupportTableHTML(_ html: String) -> [FujiFirmwareEntry] {
        let rowPattern = #"<a\s+href="([^"]+)"\s+class="support-table__row[^"]*"[^>]*>(.*?)</a>"#
        let namePattern = #"<span[^>]*class="font-semibold"[^>]*>(.*?)</span>"#
        let versionPattern = #"Ver\.?\s*([0-9]+(?:\.[0-9]+)+)"#

        guard let rowRegex = try? NSRegularExpression(pattern: rowPattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
              let nameRegex = try? NSRegularExpression(pattern: namePattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
              let versionRegex = try? NSRegularExpression(pattern: versionPattern, options: [.caseInsensitive]) else {
            return []
        }

        let nsHTML = html as NSString
        let fullRange = NSRange(location: 0, length: nsHTML.length)
        var results: [FujiFirmwareEntry] = []

        for match in rowRegex.matches(in: html, options: [], range: fullRange) {
            guard match.numberOfRanges >= 3 else { continue }
            let href = nsHTML.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let body = nsHTML.substring(with: match.range(at: 2))
            let nsBody = body as NSString
            let bodyRange = NSRange(location: 0, length: nsBody.length)

            guard let url = URL(string: href),
                  let nameMatch = nameRegex.firstMatch(in: body, options: [], range: bodyRange),
                  let verMatch = versionRegex.firstMatch(in: body, options: [], range: bodyRange) else {
                continue
            }

            let rawName = nsBody.substring(with: nameMatch.range(at: 1))
            let cleanName = stripHTMLTags(rawName).trimmingCharacters(in: .whitespacesAndNewlines)
            let version = nsBody.substring(with: verMatch.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)

            if !cleanName.isEmpty && !version.isEmpty {
                results.append(FujiFirmwareEntry(modelName: cleanName, latestVersion: version, downloadURL: url))
            }
        }

        return results
    }

    // MARK: - Modell-Matching & Versionsvergleich

    /// Erkennt, ob der ueber BLE gemeldete Objektivname ein Original-Fujifilm-Objektiv ist.
    public static func isFujifilmLensName(_ rawName: String) -> Bool {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let stripped = trimmed
            .replacingOccurrences(of: "FUJINON", with: "")
            .replacingOccurrences(of: "FUJIFILM", with: "")
            .replacingOccurrences(of: "LENS", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.hasPrefix("XF")
            || stripped.hasPrefix("XC")
            || stripped.hasPrefix("GF")
            || stripped.hasPrefix("MKX")
    }

    /// Ordnet einen BLE-Kameranamen (z. B. `"X-T4"`, `"FUJIFILM X-T4"`, `"FUJIFILM-X-T4-3A2B"`)
    /// eindeutig einem Eintrag der Fujifilm-Kameraliste zu.
    public static func matchCamera(modelName: String, in entries: [FujiFirmwareEntry]) -> FujiFirmwareEntry? {
        let cleaned = stripCameraBrandAndSerial(modelName)
        let normalizedTarget = normalizeAlphaNumeric(cleaned)
        guard !normalizedTarget.isEmpty else { return nil }

        // 1. Exakter normalisierter Treffer (verhindert Verwechslung wie X-T30 vs. X-T30 II)
        if let exact = entries.first(where: { normalizeAlphaNumeric($0.modelName) == normalizedTarget }) {
            return exact
        }

        // 2. Exakter Wortgrenzen-Treffer, sortiert nach laengstem Modellnamen zuerst
        let tokenizedInput = tokenizeUpper(cleaned)
        let sorted = entries.sorted { $0.modelName.count > $1.modelName.count }
        for entry in sorted {
            let entryTokens = tokenizeUpper(entry.modelName)
            guard !entryTokens.isEmpty, entryTokens.count <= tokenizedInput.count else { continue }
            if Array(tokenizedInput.prefix(entryTokens.count)) == entryTokens {
                let remainder = tokenizedInput.dropFirst(entryTokens.count)
                // Falls noch ein Modell-Suffix folgt (z. B. II, III, S, V, VI), nicht falsch zuordnen
                if let next = remainder.first, isModelVariantToken(next) {
                    continue
                }
                return entry
            }
        }

        return nil
    }

    /// Ordnet einen Fujifilm-Objektivnamen strikt einem Eintrag der Fujifilm-Objektivliste zu.
    /// Verwendet strenge Normalisierung, damit z. B. "XF23mmF1.4 R LM WR" nicht mit "XF23mmF1.4 R" verwechselt wird.
    public static func matchLens(lensName: String, in entries: [FujiFirmwareEntry]) -> FujiFirmwareEntry? {
        guard isFujifilmLensName(lensName) else { return nil }
        let targetKey = normalizeLensKey(lensName)
        guard !targetKey.isEmpty else { return nil }

        return entries.first { normalizeLensKey($0.modelName) == targetKey }
    }

    /// Vergleicht installierte und aktuelle Versionsnummer numerisch (z. B. "02.12" == "2.12").
    public static func compare(installed: String, against entry: FujiFirmwareEntry) -> FujiFirmwareStatus? {
        guard let installedParts = parseVersionComponents(installed),
              let latestParts = parseVersionComponents(entry.latestVersion) else {
            return nil
        }

        let maxCount = max(installedParts.count, latestParts.count)
        for idx in 0..<maxCount {
            let lhs = idx < installedParts.count ? installedParts[idx] : 0
            let rhs = idx < latestParts.count ? latestParts[idx] : 0
            if lhs < rhs {
                return .updateAvailable(
                    installedVersion: formatVersion(installedParts),
                    latestVersion: entry.latestVersion,
                    downloadURL: entry.downloadURL
                )
            } else if lhs > rhs {
                return .upToDate(latestVersion: entry.latestVersion, downloadURL: entry.downloadURL)
            }
        }

        return .upToDate(latestVersion: entry.latestVersion, downloadURL: entry.downloadURL)
    }

    // MARK: - Hilfsfunktionen

    public static func parseVersionComponents(_ raw: String) -> [Int]? {
        let pattern = #"([0-9]+(?:\.[0-9]+)+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(location: 0, length: (raw as NSString).length)) else {
            return nil
        }
        let versionSubstring = (raw as NSString).substring(with: match.range(at: 1))
        let parts = versionSubstring.split(separator: ".").compactMap { Int($0) }
        return parts.isEmpty ? nil : parts
    }

    private static func formatVersion(_ parts: [Int]) -> String {
        guard parts.count >= 2 else {
            return parts.map(String.init).joined(separator: ".")
        }
        let rest = parts.dropFirst().map { String(format: "%02d", $0) }
        return ([String(parts[0])] + rest).joined(separator: ".")
    }

    private static func stripHTMLTags(_ input: String) -> String {
        let withoutTags = input.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return withoutTags
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    private static func stripCameraBrandAndSerial(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Klammer-Zusatz entfernen, z. B. "X-T4 (1234)"
        value = value.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
        // Fuehrendes FUJIFILM entfernen
        value = value.replacingOccurrences(of: #"^(?i)FUJIFILM[\s\-_]*"#, with: "", options: .regularExpression)
        // Optionales 4-stelliges Hex-/Geraete-Suffix wie "-3A2B" entfernen
        value = value.replacingOccurrences(of: #"[\s\-_][0-9A-Fa-f]{4}$"#, with: "", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeAlphaNumeric(_ raw: String) -> String {
        raw.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func normalizeLensKey(_ raw: String) -> String {
        var value = raw.uppercased()
        value = value.replacingOccurrences(of: "FUJINON", with: "")
        value = value.replacingOccurrences(of: "FUJIFILM", with: "")
        value = value.replacingOccurrences(of: "LENS", with: "")
        // Blendenangaben wie "F4.0" -> "F4" oder "F2.80" -> "F2.8" vereinheitlichen
        value = value.replacingOccurrences(of: #"(\d)\.0(?![0-9])"#, with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(\d\.\d)0(?![0-9])"#, with: "$1", options: .regularExpression)
        return value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func tokenizeUpper(_ raw: String) -> [String] {
        raw.uppercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func isModelVariantToken(_ token: String) -> Bool {
        let variants: Set<String> = ["II", "III", "IV", "V", "VI", "S", "R", "RF", "F", "T", "H", "E", "PRO", "HALF"]
        return variants.contains(token) || token.allSatisfy(\.isNumber)
    }
}

import Foundation
import FujiCore

/// Mac-Diagnose- und Machbarkeitstool fuer die Fujifilm X-T4 (Phase 1).
@main
struct FujiProbeCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            printUsage()
            return
        }

        let options = ParsedOptions(args: Array(args.dropFirst()))

        do {
            switch command {
            case "ble-scan":
                try await runBLEScan(options: options)
            case "ble-wifi":
                try await runBLEWiFi(options: options)
            case "probe":
                try runProbe(options: options)
            case "list":
                try runList(options: options)
            case "download":
                try runDownload(options: options)
            case "test-run":
                try runCombinedTest(options: options)
            case "help", "--help", "-h":
                printUsage()
            default:
                fputs("Unbekannter Befehl '\(command)'.\n\n", stderr)
                printUsage()
                exit(1)
            }
        } catch {
            fputs("\nFEHLER: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    // MARK: - BLE Commands

    private static func runBLEScan(options: ParsedOptions) async throws {
        let timeout = options.double("timeout") ?? 8.0
        let showAll = options.flag("all")

        let ble = FujiBLEManager { msg in
            print("[BLE] \(msg)")
        }
        let devices = try await ble.scanForCameras(durationSeconds: timeout, showAllNamed: showAll)

        if devices.isEmpty {
            print("\nKeine Fujifilm-Kamera gefunden.")
            print("Tipps:")
            print("  1) An der X-T4: Einrichtung -> Verbindungseinstellung -> Bluetooth/Smartphone -> Bluetooth EIN")
            print("  2) Fuer das erste Koppeln: 'Kopplungsregistrierung' starten")
            print("  3) Testweise alle BLE-Geraete anzeigen: fuji-probe ble-scan --all")
            return
        }

        print("\nGefundene Geraete (\(devices.count)):")
        for (i, d) in devices.enumerated() {
            print("  [\(i + 1)] \(d.name) | RSSI: \(d.rssi) dBm | ID: \(d.id.uuidString)")
            if let mfg = d.manufacturerDataHex {
                print("      Herstellerdaten: \(mfg)")
            }
            if let token = d.pairingTokenHex {
                print("      Pairing-Token:   \(token)  (Kopplungsmodus aktiv!)")
            }
            if !d.advertisedServices.isEmpty {
                print("      Services:        \(d.advertisedServices.joined(separator: ", "))")
            }
        }
    }

    private static func runBLEWiFi(options: ParsedOptions) async throws {
        let nameFilter = options.string("name")
        let token = options.string("token")
        let trigger = !options.flag("no-trigger")
        let timeout = options.double("timeout") ?? 8.0

        let ble = FujiBLEManager { msg in
            print("[BLE] \(msg)")
        }

        let result = try await ble.connectAndPrepareWiFi(
            nameFilter: nameFilter,
            clientName: "FujiTransferMac",
            savedTokenHex: token,
            triggerWiFi: trigger,
            scanSeconds: timeout
        )

        print("\n=== BLE Ergebnis ===")
        print("Kamera:          \(result.cameraName)")
        if let fw = result.firmwareVersion {
            print("Firmware:        \(fw)")
        }
        print("Pairing-Modus:   \(result.pairingMode)")
        if let tok = result.pairingTokenHex {
            print("Pairing-Token:   \(tok)  (fuer spaetere Nutzung merken)")
        }
        print("WLAN-SSID:       \(result.ssid.isEmpty ? "(nicht ausgelesen)" : result.ssid)")
        print("WLAN-Passwort:   \(result.password ?? "(offen / nicht gesetzt)")")
        print("Verstecktes Netz:\(result.isHiddenNetwork ? " Ja" : " Nein")")
        print("WLAN-Status:     \(result.wifiReadyState)")

        if trigger && !result.ssid.isEmpty {
            print("\nNaechster Schritt:")
            print("  1) Verbinde deinen Mac mit dem WLAN '\(result.ssid)'")
            if let pw = result.password {
                print("     Passwort: \(pw)")
            }
            print("  2) Starte: swift run fuji-probe probe --mode auto")
        }
    }

    // MARK: - Wi-Fi PTP/IP Commands

    private static func runProbe(options: ParsedOptions) throws {
        let (client, info) = try connectWithAutoFallback(options: options)
        defer { client.disconnect() }

        printSessionInfo(info)
        print("\nMachbarkeits-Check erfolgreich! Du kannst jetzt Fotos auflisten oder testen:")
        print("  swift run fuji-probe list --limit 10 --mode \(info.effectiveMode.rawValue)")
        print("  swift run fuji-probe download --count 2 --thumb --mode \(info.effectiveMode.rawValue)")
    }

    private static func runList(options: ParsedOptions) throws {
        let limit = options.int("limit") ?? 20
        let offset = options.int("offset") ?? 0
        let cardSlot = options.int("card")

        let (client, initialInfo) = try connectWithAutoFallback(options: options)
        defer { client.disconnect() }

        var info = initialInfo
        if let cardSlot, cardSlot != info.activeCardID {
            print("Wechsle auf Kartenslot \(cardSlot)...")
            info = try client.switchCard(cardID: cardSlot)
        }

        printSessionInfo(info)
        let photos = try client.listPhotos(offset: offset, limit: limit)
        print("\n=== Fotos (zeige \(photos.count) von \(info.totalObjectCount)) ===")
        for p in photos {
            let sizeKB = Double(p.compressedSize) / 1024.0
            let sizeText = sizeKB >= 1024.0
                ? String(format: "%.2f MB", sizeKB / 1024.0)
                : String(format: "%.0f KB", sizeKB)
            print(
                String(
                    format: "  [%3d] Handle %-6u | %-14s | %-6s | %4ux%-4u | %8s | %s",
                    p.index,
                    p.handle,
                    (p.filename as NSString).utf8String!,
                    (p.formatLabel as NSString).utf8String!,
                    p.width,
                    p.height,
                    (sizeText as NSString).utf8String!,
                    (p.dateCreated as NSString).utf8String!
                )
            )
        }
    }

    private static func runDownload(options: ParsedOptions) throws {
        let count = options.int("count") ?? 1
        let specificHandle = options.int("handle").map { UInt32($0) }
        let includeThumb = options.flag("thumb")
        let compress = options.flag("compress")
        let outDir = URL(fileURLWithPath: options.string("out") ?? "./downloads")

        let (client, info) = try connectWithAutoFallback(options: options)
        defer { client.disconnect() }

        printSessionInfo(info)

        let handles: [UInt32]
        if let specificHandle {
            handles = [specificHandle]
        } else {
            let photos = try client.listPhotos(offset: 0, limit: count)
            handles = photos.map(\.handle)
        }

        guard !handles.isEmpty else {
            print("Keine Dateien zum Herunterladen gefunden.")
            return
        }

        print("\nSpeichere nach: \(outDir.path)")
        print("Komprimierung:  \(compress ? "Smartphone-Vorschau (klein)" : "Volle Original-Aufloesung")")

        for handle in handles {
            try downloadSingle(
                client: client,
                handle: handle,
                includeThumb: includeThumb,
                compress: compress,
                outDir: outDir
            )
        }
    }

    /// Fuehrt Probe + Liste + Download in EINER offenen Session aus, damit die X-T4
    /// das WLAN nicht zwischen zwei CLI-Aufrufen abschaltet.
    private static func runCombinedTest(options: ParsedOptions) throws {
        let listLimit = options.int("limit") ?? 10
        let downloadCount = options.int("count") ?? 2
        let includeThumb = !options.flag("no-thumb")
        let compress = options.flag("compress")
        let outDir = URL(fileURLWithPath: options.string("out") ?? "./downloads")

        let (client, info) = try connectWithAutoFallback(options: options)
        defer { client.disconnect() }

        printSessionInfo(info)

        let photos = try client.listPhotos(offset: 0, limit: max(listLimit, downloadCount))
        print("\n=== Fotos (zeige \(min(photos.count, listLimit)) von \(info.totalObjectCount)) ===")
        for p in photos.prefix(listLimit) {
            print(
                String(
                    format: "  [%3d] Handle %-6u | %-14s | %-6s | %4ux%-4u | %s",
                    p.index,
                    p.handle,
                    (p.filename as NSString).utf8String!,
                    (p.formatLabel as NSString).utf8String!,
                    p.width,
                    p.height,
                    (p.dateCreated as NSString).utf8String!
                )
            )
        }

        let toDownload = Array(photos.prefix(downloadCount))
        guard !toDownload.isEmpty else {
            print("\nKeine Fotos zum Herunterladen gefunden.")
            return
        }

        print("\n=== Test-Download (\(toDownload.count) Foto(s)) nach \(outDir.path) ===")
        for photo in toDownload {
            try downloadSingle(
                client: client,
                handle: photo.handle,
                includeThumb: includeThumb,
                compress: compress,
                outDir: outDir
            )
        }
    }

    private static func downloadSingle(
        client: FujiWiFiClient,
        handle: UInt32,
        includeThumb: Bool,
        compress: Bool,
        outDir: URL
    ) throws {
        if includeThumb {
            let thumbStart = Date()
            do {
                let thumbData = try client.fetchThumbnail(handle: handle)
                let thumbMs = Int(Date().timeIntervalSince(thumbStart) * 1000)
                try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
                let thumbURL = outDir.appendingPathComponent("thumb_\(handle).jpg")
                try thumbData.write(to: thumbURL)
                print("  [Thumb] Handle \(handle): \(thumbData.count) Bytes in \(thumbMs) ms -> \(thumbURL.lastPathComponent)")
            } catch {
                print("  [Thumb] Handle \(handle) uebersprungen: \(error.localizedDescription)")
            }
        }

        print("  [Foto]  Starte Download fuer Handle \(handle)...")
        let result = try client.downloadPhoto(
            handle: handle,
            toDirectory: outDir,
            compressForSmartphone: compress
        ) { received, total in
            let pct = total > 0 ? Int((Double(received) / Double(total)) * 100.0) : 0
            let mb = Double(received) / (1024.0 * 1024.0)
            print(String(format: "          Fortschritt: %3d%% (%.2f MB)", pct, mb))
        }

        let okMarker = (result.validJPEGHeader && result.validJPEGFooter)
            ? "OK (JPEG valide)"
            : "Hinweis: Kein Standard-JPEG-Header/Footer"
        print(
            String(
                format: "  [Fertig] %@ | %.2f MB in %.2fs (%.2f MB/s) | %@",
                result.filename,
                Double(result.bytesWritten) / (1024.0 * 1024.0),
                result.durationSeconds,
                result.megabytesPerSecond,
                okMarker
            )
        )
    }

    // MARK: - Connection helper

    private static func connectWithAutoFallback(options: ParsedOptions) throws -> (FujiWiFiClient, FujiSessionInfo) {
        let host = options.string("host") ?? "192.168.0.1"
        let port = Int32(options.int("port") ?? 55740)
        let modeArg = (options.string("mode") ?? "auto").lowercased()
        let iface = options.string("interface")
        let verbose = options.flag("verbose")

        let modesToTry: [FujiTransportMode]
        switch modeArg {
        case "xapp":
            modesToTry = [.xapp]
        case "wireless":
            modesToTry = [.wirelessComm]
        default:
            // X-T4 ab Firmware 2.00 nutzt haeufig XApp-Modus, aeltere/manuelle Verbindungen WirelessComm
            modesToTry = [.xapp, .wirelessComm]
        }

        var lastError: Error?
        for mode in modesToTry {
            print("Verbinde zu \(host):\(port) im Modus '\(mode.rawValue)'...")
            let client = FujiWiFiClient(verbose: verbose) { level, msg in
                if verbose || level != "DBG" {
                    print("[\(level)] \(msg)")
                }
            }
            if let iface {
                client.setNetworkInterface(iface)
            }
            do {
                let info = try client.connect(host: host, port: port, mode: mode)
                return (client, info)
            } catch {
                lastError = error
                client.disconnect()
                if modesToTry.count > 1 {
                    print("Modus '\(mode.rawValue)' fehlgeschlagen (\(error.localizedDescription)) -> probiere naechsten Modus...")
                }
            }
        }
        throw lastError ?? FujiError.notConnected
    }

    private static func printSessionInfo(_ info: FujiSessionInfo) {
        print("\n=== Kamera-Verbindung ===")
        print("Kamera:             \(info.cameraName.isEmpty ? "(unbekannt)" : info.cameraName)")
        print("Aktiver Modus:      \(info.effectiveMode.rawValue)")
        print("CameraState (DF00): \(info.cameraState)")
        print(String(format: "RemoteVersion:      0x%X", info.remoteVersion))
        print(String(format: "ImgViewVersion:     0x%X (Ex: 0x%X)", info.remoteImageViewVersion, info.remoteImageViewExVersion))
        print("Aktiver Slot:       \(info.activeCardID == 0 ? "Standard" : "Slot \(info.activeCardID)")")
        print("Objekte verfuegbar: \(info.totalObjectCount) (\(info.hasExplicitHandleList ? "XApp-Handle-Liste" : "Index-basiert"))")
        for card in info.cards {
            print("  - \(card.name) (ID \(card.id)): \(card.objectCount) Objekte")
        }
    }

    private static func printUsage() {
        print("""
        fuji-probe – Machbarkeits-Test fuer Fujifilm X-T4 (BLE + WLAN PTP/IP)

        BEFEHLE:
          ble-scan   [--timeout 8] [--all]
                     Sucht nach der X-T4 per Bluetooth LE und zeigt Token/Services.

          ble-wifi   [--name X-T4] [--token HEX] [--no-trigger] [--timeout 8]
                     Koppelt per BLE, liest WLAN-SSID & Passwort aus und startet den Hotspot.

          probe      [--host 192.168.0.1] [--mode auto|xapp|wireless] [--interface en0] [--verbose]
                     Prueft den WLAN-PTP/IP-Handshake, Protokollversion und SD-Kartenslots.

          list       [--limit 20] [--offset 0] [--card 1|2] [--mode auto|xapp|wireless] [--verbose]
                     Listet Fotos auf der SD-Karte mit Handle, Dateiname, Groesse und Aufloesung.

          download   [--count 1 | --handle H] [--thumb] [--compress] [--out ./downloads] [--mode ...] [--verbose]
                     Laedt Thumbnails und/oder Original-JPEGs herunter und misst MB/s + Integritaet.

          test-run   [--limit 10] [--count 2] [--out ./downloads] [--mode xapp|auto]
                     Fuehrt Probe + Liste + Thumbnail/JPEG-Download in EINER offenen Verbindung aus.
        """)
    }
}

/// Einfacher CLI-Argument-Parser ohne externe Paket-Abhaengigkeiten.
private struct ParsedOptions {
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    init(args: [String]) {
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg.hasPrefix("--") {
                let key = String(arg.dropFirst(2))
                if i + 1 < args.count && !args[i + 1].hasPrefix("--") {
                    values[key] = args[i + 1]
                    i += 2
                } else {
                    flags.insert(key)
                    i += 1
                }
            } else {
                i += 1
            }
        }
    }

    func string(_ key: String) -> String? { values[key] }
    func int(_ key: String) -> Int? { values[key].flatMap(Int.init) }
    func double(_ key: String) -> Double? { values[key].flatMap(Double.init) }
    func flag(_ key: String) -> Bool { flags.contains(key) || values[key] == "true" }
}

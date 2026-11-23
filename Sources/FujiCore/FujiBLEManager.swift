import Foundation
@preconcurrency import CoreBluetooth

/// CoreBluetooth-Manager zum Scannen, Koppeln und Ausloesen des Kamera-WLANs
/// (funktioniert identisch auf macOS und iOS).
/// Alle veraenderlichen Zustaende werden ausschliesslich seriell ueber `queue` angesprochen.
public final class FujiBLEManager: NSObject, @unchecked Sendable {
    public typealias LogHandler = @Sendable (String) -> Void

    private let queue = DispatchQueue(label: "fuji.ble.manager")
    internal let log: LogHandler
    private var central: CBCentralManager!

    internal var powerStateContinuation: CheckedContinuation<CBManagerState, Never>?
    internal var scanResults: [UUID: (peripheral: CBPeripheral, device: FujiBLEDevice)] = [:]
    internal var fastFindFilter: String?
    internal var fastFindContinuation: CheckedContinuation<(CBPeripheral, FujiBLEDevice), Error>?

    // Aktive Verbindungs-Continuations
    internal var connectContinuation: CheckedContinuation<CBPeripheral, Error>?
    internal var disconnectContinuation: CheckedContinuation<Void, Never>?
    internal var servicesContinuation: CheckedContinuation<[CBService], Error>?
    internal var charsContinuation: CheckedContinuation<[CBCharacteristic], Error>?
    internal var readContinuations: [CBUUID: CheckedContinuation<Data, Error>] = [:]
    internal var writeContinuations: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    internal var notifyContinuations: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    internal var ind1Continuation: CheckedContinuation<Data, Error>?
    internal var timeSyncCharacteristic: CBCharacteristic?

    public init(onLog: @escaping LogHandler = { _ in }) {
        self.log = onLog
        super.init()
        self.central = CBCentralManager(delegate: self, queue: queue)
    }

    /// Wartet bis Bluetooth eingeschaltet und autorisiert ist.
    public func waitUntilPoweredOn(timeoutSeconds: Double = 8.0) async throws {
        let state: CBManagerState = await withCheckedContinuation { cont in
            queue.async {
                if self.central.state != .unknown && self.central.state != .resetting {
                    cont.resume(returning: self.central.state)
                } else {
                    self.powerStateContinuation = cont
                }
            }
        }
        switch state {
        case .poweredOn:
            return
        case .unauthorized:
            throw FujiError.bleUnavailable(
                "Bluetooth-Zugriff nicht erlaubt. Bitte unter Systemeinstellungen -> Datenschutz & Sicherheit -> Bluetooth fuer das Terminal freigeben."
            )
        case .poweredOff:
            throw FujiError.bleUnavailable("Bluetooth ist ausgeschaltet.")
        case .unsupported:
            throw FujiError.bleUnavailable("Dieses Geraet unterstuetzt kein Bluetooth LE.")
        default:
            throw FujiError.bleUnavailable("Bluetooth-Status: \(state.rawValue)")
        }
    }

    /// Scannt fuer `durationSeconds` nach Fujifilm-Kameras in der Umgebung.
    public func scanForCameras(durationSeconds: Double = 8.0, showAllNamed: Bool = false) async throws -> [FujiBLEDevice] {
        try await waitUntilPoweredOn()

        queue.sync {
            self.scanResults.removeAll()
            self.central.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
        }
        log("BLE-Scan gestartet (\(Int(durationSeconds))s)...")

        try await Task.sleep(nanoseconds: UInt64(durationSeconds * 1_000_000_000))

        let devices: [FujiBLEDevice] = queue.sync {
            self.central.stopScan()
            return self.scanResults.values.map(\.device).sorted { $0.rssi > $1.rssi }
        }

        if showAllNamed {
            return devices
        }
        return devices.filter { isLikelyFujifilm($0) }
    }

    /// Verbindet sofort nach Fund mit der ersten passenden Fujifilm-Kamera, fuehrt Pairing aus,
    /// liest WLAN-SSID + Passwort aus und startet optional den Kamera-Hotspot.
    public func connectAndPrepareWiFi(
        nameFilter: String? = nil,
        clientName: String = "FujiTransfer",
        savedTokenHex: String? = nil,
        triggerWiFi: Bool = true,
        scanSeconds: Double = 10.0
    ) async throws -> FujiBLEWiFiResult {
        try await waitUntilPoweredOn()

        log("Suche Fujifilm-Kamera per BLE (max. \(Int(scanSeconds))s)...")
        let (peripheral, target) = try await findFirstCamera(nameFilter: nameFilter, timeoutSeconds: scanSeconds)

        log("Verbinde per BLE mit '\(target.name)' (RSSI \(target.rssi) dBm)...")
        let connectedPeripheral = try await connect(peripheral: peripheral, timeoutSeconds: 10.0)
        do {
            let result = try await runConnectedWiFiPrep(
                connectedPeripheral: connectedPeripheral,
                target: target,
                clientName: clientName,
                savedTokenHex: savedTokenHex,
                triggerWiFi: triggerWiFi
            )
            await disconnectAndWait(peripheral: connectedPeripheral)
            return result
        } catch {
            await disconnectAndWait(peripheral: connectedPeripheral)
            throw error
        }
    }

    private func runConnectedWiFiPrep(
        connectedPeripheral: CBPeripheral,
        target: FujiBLEDevice,
        clientName: String,
        savedTokenHex: String?,
        triggerWiFi: Bool
    ) async throws -> FujiBLEWiFiResult {
        log("Lese GATT-Services...")
        let services = try await discoverServices(on: connectedPeripheral)
        var charMap: [CBUUID: CBCharacteristic] = [:]
        for service in services {
            let chars = try await discoverCharacteristics(for: service, on: connectedPeripheral)
            for ch in chars {
                charMap[ch.uuid] = ch
            }
        }
        log("Gefundene GATT-Services: \(services.count), Characteristics: \(charMap.count)")

        // 1) Pairing-Modus erkennen (Legacy vs. Secure XApp)
        let pairingMode: String
        let usedTokenHex = savedTokenHex ?? target.pairingTokenHex

        if let pairTokenChar = charMap[FujiBLEUUIDs.legacyPairTokenChar] {
            pairingMode = "Legacy BLE Pairing"
            guard let tokenHex = usedTokenHex, let tokenData = dataFromHex(tokenHex), tokenData.count == 4 else {
                throw FujiError.bleError(
                    "Legacy-Pairing erfordert ein 4-Byte Pairing-Token (Kamera in Bluetooth-Kopplungsmodus versetzen oder --token angeben)."
                )
            }
            log("Sende Legacy Pairing-Token (\(tokenHex))...")
            try await writeValue(tokenData, to: pairTokenChar, on: connectedPeripheral)
            if let idenChar = charMap[FujiBLEUUIDs.clientNameChar] {
                try await writeValue(Data(clientName.utf8), to: idenChar, on: connectedPeripheral)
            }
        } else if let secureStatusChar = charMap[FujiBLEUUIDs.secureStatusChar] {
            pairingMode = "Secure XApp BLE Pairing"
            log("Lese Secure-Pairing-Status (geloest ueber macOS/iOS BLE-Bonding)...")
            var status = try await readValue(from: secureStatusChar, on: connectedPeripheral)
            log("Secure-Status gelesen: \(hexString(status))")
            if status.count >= 4 {
                status[3] = 0x20
                try await writeValue(status, to: secureStatusChar, on: connectedPeripheral)
                log("Secure-Pairing-ACK gesendet.")
            }
            if let idenChar = charMap[FujiBLEUUIDs.clientNameChar] {
                try await writeValue(Data(clientName.utf8), to: idenChar, on: connectedPeripheral)
            }
        } else {
            pairingMode = "Unbekannt / bereits gekoppelt"
            log("Hinweis: Weder Legacy- noch Secure-Pairing-Service gefunden; versuche direktes Auslesen.")
        }

        // 2) Kamera-Infos + WLAN SSID & Passwort auslesen
        var cameraName = target.name
        if let nameChar = charMap[FujiBLEUUIDs.deviceNameChar],
           let nameData = try? await readValue(from: nameChar, on: connectedPeripheral),
           let parsed = cleanUTF8String(nameData), !parsed.isEmpty {
            cameraName = parsed
        }

        var firmwareVersion: String?
        if let fwChar = charMap[FujiBLEUUIDs.firmwareRevChar],
           let fwData = try? await readValue(from: fwChar, on: connectedPeripheral) {
            firmwareVersion = cleanUTF8String(fwData)
        }

        var ssid = ""
        if let ssidChar = charMap[FujiBLEUUIDs.wifiSSIDChar] {
            let ssidData = try await readValue(from: ssidChar, on: connectedPeripheral)
            ssid = cleanUTF8String(ssidData) ?? ""
            log("Kamera WLAN-SSID: '\(ssid)'")
        }

        var password: String?
        var isHidden = false
        if let pwChar = charMap[FujiBLEUUIDs.wifiPasswordChar],
           let pwData = try? await readValue(from: pwChar, on: connectedPeripheral),
           let pwText = cleanUTF8String(pwData), !pwText.isEmpty {
            password = pwText
            isHidden = true
            log("Kamera WLAN-Passwort ausgelesen (\(pwText.count) Zeichen).")
        }

        queue.sync {
            self.timeSyncCharacteristic = charMap[FujiBLEUUIDs.timeChar]
        }

        // 2b) Fujifilm-Notifications synchron abonnieren (auf Bestaetigung warten, damit die X-T4 das Pairing speichert!)
        let subscribeUUIDs: [CBUUID] = [
            FujiBLEUUIDs.wifiSSIDChar,
            FujiBLEUUIDs.ind1Char,
            FujiBLEUUIDs.ind2Char,
            FujiBLEUUIDs.not1Char,
            FujiBLEUUIDs.geotagUpdateChar,
            FujiBLEUUIDs.ind3Char,
            FujiBLEUUIDs.wifiStatusNot9Char
        ]
        var subscribedCount = 0
        for uuid in subscribeUUIDs {
            if let ch = charMap[uuid],
               ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                do {
                    try await setNotify(true, for: ch, on: connectedPeripheral, timeoutSeconds: 3.0)
                    subscribedCount += 1
                } catch {
                    log("Hinweis Subscription \(uuid): \(error.localizedDescription)")
                }
            }
        }
        log("BLE-Subscriptions aktiv: \(subscribedCount)/\(subscribeUUIDs.count)")

        // Bei reinem Pairing (--no-trigger) Verbindung kurz offen halten, damit die X-T4 das Geraet speichert
        if !triggerWiFi {
            log("Halte BLE-Verbindung kurz offen, damit die X-T4 das Kopplungsziel speichert...")
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }

        // 3) Optional: Kamera-WLAN-Hotspot per BLE starten (wie XApp)
        var wifiReadyState = "Nicht ausgeloest"
        if triggerWiFi {
            if let shutterChar = charMap[FujiBLEUUIDs.shutterChar] {
                try? await writeValue(Data([0x01, 0x00]), to: shutterChar, on: connectedPeripheral, timeoutSeconds: 2.0)
                try? await writeValue(Data([0x00, 0x00]), to: shutterChar, on: connectedPeripheral, timeoutSeconds: 2.0)
            }
            guard let triggerChar = charMap[FujiBLEUUIDs.wifiTriggerChar] else {
                throw FujiError.bleError("Wi-Fi-Trigger-Characteristic (\(FujiBLEUUIDs.wifiTriggerChar)) nicht gefunden.")
            }

            // 1s Pause wie in libfuji/bluetooth.c vor dem Wi-Fi-Trigger
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            // Auf X-T4 (FW 02.12) weckt 0x03 0x00 das Kamera-WLAN zuverlaessig auf; 0x04 0x00 als Fallback.
            let triggerPayloads: [(label: String, bytes: [UInt8])] = [
                ("0x03 0x00 (X-T4 WLAN)", [0x03, 0x00]),
                ("0x04 0x00 (XApp)", [0x04, 0x00])
            ]

            var started = false
            for candidate in triggerPayloads {
                log("Sende Wi-Fi-Startbefehl \(candidate.label)...")
                do {
                    try await writeValue(Data(candidate.bytes), to: triggerChar, on: connectedPeripheral, timeoutSeconds: 5.0)
                    log("Wi-Fi-Startbefehl \(candidate.label) bestaetigt.")
                } catch {
                    log("Hinweis bei \(candidate.label): \(error.localizedDescription)")
                    continue
                }

                // Bei 0x03 0x00 sendet die X-T4 nicht immer IND1 01/02, startet das WLAN aber sofort.
                if candidate.bytes == [0x03, 0x00] {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    wifiReadyState = "WLAN-Startbefehl (0x03 0x00) gesendet – '\(ssid)' sollte jetzt aktiv sein."
                    started = true
                    break
                }

                if let indData = await waitForNonZeroIND1(timeoutSeconds: 4.0) {
                    let hex = hexString(indData)
                    if indData.first == 0x01 || indData.first == 0x02 {
                        wifiReadyState = "Kamera-Hotspot aktiv (IND1=\(hex))"
                        started = true
                        break
                    }
                }
            }

            if !started {
                wifiReadyState = "Trigger gesendet – pruefe, ob WLAN '\(ssid)' aktiv ist"
            }
        }

        return FujiBLEWiFiResult(
            cameraName: cameraName,
            firmwareVersion: firmwareVersion,
            pairingMode: pairingMode,
            pairingTokenHex: usedTokenHex,
            ssid: ssid,
            password: password,
            isHiddenNetwork: isHidden,
            wifiTriggered: triggerWiFi,
            wifiReadyState: wifiReadyState
        )
    }

    // MARK: - Async CoreBluetooth wrappers

    private func disconnectAndWait(peripheral: CBPeripheral, timeoutSeconds: Double = 2.0) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                guard peripheral.state == .connected || peripheral.state == .connecting else {
                    cont.resume()
                    return
                }
                self.disconnectContinuation = cont
                self.central.cancelPeripheralConnection(peripheral)
                self.queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                    if let pending = self.disconnectContinuation {
                        self.disconnectContinuation = nil
                        pending.resume()
                    }
                }
            }
        }
    }

    private func findFirstCamera(
        nameFilter: String?,
        timeoutSeconds: Double
    ) async throws -> (CBPeripheral, FujiBLEDevice) {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.scanResults.removeAll()
                self.fastFindFilter = nameFilter?.lowercased()
                self.fastFindContinuation = cont
                self.central.scanForPeripherals(
                    withServices: nil,
                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
                )
                self.queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                    if let pending = self.fastFindContinuation {
                        self.fastFindContinuation = nil
                        self.central.stopScan()
                        pending.resume(throwing: FujiError.bleTimeout(
                            "Keine Fujifilm-Kamera per Bluetooth gefunden. Ist Bluetooth an der X-T4 aktiv (und nicht vom iPhone blockiert)?"
                        ))
                    }
                }
            }
        }
    }

    private func connect(peripheral: CBPeripheral, timeoutSeconds: Double = 10.0) async throws -> CBPeripheral {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                peripheral.delegate = self
                self.connectContinuation = cont
                self.central.connect(peripheral, options: nil)
                self.queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                    if let pending = self.connectContinuation {
                        self.connectContinuation = nil
                        self.central.cancelPeripheralConnection(peripheral)
                        pending.resume(throwing: FujiError.bleTimeout(
                            "BLE-Verbindungsaufbau zur Kamera hat nicht geantwortet (Timeout \(Int(timeoutSeconds))s). Pruefe an der X-T4 unter 'Kopplungsziel auswaehlen', ob FujiTransferMac aktiv ist."
                        ))
                    }
                }
            }
        }
    }

    private func discoverServices(on peripheral: CBPeripheral) async throws -> [CBService] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.servicesContinuation = cont
                peripheral.discoverServices(nil)
            }
        }
    }

    private func discoverCharacteristics(for service: CBService, on peripheral: CBPeripheral) async throws -> [CBCharacteristic] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.charsContinuation = cont
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    private func readValue(
        from char: CBCharacteristic,
        on peripheral: CBPeripheral,
        timeoutSeconds: Double = 5.0
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.readContinuations[char.uuid] = cont
                peripheral.readValue(for: char)
                self.queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                    if let pending = self.readContinuations.removeValue(forKey: char.uuid) {
                        pending.resume(throwing: FujiError.bleTimeout("Timeout beim Lesen von \(char.uuid)"))
                    }
                }
            }
        }
    }

    private func writeValue(
        _ data: Data,
        to char: CBCharacteristic,
        on peripheral: CBPeripheral,
        timeoutSeconds: Double = 5.0
    ) async throws {
        let writeType: CBCharacteristicWriteType = char.properties.contains(.write) ? .withResponse : .withoutResponse
        if writeType == .withoutResponse {
            queue.async { peripheral.writeValue(data, for: char, type: .withoutResponse) }
            return
        }
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.writeContinuations[char.uuid] = cont
                peripheral.writeValue(data, for: char, type: .withResponse)
                self.queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                    if let pending = self.writeContinuations.removeValue(forKey: char.uuid) {
                        pending.resume(throwing: FujiError.bleTimeout("Timeout beim Schreiben von \(char.uuid)"))
                    }
                }
            }
        }
    }

    private func setNotify(
        _ enabled: Bool,
        for char: CBCharacteristic,
        on peripheral: CBPeripheral,
        timeoutSeconds: Double = 3.0
    ) async throws {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.notifyContinuations[char.uuid] = cont
                peripheral.setNotifyValue(enabled, for: char)
                self.queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                    if let pending = self.notifyContinuations.removeValue(forKey: char.uuid) {
                        pending.resume(throwing: FujiError.bleTimeout("Timeout bei Subscription \(char.uuid)"))
                    }
                }
            }
        }
    }

    private func waitForNonZeroIND1(timeoutSeconds: Double) async -> Data? {
        try? await withCheckedThrowingContinuation { cont in
            queue.async {
                self.ind1Continuation = cont
                self.queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                    if let pending = self.ind1Continuation {
                        self.ind1Continuation = nil
                        pending.resume(throwing: FujiError.bleTimeout("Kein aktives IND1-Event"))
                    }
                }
            }
        }
    }

    internal func isLikelyFujifilm(_ device: FujiBLEDevice) -> Bool {
        let upper = device.name.uppercased()
        if upper.contains("FUJI") || upper.contains("X-T") || upper.contains("X-H")
            || upper.contains("X-S") || upper.contains("X-E") || upper.contains("X-PRO")
            || upper.contains("X100") || upper.contains("GFX") {
            return true
        }
        let knownServices: Set<String> = [
            FujiBLEUUIDs.legacyPairService.uuidString.lowercased(),
            FujiBLEUUIDs.securePairService.uuidString.lowercased(),
            FujiBLEUUIDs.xappService.uuidString.lowercased(),
            FujiBLEUUIDs.filesService.uuidString.lowercased(),
            FujiBLEUUIDs.wifiInfoService.uuidString.lowercased()
        ]
        if device.advertisedServices.contains(where: { knownServices.contains($0.lowercased()) }) {
            return true
        }
        // Fujifilm Manufacturer Company ID 0x04D8 (Little Endian: d8 04)
        if let mfg = device.manufacturerDataHex?.lowercased(), mfg.hasPrefix("d804") {
            return true
        }
        return false
    }
}

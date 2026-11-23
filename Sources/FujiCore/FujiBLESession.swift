import Foundation
@preconcurrency import CoreBluetooth

/// Dauerhafte Bluetooth-LE-Verbindung zur Fujifilm-Kamera fuer:
/// - Fernausloeser (Fokus, Ausloesen, Bulb, Intervallometer)
/// - Automatisches & manuelles GPS-Geotagging
/// - Objektiv- & Kamera-Firmware-Auslesung
/// - Kamera-Backup / Status-Download ueber BLE
/// - Direktes Aufwecken des Kamera-WLANs (0x03 0x00)
///
/// Alle veraenderlichen Zustaende laufen strikt seriell ueber `queue`.
public final class FujiBLESession: NSObject, @unchecked Sendable {
    public typealias LogHandler = @Sendable (String) -> Void
    public typealias EventHandler = @Sendable () -> Void
    public typealias DisconnectHandler = @Sendable (String?) -> Void

    private let queue = DispatchQueue(label: "fuji.ble.session")
    private let log: LogHandler
    private var central: CBCentralManager!

    private var powerStateContinuation: CheckedContinuation<CBManagerState, Never>?
    private var findContinuation: CheckedContinuation<(CBPeripheral, String?), Error>?
    private var connectContinuation: CheckedContinuation<CBPeripheral, Error>?
    private var disconnectContinuation: CheckedContinuation<Void, Never>?
    private var servicesContinuation: CheckedContinuation<[CBService], Error>?
    private var charsContinuation: CheckedContinuation<[CBCharacteristic], Error>?
    private var readContinuations: [CBUUID: CheckedContinuation<Data, Error>] = [:]
    private var writeContinuations: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    private var notifyContinuations: [CBUUID: CheckedContinuation<Void, Error>] = [:]

    private var activePeripheral: CBPeripheral?
    private var charMap: [CBUUID: CBCharacteristic] = [:]

    public var onGeotagRequested: EventHandler?
    public var onTimeSynced: EventHandler?
    public var onDisconnected: DisconnectHandler?

    public init(onLog: @escaping LogHandler = { _ in }) {
        self.log = onLog
        super.init()
        self.central = CBCentralManager(delegate: self, queue: queue)
    }

    public var isConnected: Bool {
        queue.sync { activePeripheral?.state == .connected }
    }

    // MARK: - Verbinden & Trennen

    /// Verbindet dauerhaft per BLE mit der X-T4, authentifiziert sich mit dem gespeicherten
    /// 4-Byte-Token und liest Kamera- & Objektiv-Infos aus.
    public func connect(
        savedTokenHex: String?,
        clientName: String = "FujiTransfer",
        scanSeconds: Double = 10.0
    ) async throws -> FujiBLECameraStatus {
        try await waitUntilPoweredOn()

        log("Suche X-T4 per Bluetooth LE (max. \(Int(scanSeconds))s)...")
        let (peripheral, advertisedToken) = try await findFirstFujiCamera(timeoutSeconds: scanSeconds)

        log("Verbinde dauerhaft mit '\(peripheral.name ?? "X-T4")'...")
        let connected = try await connectPeripheral(peripheral, timeoutSeconds: 10.0)

        let services = try await discoverServices(on: connected)
        var discovered: [CBUUID: CBCharacteristic] = [:]
        for service in services {
            let chars = try await discoverCharacteristics(for: service, on: connected)
            for ch in chars {
                discovered[ch.uuid] = ch
            }
        }
        queue.sync {
            self.activePeripheral = connected
            self.charMap = discovered
        }
        log("BLE bereit: \(services.count) Services, \(discovered.count) Characteristics.")

        // Authentifizieren (Legacy Token oder Secure Pairing)
        let tokenHex = (savedTokenHex?.isEmpty == false) ? savedTokenHex : advertisedToken
        if let pairChar = discovered[FujiBLEUUIDs.legacyPairTokenChar] {
            guard let hex = tokenHex, let tokenData = dataFromHex(hex), tokenData.count == 4 else {
                disconnect()
                throw FujiError.bleError("Kein gueltiges Pairing-Token gespeichert. Bitte zuerst im Tab 'Fotos' koppeln.")
            }
            try await writeValue(tokenData, to: pairChar, on: connected, timeoutSeconds: 5.0)
            if let idenChar = discovered[FujiBLEUUIDs.clientNameChar] {
                try await writeValue(Data(clientName.utf8), to: idenChar, on: connected, timeoutSeconds: 5.0)
            }
        } else if let secureChar = discovered[FujiBLEUUIDs.secureStatusChar] {
            var status = try await readValue(from: secureChar, on: connected, timeoutSeconds: 5.0)
            if status.count >= 4 {
                status[3] = 0x20
                try await writeValue(status, to: secureChar, on: connected, timeoutSeconds: 5.0)
            }
            if let idenChar = discovered[FujiBLEUUIDs.clientNameChar] {
                try await writeValue(Data(clientName.utf8), to: idenChar, on: connected, timeoutSeconds: 5.0)
            }
        }

        // Kamera-, Objektiv- & WLAN-Infos auslesen
        let camName = await readString(FujiBLEUUIDs.deviceNameChar, on: connected) ?? peripheral.name ?? "X-T4"
        let fwVer = await readString(FujiBLEUUIDs.firmwareRevChar, on: connected)
        let lensName = await readString(FujiBLEUUIDs.lensNameChar, on: connected)
        let lensFw = await readString(FujiBLEUUIDs.lensFirmwareChar, on: connected)
        let ssid = await readString(FujiBLEUUIDs.wifiSSIDChar, on: connected)

        // Status-, Zeit- & Geotag-Subscriptions aktivieren
        let subUUIDs: [CBUUID] = [
            FujiBLEUUIDs.wifiSSIDChar,
            FujiBLEUUIDs.ind1Char,
            FujiBLEUUIDs.ind2Char,
            FujiBLEUUIDs.not1Char,
            FujiBLEUUIDs.geotagUpdateChar,
            FujiBLEUUIDs.ind3Char
        ]
        for uuid in subUUIDs {
            if let ch = discovered[uuid], ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                try? await setNotify(true, for: ch, on: connected, timeoutSeconds: 3.0)
            }
        }

        return FujiBLECameraStatus(
            cameraName: camName,
            firmwareVersion: fwVer,
            lensName: lensName,
            lensFirmwareVersion: lensFw,
            wifiSSID: ssid,
            supportsShutter: discovered[FujiBLEUUIDs.shutterChar] != nil,
            supportsGeotag: discovered[FujiBLEUUIDs.geotagChar] != nil,
            supportsFiles: discovered[FujiBLEUUIDs.filesFileInfoChar] != nil
        )
    }

    public func disconnect() {
        queue.async {
            if let p = self.activePeripheral {
                self.central.cancelPeripheralConnection(p)
            }
            self.activePeripheral = nil
            self.charMap.removeAll()
        }
    }

    /// Trennt BLE sauber und wartet auf `didDisconnectPeripheral`, damit iOS das HCI-Disconnect
    /// sofort an die X-T4 sendet (verhindert haengende BLE-Sessions beim Tab-Wechsel).
    public func disconnectAndWait(timeoutSeconds: Double = 2.0) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                guard let p = self.activePeripheral, p.state == .connected || p.state == .connecting else {
                    self.activePeripheral = nil
                    self.charMap.removeAll()
                    cont.resume()
                    return
                }
                self.disconnectContinuation = cont
                self.central.cancelPeripheralConnection(p)
                self.queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                    if let pending = self.disconnectContinuation {
                        self.disconnectContinuation = nil
                        self.activePeripheral = nil
                        self.charMap.removeAll()
                        pending.resume()
                    }
                }
            }
        }
    }

    // MARK: - Fernausloeser (Shutter / AF / Bulb)

    public func focusPress() async throws {
        try await sendShutterCommand(param: [0x03, 0x00])
        log("Autofokus (halb gedrueckt).")
    }

    public func shutterPress() async throws {
        try await sendShutterCommand(param: [0x02, 0x00])
        log("Ausloeser gedrueckt.")
    }

    public func shutterRelease() async throws {
        try await sendShutterCommand(param: [0x00, 0x00])
        log("Ausloeser losgelassen.")
    }

    /// Einmal sauber fokussieren, ausloesen und loslassen.
    public func triggerSingleShot(focusDelayMs: UInt64 = 250) async throws {
        try await focusPress()
        if focusDelayMs > 0 {
            try await Task.sleep(nanoseconds: focusDelayMs * 1_000_000)
        }
        try await shutterPress()
        try await Task.sleep(nanoseconds: 150_000_000)
        try await shutterRelease()
    }

    private func sendShutterCommand(param: [UInt8]) async throws {
        let (peripheral, char) = try requireCharacteristic(FujiBLEUUIDs.shutterChar, name: "Shutter")
        try await writeValue(Data([0x01, 0x00]), to: char, on: peripheral, timeoutSeconds: 4.0)
        try await writeValue(Data(param), to: char, on: peripheral, timeoutSeconds: 4.0)
    }

    // MARK: - GPS Geotagging (23-Byte Fujifilm geotag_t)

    /// Schreibt GPS-Koordinaten, Hoehe und UTC-Zeitstempel direkt in die Kamera.
    public func sendGeotag(latitude: Double, longitude: Double, altitudeMeters: Double, date: Date = Date()) async throws {
        let (peripheral, char) = try requireCharacteristic(FujiBLEUUIDs.geotagChar, name: "Geotag")

        var payload = Data(capacity: 23)
        let latFixed = Int32((latitude * 10_000_000.0).rounded()).littleEndian
        let lonFixed = Int32((longitude * 10_000_000.0).rounded()).littleEndian
        let altFixed = Int32(altitudeMeters.rounded()).littleEndian

        withUnsafeBytes(of: latFixed) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: lonFixed) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: altFixed) { payload.append(contentsOf: $0) }
        payload.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(secondsFromGMT: 0)!
        let comps = utcCal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let yearLE = UInt16(comps.year ?? 2026).littleEndian
        withUnsafeBytes(of: yearLE) { payload.append(contentsOf: $0) }
        payload.append(UInt8(comps.month ?? 1))
        payload.append(UInt8(comps.day ?? 1))
        payload.append(UInt8(comps.hour ?? 0))
        payload.append(UInt8(comps.minute ?? 0))
        payload.append(UInt8(comps.second ?? 0))

        try await writeValue(payload, to: char, on: peripheral, timeoutSeconds: 5.0)
        log(String(format: "GPS gesendet: %.5f, %.5f (%.0fm)", latitude, longitude, altitudeMeters))
    }

    // MARK: - Kamera-WLAN ueber laufende BLE-Verbindung starten

    public func triggerWiFiHotspot() async throws {
        let (peripheral, triggerChar) = try requireCharacteristic(FujiBLEUUIDs.wifiTriggerChar, name: "Wi-Fi Trigger")
        try? await shutterRelease()
        try await Task.sleep(nanoseconds: 500_000_000)
        try await writeValue(Data([0x03, 0x00]), to: triggerChar, on: peripheral, timeoutSeconds: 5.0)
        log("Kamera-WLAN per BLE (0x03 0x00) gestartet.")
    }

    // MARK: - Kamera-Backup & Equipment-Status ueber BLE (SVC_FILES)

    /// Laedt Kamera-Einstellungsbackup oder Statusdaten ueber den Fujifilm BLE-Dateidienst.
    public func downloadBLEFile(
        kind: FujiBLEFileKind,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> FujiBLEFileResult {
        let (peripheral, infoChar) = try requireCharacteristic(FujiBLEUUIDs.filesFileInfoChar, name: "BLE FileInfo")
        let (_, chunkChar) = try requireCharacteristic(FujiBLEUUIDs.filesFileChunkChar, name: "BLE FileChunk")

        // 1) Pflicht-Indications & File-Notify abonnieren (siehe libfuji/bluetooth.c)
        let indUUID = (kind == .status) ? FujiBLEUUIDs.statusIndicationChar : FujiBLEUUIDs.backupIndicationChar
        for uuid in [FujiBLEUUIDs.filesNotifyChar, indUUID] {
            if let ch = queue.sync(execute: { self.charMap[uuid] }),
               ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                try? await setNotify(true, for: ch, on: peripheral, timeoutSeconds: 3.0)
            }
        }

        // 2) Modus in CHR_UNK6 (68052e8a-...) setzen: Status = 01,00 | Backup = 03,00
        if let modeChar = queue.sync(execute: { self.charMap[FujiBLEUUIDs.filesModeChar] }) {
            let modeBytes: [UInt8] = (kind == .status) ? [0x01, 0x00] : [0x03, 0x00]
            try? await writeValue(Data(modeBytes), to: modeChar, on: peripheral, timeoutSeconds: 4.0)
        }

        // 3) Startbefehl an Kamera senden (Status = 0x02 0x00, Backup = 0x01 0x00)
        let cmdUUID = (kind == .status) ? FujiBLEUUIDs.statusCommandChar : FujiBLEUUIDs.backupUploadCommandChar
        let cmdBytes: [UInt8] = (kind == .status) ? [0x02, 0x00] : [0x01, 0x00]
        if let cmdChar = queue.sync(execute: { self.charMap[cmdUUID] }) {
            try await writeValue(Data(cmdBytes), to: cmdChar, on: peripheral, timeoutSeconds: 5.0)
        }

        if let maxChunkChar = queue.sync(execute: { self.charMap[FujiBLEUUIDs.filesMaxChunkSizeChar] }) {
            var maxSize: UInt32 = UInt32(0x78).littleEndian
            let maxSizeData = withUnsafeBytes(of: &maxSize) { Data($0) }
            try? await writeValue(maxSizeData, to: maxChunkChar, on: peripheral, timeoutSeconds: 4.0)
        }

        // 4) Bis zu 4s warten, bis die Kamera FILEINFO mit totalSize > 0 bereitstellt
        var rawName = "\(kind.rawValue).bin"
        var totalSize: UInt32 = 0
        for attempt in 1...8 {
            try await Task.sleep(nanoseconds: 500_000_000)
            let infoData = try await readValue(from: infoChar, on: peripheral, timeoutSeconds: 5.0)
            if infoData.count >= 44 {
                let parsedSize = infoData.subdata(in: 40..<44).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
                if parsedSize > 0 {
                    rawName = cleanUTF8String(infoData.prefix(40)) ?? rawName
                    totalSize = parsedSize
                    break
                }
            }
            if attempt == 8 {
                log("FILEINFO nach 8 Versuchen noch leer (\(infoData.count)B): \(hexString(infoData.prefix(48)))")
            }
        }

        guard totalSize > 0, totalSize < 5_000_000 else {
            throw FujiError.bleError("Kamera hat keine Datei bereitgestellt (\(totalSize) Bytes). Hinweis: Kamera im normalen Liveview (kein Menue) und SD-Karte eingelegt?")
        }

        log("Starte BLE-Download '\(rawName)' (\(totalSize) Bytes)...")
        var buffer = Data()
        buffer.reserveCapacity(Int(totalSize))
        var emptyReads = 0

        while buffer.count < Int(totalSize) {
            let chunk = try await readValue(from: chunkChar, on: peripheral, timeoutSeconds: 6.0)
            guard chunk.count >= 6 else {
                emptyReads += 1
                if emptyReads >= 3 { break }
                continue
            }
            let chunkSize = Int(chunk.subdata(in: 2..<6).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian })
            let available = min(chunkSize, max(0, chunk.count - 6))
            if available == 0 {
                emptyReads += 1
                if emptyReads >= 3 { break }
                continue
            }
            emptyReads = 0
            buffer.append(chunk.subdata(in: 6..<(6 + available)))
            onProgress?(buffer.count, Int(totalSize))
        }

        log("BLE-Datei '\(rawName)' fertig geladen (\(buffer.count) Bytes).")
        return FujiBLEFileResult(kind: kind, filename: rawName, data: buffer)
    }

    // MARK: - Interne CoreBluetooth-Hilfen

    private func requireCharacteristic(_ uuid: CBUUID, name: String) throws -> (CBPeripheral, CBCharacteristic) {
        try queue.sync {
            guard let p = self.activePeripheral, p.state == .connected else {
                throw FujiError.bleError("Keine aktive Bluetooth-Verbindung zur Kamera.")
            }
            guard let ch = self.charMap[uuid] else {
                throw FujiError.bleError("Funktion '\(name)' wird von dieser Kamera/Firmware nicht bereitgestellt.")
            }
            return (p, ch)
        }
    }

    private func readString(_ uuid: CBUUID, on peripheral: CBPeripheral) async -> String? {
        guard let ch = queue.sync(execute: { self.charMap[uuid] }), ch.properties.contains(.read) else {
            return nil
        }
        guard let data = try? await readValue(from: ch, on: peripheral, timeoutSeconds: 3.0) else {
            return nil
        }
        let str = cleanUTF8String(data)
        return (str?.isEmpty == false) ? str : nil
    }

    private func waitUntilPoweredOn() async throws {
        let state: CBManagerState = await withCheckedContinuation { cont in
            queue.async {
                if self.central.state != .unknown && self.central.state != .resetting {
                    cont.resume(returning: self.central.state)
                } else {
                    self.powerStateContinuation = cont
                }
            }
        }
        guard state == .poweredOn else {
            throw FujiError.bleUnavailable("Bluetooth ist nicht aktiv oder nicht erlaubt (Status \(state.rawValue)).")
        }
    }

    private func findFirstFujiCamera(timeoutSeconds: Double) async throws -> (CBPeripheral, String?) {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.findContinuation = cont
                self.central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
                self.queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                    if let pending = self.findContinuation {
                        self.findContinuation = nil
                        self.central.stopScan()
                        pending.resume(throwing: FujiError.bleTimeout("Keine Fujifilm-Kamera per Bluetooth gefunden."))
                    }
                }
            }
        }
    }

    private func connectPeripheral(_ peripheral: CBPeripheral, timeoutSeconds: Double) async throws -> CBPeripheral {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                peripheral.delegate = self
                self.connectContinuation = cont
                self.central.connect(peripheral, options: nil)
                self.queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                    if let pending = self.connectContinuation {
                        self.connectContinuation = nil
                        self.central.cancelPeripheralConnection(peripheral)
                        pending.resume(throwing: FujiError.bleTimeout("Bluetooth-Verbindungsaufbau zur X-T4 abgelaufen."))
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

    private func readValue(from char: CBCharacteristic, on peripheral: CBPeripheral, timeoutSeconds: Double) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.readContinuations[char.uuid] = cont
                peripheral.readValue(for: char)
                self.queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                    if let pending = self.readContinuations.removeValue(forKey: char.uuid) {
                        pending.resume(throwing: FujiError.bleTimeout("Timeout beim Lesen (\(char.uuid))."))
                    }
                }
            }
        }
    }

    private func writeValue(_ data: Data, to char: CBCharacteristic, on peripheral: CBPeripheral, timeoutSeconds: Double) async throws {
        if !char.properties.contains(.write) {
            queue.async { peripheral.writeValue(data, for: char, type: .withoutResponse) }
            return
        }
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.writeContinuations[char.uuid] = cont
                peripheral.writeValue(data, for: char, type: .withResponse)
                self.queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                    if let pending = self.writeContinuations.removeValue(forKey: char.uuid) {
                        pending.resume(throwing: FujiError.bleTimeout("Timeout beim Schreiben (\(char.uuid))."))
                    }
                }
            }
        }
    }

    private func setNotify(_ enabled: Bool, for char: CBCharacteristic, on peripheral: CBPeripheral, timeoutSeconds: Double) async throws {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.notifyContinuations[char.uuid] = cont
                peripheral.setNotifyValue(enabled, for: char)
                self.queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                    if let pending = self.notifyContinuations.removeValue(forKey: char.uuid) {
                        pending.resume(throwing: FujiError.bleTimeout("Timeout bei Subscription (\(char.uuid))."))
                    }
                }
            }
        }
    }

    private func sendCurrentTimestamp(to peripheral: CBPeripheral) {
        guard let timeChar = charMap[FujiBLEUUIDs.timeChar] else { return }
        let now = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        var bytes = Data(capacity: 7)
        let yearLE = UInt16(now.year ?? 2026).littleEndian
        withUnsafeBytes(of: yearLE) { bytes.append(contentsOf: $0) }
        bytes.append(UInt8(now.month ?? 1))
        bytes.append(UInt8(now.day ?? 1))
        bytes.append(UInt8(now.hour ?? 0))
        bytes.append(UInt8(now.minute ?? 0))
        bytes.append(UInt8(now.second ?? 0))
        peripheral.writeValue(bytes, for: timeChar, type: .withResponse)
        log("Uhrzeit automatisch mit X-T4 synchronisiert.")
        onTimeSynced?()
    }
}

// MARK: - CBCentralManagerDelegate & CBPeripheralDelegate

extension FujiBLESession: CBCentralManagerDelegate, CBPeripheralDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if let cont = powerStateContinuation, central.state != .unknown && central.state != .resetting {
            powerStateContinuation = nil
            cont.resume(returning: central.state)
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let pending = findContinuation else { return }
        let name = ((advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "").uppercased()
        let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []

        let matchesName = name.contains("FUJI") || name.contains("X-T") || name.contains("X-H")
            || name.contains("X-S") || name.contains("X-E") || name.contains("X100") || name.contains("GFX")
        let matchesMfg = mfg.map { $0.count >= 2 && $0[0] == 0xD8 && $0[1] == 0x04 } ?? false
        let matchesSvc = services.contains(FujiBLEUUIDs.filesService) || services.contains(FujiBLEUUIDs.xappService)

        guard matchesName || matchesMfg || matchesSvc else { return }

        var tokenHex: String?
        if let mfg, mfg.count >= 7, mfg[2] == 0x02 {
            tokenHex = hexString(mfg.subdata(in: 3..<7))
        }
        findContinuation = nil
        central.stopScan()
        pending.resume(returning: (peripheral, tokenHex))
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if let cont = connectContinuation {
            connectContinuation = nil
            cont.resume(returning: peripheral)
        }
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if let cont = connectContinuation {
            connectContinuation = nil
            cont.resume(throwing: error ?? FujiError.bleError("BLE-Verbindung fehlgeschlagen."))
        }
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let err = error ?? FujiError.bleError("Bluetooth-Verbindung zur Kamera getrennt.")
        if let c = servicesContinuation { servicesContinuation = nil; c.resume(throwing: err) }
        if let c = charsContinuation { charsContinuation = nil; c.resume(throwing: err) }
        for (_, c) in readContinuations { c.resume(throwing: err) }
        readContinuations.removeAll()
        for (_, c) in writeContinuations { c.resume(throwing: err) }
        writeContinuations.removeAll()
        for (_, c) in notifyContinuations { c.resume(throwing: err) }
        notifyContinuations.removeAll()
        activePeripheral = nil
        charMap.removeAll()
        if let c = disconnectContinuation {
            disconnectContinuation = nil
            c.resume()
        }
        onDisconnected?(error?.localizedDescription)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let c = servicesContinuation {
            servicesContinuation = nil
            if let error { c.resume(throwing: error) } else { c.resume(returning: peripheral.services ?? []) }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let c = charsContinuation {
            charsContinuation = nil
            if let error { c.resume(throwing: error) } else { c.resume(returning: service.characteristics ?? []) }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let c = readContinuations.removeValue(forKey: characteristic.uuid) {
            if let error { c.resume(throwing: error) } else { c.resume(returning: characteristic.value ?? Data()) }
            return
        }
        if characteristic.uuid == FujiBLEUUIDs.not1Char {
            sendCurrentTimestamp(to: peripheral)
        } else if characteristic.uuid == FujiBLEUUIDs.geotagUpdateChar {
            log("Kamera fragt aktuellen GPS-Standort an.")
            onGeotagRequested?()
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let c = writeContinuations.removeValue(forKey: characteristic.uuid) {
            if let error { c.resume(throwing: error) } else { c.resume(returning: ()) }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let c = notifyContinuations.removeValue(forKey: characteristic.uuid) {
            if let error { c.resume(throwing: error) } else { c.resume(returning: ()) }
        }
    }
}

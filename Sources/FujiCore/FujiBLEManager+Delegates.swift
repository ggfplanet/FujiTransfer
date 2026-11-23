import Foundation
@preconcurrency import CoreBluetooth

// MARK: - CBCentralManagerDelegate & CBPeripheralDelegate

extension FujiBLEManager: CBCentralManagerDelegate, CBPeripheralDelegate {
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
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
            ?? "(Unbenannt)"
        let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let mfgHex = mfgData.map { hexString($0) }

        // Fujifilm Pairing-Advertisement enthaelt [company_id: 2B][type: 1B (0x02)][token: 4B]
        var tokenHex: String?
        if let data = mfgData, data.count >= 7, data[2] == 0x02 {
            tokenHex = hexString(data.subdata(in: 3..<7))
        }

        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString) ?? []
        let device = FujiBLEDevice(
            id: peripheral.identifier,
            name: name,
            rssi: RSSI.intValue,
            manufacturerDataHex: mfgHex,
            pairingTokenHex: tokenHex,
            advertisedServices: serviceUUIDs
        )
        scanResults[peripheral.identifier] = (peripheral, device)

        if let pending = fastFindContinuation, isLikelyFujifilm(device) {
            if let filter = fastFindFilter, !filter.isEmpty, !device.name.lowercased().contains(filter) {
                return
            }
            fastFindContinuation = nil
            central.stopScan()
            pending.resume(returning: (peripheral, device))
        }
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
        let disconnectError = error ?? FujiError.bleError("BLE-Verbindung wurde von der Kamera getrennt.")
        if let cont = servicesContinuation { servicesContinuation = nil; cont.resume(throwing: disconnectError) }
        if let cont = charsContinuation { charsContinuation = nil; cont.resume(throwing: disconnectError) }
        for (_, cont) in readContinuations { cont.resume(throwing: disconnectError) }
        readContinuations.removeAll()
        for (_, cont) in writeContinuations { cont.resume(throwing: disconnectError) }
        writeContinuations.removeAll()
        for (_, cont) in notifyContinuations { cont.resume(throwing: disconnectError) }
        notifyContinuations.removeAll()
        if let cont = ind1Continuation { ind1Continuation = nil; cont.resume(throwing: disconnectError) }
        if let cont = disconnectContinuation { disconnectContinuation = nil; cont.resume() }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let cont = servicesContinuation {
            servicesContinuation = nil
            if let error {
                cont.resume(throwing: error)
            } else {
                cont.resume(returning: peripheral.services ?? [])
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let cont = charsContinuation {
            charsContinuation = nil
            if let error {
                cont.resume(throwing: error)
            } else {
                cont.resume(returning: service.characteristics ?? [])
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let cont = readContinuations.removeValue(forKey: characteristic.uuid) {
            if let error {
                cont.resume(throwing: error)
            } else {
                cont.resume(returning: characteristic.value ?? Data())
            }
            return
        }
        let val = characteristic.value ?? Data()
        if characteristic.uuid == FujiBLEUUIDs.not1Char, let timeChar = timeSyncCharacteristic {
            let now = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
            var bytes = Data(capacity: 7)
            let year = UInt16(now.year ?? 2026).littleEndian
            withUnsafeBytes(of: year) { bytes.append(contentsOf: $0) }
            bytes.append(UInt8(now.month ?? 1))
            bytes.append(UInt8(now.day ?? 1))
            bytes.append(UInt8(now.hour ?? 0))
            bytes.append(UInt8(now.minute ?? 0))
            bytes.append(UInt8(now.second ?? 0))
            peripheral.writeValue(bytes, for: timeChar, type: .withResponse)
            log("Zeitstempel auf NOT1-Anfrage an X-T4 gesendet.")
            return
        }
        if characteristic.uuid == FujiBLEUUIDs.ind1Char {
            log("IND1 Event: \(hexString(val))")
            if val.first != 0x00, let cont = ind1Continuation {
                ind1Continuation = nil
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: val)
                }
            }
        } else if !val.isEmpty {
            log("BLE Notify \(characteristic.uuid): \(hexString(val))")
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let cont = writeContinuations.removeValue(forKey: characteristic.uuid) {
            if let error {
                cont.resume(throwing: error)
            } else {
                cont.resume(returning: ())
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let cont = notifyContinuations.removeValue(forKey: characteristic.uuid) {
            if let error {
                cont.resume(throwing: error)
            } else {
                cont.resume(returning: ())
            }
        }
    }
}

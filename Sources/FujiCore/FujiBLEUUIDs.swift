import Foundation
@preconcurrency import CoreBluetooth

/// Bekannte Fujifilm BLE GATT-UUIDs (aus libfuji/bluetooth.c & furble, MIT-Lizenz).
public enum FujiBLEUUIDs {
    // Legacy Pairing (Camera Remote & X-T4 Legacy BLE)
    public static let legacyPairService = CBUUID(string: "91f1de68-dff6-466e-8b65-ff13b0f16fb8")
    public static let legacyPairTokenChar = CBUUID(string: "aba356eb-9633-4e60-b73f-f52516dbd671")
    public static let clientNameChar = CBUUID(string: "85b9163e-62d1-49ff-a6f5-054b4630d4a1")

    // Secure Pairing (FUJIFILM XApp / neuere Bodies)
    public static let securePairService = CBUUID(string: "123d8f06-62a1-4935-9322-833c531ee225")
    public static let secureStatusChar = CBUUID(string: "f557d96b-8284-4667-8793-b971c1deca2a")

    // XApp Erkennungs- & Datei-Status-Service (wird von X-T4 direkt im BLE-Advertisement gesendet)
    public static let xappService = CBUUID(string: "117c4142-edd4-4c77-8696-dd18eebb770a")
    public static let filesService = CBUUID(string: "af854c2e-b214-458e-97e2-912c4ecf2cb8")

    // WLAN SSID & Passwort + Status-Notifications
    public static let wifiInfoService = CBUUID(string: "4e941240-d01d-46b9-a5ea-67636806830b")
    public static let wifiSSIDChar = CBUUID(string: "bf6dc9cf-3606-4ec9-a4c8-d77576e93ea4")
    public static let wifiPasswordChar = CBUUID(string: "e809256a-915c-4967-92e8-53b7d4cad213")
    public static let wifiStatusNot9Char = CBUUID(string: "82a9f452-c5ce-4ef5-8203-3fc9a47f8171")

    // Status-Indications (IND1: 02,00 = Wi-Fi startet, 01,00 = AP bereit)
    public static let confService = CBUUID(string: "4c0020fe-f3b6-40de-acc9-77d129067b14")
    public static let ind1Char = CBUUID(string: "a68e3f66-0fcc-4395-8d4c-aa980b5877fa")
    public static let ind2Char = CBUUID(string: "bd17ba04-b76b-4892-a545-b73ba1f74dae")
    public static let not1Char = CBUUID(string: "f9150137-5d40-4801-a8dc-f7fc5b01da50")
    public static let ind3Char = CBUUID(string: "049ec406-ef75-4205-a390-08fe209c51f0")
    public static let geotagUpdateChar = CBUUID(string: "ad06c7b7-f41a-46f4-a29a-712055319122")

    // Zeit-Sync (Kamera fordert bei NOT1 den aktuellen Zeitstempel an)
    public static let timeService = CBUUID(string: "e872b11f-d526-4ae1-9bb4-89a99d48fa59")
    public static let timeChar = CBUUID(string: "b9bfd37f-ccad-4d36-a1ee-018e792b3edf")

    // Shutter, Wi-Fi Hotspot Trigger & Backup/Status Befehle
    public static let shutterService = CBUUID(string: "6514eb81-4e8f-458d-aa2a-e691336cdfac")
    public static let shutterChar = CBUUID(string: "7fcf49c6-4ff0-4777-a03d-1a79166af7a8")
    public static let wifiTriggerChar = CBUUID(string: "600655e6-3637-42f1-8fb2-44efc5c63b13")
    public static let statusCommandChar = CBUUID(string: "2674f0b0-f909-4e73-8656-338e9c74457f")
    public static let backupUploadCommandChar = CBUUID(string: "f1897eb9-a9aa-40f0-8ce6-2fa7915bc459")
    public static let backupReadCommandChar = CBUUID(string: "f14e7a88-6f57-4872-a69b-b47ef3295c9b")

    // GPS-Geotagging (Koordinaten + Hoehe + UTC-Zeit)
    public static let geotagService = CBUUID(string: "3b46ec2b-48ba-41fd-b1b8-ed860b60d22b")
    public static let geotagChar = CBUUID(string: "0f36ec14-29e5-411a-a1b6-64ee8383f090")

    // Objektiv-Informationen (Name & Firmware)
    public static let lensService = CBUUID(string: "15ca59fe-620c-464d-a987-223fab660cde")
    public static let lensNameChar = CBUUID(string: "68887a7a-10a7-4a4a-aadd-6f9db1abaa0e")
    public static let lensFirmwareChar = CBUUID(string: "621a98d8-6314-4c3e-a683-eea1d6166606")

    // Datei-Transfer ueber BLE (Kamera-Backup & Equipment-Status)
    public static let filesFileInfoChar = CBUUID(string: "c922ac69-9480-4348-8f4b-9ee29bc30d1d")
    public static let filesMaxChunkSizeChar = CBUUID(string: "7f3400fe-17e7-4b80-8a0e-81b0343c1b49")
    public static let filesFileChunkChar = CBUUID(string: "ac0c799a-fa6c-4df5-bbc5-bb95cce7e6ea")
    public static let filesModeChar = CBUUID(string: "68052e8a-fb91-404f-8847-0eb4be24308c")
    public static let filesNotifyChar = CBUUID(string: "2e27ed9f-5506-41cd-ba48-dac06669ad95")
    public static let statusIndicationChar = CBUUID(string: "2f6cb772-1d69-448e-8819-fe6b5c20b094")
    public static let backupIndicationChar = CBUUID(string: "4b3a413c-230f-42bc-b3ed-b1db2eadee82")

    // Standard BLE Device Information & Generic Access
    public static let genericAccessService = CBUUID(string: "1800")
    public static let deviceNameChar = CBUUID(string: "2A00")
    public static let deviceInfoService = CBUUID(string: "180A")
    public static let firmwareRevChar = CBUUID(string: "2A26")
}

// MARK: - Interne Byte- & String-Helfer fuer BLE

func hexString(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

func dataFromHex(_ hex: String) -> Data? {
    let cleaned = hex.replacingOccurrences(of: " ", with: "")
    guard cleaned.count % 2 == 0 else { return nil }
    var data = Data(capacity: cleaned.count / 2)
    var index = cleaned.startIndex
    while index < cleaned.endIndex {
        let nextIndex = cleaned.index(index, offsetBy: 2)
        guard let byte = UInt8(cleaned[index..<nextIndex], radix: 16) else { return nil }
        data.append(byte)
        index = nextIndex
    }
    return data
}

func cleanUTF8String(_ data: Data) -> String? {
    let trimmed = data.prefix { $0 != 0 }
    return String(data: trimmed, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

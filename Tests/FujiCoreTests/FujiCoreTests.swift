import XCTest
import Foundation
import CoreBluetooth
import CFujiBridge
@testable import FujiCore

final class FujiCoreTests: XCTestCase {
    func testPhotoInfoFormatLabels() {
        let jpeg = FujiPhotoInfo(
            index: 0,
            handle: 1,
            storageID: 0x10000001,
            objectFormat: 0x3801,
            compressedSize: 5_242_880,
            width: 6240,
            height: 4160,
            filename: "DSCF0001.JPG",
            dateCreated: "20261122T110000"
        )
        XCTAssertTrue(jpeg.isJPEG)
        XCTAssertEqual(jpeg.formatLabel, "JPEG")

        let raf = FujiPhotoInfo(
            index: 1,
            handle: 2,
            storageID: 0x10000001,
            objectFormat: 0x3800,
            compressedSize: 30_000_000,
            width: 6240,
            height: 4160,
            filename: "DSCF0001.RAF",
            dateCreated: "20261122T110000"
        )
        XCTAssertFalse(raf.isJPEG)
        XCTAssertEqual(raf.formatLabel, "RAW/RAF")
    }

    func testDownloadResultThroughputCalculation() {
        let result = FujiDownloadResult(
            handle: 1,
            filename: "DSCF0001.JPG",
            bytesWritten: 10 * 1024 * 1024,
            expectedSize: 10 * 1024 * 1024,
            durationSeconds: 2.0,
            validJPEGHeader: true,
            validJPEGFooter: true,
            outputURL: URL(fileURLWithPath: "/tmp/DSCF0001.JPG")
        )
        XCTAssertEqual(result.megabytesPerSecond, 5.0, accuracy: 0.001)
    }

    func testBLEUUIDConstantsAreWellFormed() {
        let uuids: [CBUUID] = [
            FujiBLEUUIDs.legacyPairService,
            FujiBLEUUIDs.legacyPairTokenChar,
            FujiBLEUUIDs.clientNameChar,
            FujiBLEUUIDs.securePairService,
            FujiBLEUUIDs.secureStatusChar,
            FujiBLEUUIDs.xappService,
            FujiBLEUUIDs.wifiInfoService,
            FujiBLEUUIDs.wifiSSIDChar,
            FujiBLEUUIDs.wifiPasswordChar,
            FujiBLEUUIDs.confService,
            FujiBLEUUIDs.ind1Char,
            FujiBLEUUIDs.shutterService,
            FujiBLEUUIDs.wifiTriggerChar
        ]
        XCTAssertEqual(Set(uuids).count, uuids.count, "Alle Fujifilm BLE-UUIDs muessen eindeutig sein")
    }

    func testBridgeErrorStringsAndLifecycle() {
        let client = FujiWiFiClient(verbose: false)
        XCTAssertEqual(client.objectCount(), 0)
        client.setNetworkInterface("en0")
        client.setNetworkInterface(nil)
        client.disconnect()

        let okStr = fuji_bridge_error_string(0).map { String(cString: $0) }
        XCTAssertEqual(okStr, "OK")
    }

    /// Prueft ueber einen lokalen Loopback-TCP-Socket, dass CFujiBridge das exakte
    /// 82-Byte Fujifilm Init-Handshake-Paket (Version 0x8f53e4f2) sendet.
    /// Wird in stark eingeschraenkten Sandbox-Umgebungen (EPERM auf Loopback) sauber uebersprungen.
    func testBridgeSendsValidFujifilmInitPacketOverLoopback() throws {
        let listenFD = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listenFD, 0)
        defer { close(listenFD) }

        var yes: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bindResult, 0)
        XCTAssertEqual(listen(listenFD, 1), 0)

        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listenFD, $0, &boundLen)
            }
        }
        let port = Int32(UInt16(bigEndian: boundAddr.sin_port))

        let receivedExpectation = expectation(description: "Mock server received 82-byte FujiInitPacket")
        var capturedBytes = Data()

        DispatchQueue.global(qos: .userInitiated).async {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else { return }
            defer { close(clientFD) }

            var buf = [UInt8](repeating: 0, count: 128)
            let n = read(clientFD, &buf, buf.count)
            if n > 0 {
                capturedBytes = Data(buf.prefix(n))
            }
            receivedExpectation.fulfill()
        }

        var sawSocketPermissionDenied = false
        let client = FujiWiFiClient(verbose: true) { _, msg in
            if msg.contains("Failed to connect to socket 1") {
                sawSocketPermissionDenied = true
            }
        }

        XCTAssertThrowsError(
            try client.connect(host: "127.0.0.1", port: port, mode: .xapp, clientName: "TestMac")
        )

        if sawSocketPermissionDenied {
            throw XCTSkip("Loopback TCP connect() wird von der Test-Sandbox blockiert (EPERM).")
        }

        wait(for: [receivedExpectation], timeout: 5.0)
        XCTAssertEqual(capturedBytes.count, 82, "FujiInitPacket muss exakt 82 Bytes lang sein")

        let expectedHeader: [UInt8] = [
            0x52, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00,
            0xF2, 0xE4, 0x53, 0x8F
        ]
        XCTAssertEqual(Array(capturedBytes.prefix(12)), expectedHeader)
    }
}

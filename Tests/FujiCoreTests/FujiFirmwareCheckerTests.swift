import XCTest
import Foundation
@testable import FujiCore

final class FujiFirmwareCheckerTests: XCTestCase {
    private let sampleCameraHTML = """
    <a href="https://www.fujifilm-x.com/global/support/download/firmware/cameras/x-t4/" class="support-table__row grid">
        <div class="support-table__item"><span class="font-semibold">X-T4</span></div>
        <div class="support-table__item">Ver.2.12</div>
        <div class="support-table__item">07.09.2024</div>
    </a>
    <a href="https://www.fujifilm-x.com/global/support/download/firmware/cameras/x-t30/" class="support-table__row grid">
        <div class="support-table__item"><span class="font-semibold">X-T30</span></div>
        <div class="support-table__item">Ver.2.01</div>
    </a>
    <a href="https://www.fujifilm-x.com/global/support/download/firmware/cameras/x-t30-ii/" class="support-table__row grid">
        <div class="support-table__item"><span class="font-semibold">X-T30 II</span></div>
        <div class="support-table__item">Ver.2.04</div>
    </a>
    <a href="https://www.fujifilm-x.com/global/support/download/firmware/cameras/gfx-50s/" class="support-table__row grid">
        <div class="support-table__item"><span class="font-semibold">GFX 50S</span></div>
        <div class="support-table__item">Ver.4.52</div>
    </a>
    """

    private let sampleLensHTML = """
    <a href="https://www.fujifilm-x.com/global/support/download/firmware/lenses/xf18-55mmf28-4-r-lm-ois/" class="support-table__row grid">
        <div class="support-table__item"><span class="font-semibold">XF18-55mmF2.8-4 R LM OIS</span></div>
        <div class="support-table__item">Ver.3.24</div>
    </a>
    <a href="https://www.fujifilm-x.com/global/support/download/firmware/lenses/xf23mmf14-r/" class="support-table__row grid">
        <div class="support-table__item"><span class="font-semibold">XF23mmF1.4 R</span></div>
        <div class="support-table__item">Ver.1.01</div>
    </a>
    <a href="https://www.fujifilm-x.com/global/support/download/firmware/lenses/xf16-80mmf4-r-ois-wr/" class="support-table__row grid">
        <div class="support-table__item"><span class="font-semibold">XF16-80mmF4 R OIS WR</span></div>
        <div class="support-table__item">Ver.1.21</div>
    </a>
    """

    func testParseSupportTableHTML() {
        let cameras = FujiFirmwareChecker.parseSupportTableHTML(sampleCameraHTML)
        XCTAssertEqual(cameras.count, 4)
        XCTAssertEqual(cameras[0].modelName, "X-T4")
        XCTAssertEqual(cameras[0].latestVersion, "2.12")
        XCTAssertEqual(
            cameras[0].downloadURL.absoluteString,
            "https://www.fujifilm-x.com/global/support/download/firmware/cameras/x-t4/"
        )

        let lenses = FujiFirmwareChecker.parseSupportTableHTML(sampleLensHTML)
        XCTAssertEqual(lenses.count, 3)
        XCTAssertEqual(lenses[0].modelName, "XF18-55mmF2.8-4 R LM OIS")
        XCTAssertEqual(lenses[0].latestVersion, "3.24")
    }

    func testCameraMatchingAndVariantSafety() {
        let cameras = FujiFirmwareChecker.parseSupportTableHTML(sampleCameraHTML)

        XCTAssertEqual(FujiFirmwareChecker.matchCamera(modelName: "X-T4", in: cameras)?.modelName, "X-T4")
        XCTAssertEqual(FujiFirmwareChecker.matchCamera(modelName: "FUJIFILM X-T4", in: cameras)?.modelName, "X-T4")
        XCTAssertEqual(FujiFirmwareChecker.matchCamera(modelName: "FUJIFILM-X-T4-3A2B", in: cameras)?.modelName, "X-T4")
        XCTAssertEqual(FujiFirmwareChecker.matchCamera(modelName: "GFX50S", in: cameras)?.modelName, "GFX 50S")

        // X-T30 II darf nicht auf X-T30 matchen, X-T30 III (nicht in Liste) muss nil liefern
        XCTAssertEqual(FujiFirmwareChecker.matchCamera(modelName: "X-T30 II", in: cameras)?.modelName, "X-T30 II")
        XCTAssertNil(FujiFirmwareChecker.matchCamera(modelName: "X-T30 III", in: cameras))
    }

    func testLensMatchingOnlyFujifilmAndStrictVariants() {
        let lenses = FujiFirmwareChecker.parseSupportTableHTML(sampleLensHTML)

        XCTAssertEqual(
            FujiFirmwareChecker.matchLens(lensName: "XF18-55mmF2.8-4 R LM OIS", in: lenses)?.latestVersion,
            "3.24"
        )
        XCTAssertEqual(
            FujiFirmwareChecker.matchLens(lensName: "FUJINON XF 16-80mm F4.0 R OIS WR", in: lenses)?.latestVersion,
            "1.21"
        )
        // Neuere WR-Variante darf NICHT auf alte non-WR-Variante matchen
        XCTAssertNil(FujiFirmwareChecker.matchLens(lensName: "XF23mmF1.4 R LM WR", in: lenses))
        // Drittanbieter muessen strikt ignoriert werden
        XCTAssertNil(FujiFirmwareChecker.matchLens(lensName: "Sigma 18-50mm F2.8 DC DN", in: lenses))
        XCTAssertNil(FujiFirmwareChecker.matchLens(lensName: "Viltrox AF 27mm F1.2 Pro", in: lenses))
    }

    func testVersionComparisonWithLeadingZeros() {
        let entry = FujiFirmwareEntry(
            modelName: "X-T4",
            latestVersion: "2.12",
            downloadURL: URL(string: "https://www.fujifilm-x.com/global/support/download/firmware/cameras/x-t4/")!
        )

        XCTAssertEqual(
            FujiFirmwareChecker.compare(installed: "02.12", against: entry),
            .upToDate(latestVersion: "2.12", downloadURL: entry.downloadURL)
        )
        XCTAssertEqual(
            FujiFirmwareChecker.compare(installed: "02.11", against: entry),
            .updateAvailable(installedVersion: "2.11", latestVersion: "2.12", downloadURL: entry.downloadURL)
        )
        XCTAssertEqual(
            FujiFirmwareChecker.compare(installed: "2.9", against: entry),
            .updateAvailable(installedVersion: "2.09", latestVersion: "2.12", downloadURL: entry.downloadURL)
        )
        XCTAssertEqual(
            FujiFirmwareChecker.compare(installed: "02.13", against: entry),
            .upToDate(latestVersion: "2.12", downloadURL: entry.downloadURL)
        )
        XCTAssertNil(FujiFirmwareChecker.compare(installed: "unknown", against: entry))
    }

    func testLiveCameraFirmwareCheckAgainstFujifilmWebsite() async throws {
        guard ProcessInfo.processInfo.environment["FUJI_LIVE_FIRMWARE_TEST"] == "1" else {
            throw XCTSkip("Live-Netzwerktest nur aktiv mit FUJI_LIVE_FIRMWARE_TEST=1")
        }

        let tempCache = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuji-fw-live-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempCache) }

        let checker = FujiFirmwareChecker(cacheTTL: 3600, cacheDirectory: tempCache)

        let upToDate = await checker.checkCameraFirmware(modelName: "X-T4", installedVersion: "02.12")
        guard case .upToDate(let latest, let url) = upToDate else {
            XCTFail("Erwartete .upToDate fuer X-T4 02.12, erhielt: \(String(describing: upToDate))")
            return
        }
        XCTAssertTrue(url.absoluteString.contains("fujifilm-x.com"))
        XCTAssertFalse(latest.isEmpty)

        let outdated = await checker.checkCameraFirmware(modelName: "FUJIFILM X-T4", installedVersion: "01.00")
        guard case .updateAvailable(let installed, let latestForOld, _) = outdated else {
            XCTFail("Erwartete .updateAvailable fuer X-T4 01.00, erhielt: \(String(describing: outdated))")
            return
        }
        XCTAssertEqual(installed, "1.00")
        XCTAssertEqual(latestForOld, latest)

        let unknown = await checker.checkCameraFirmware(modelName: "NonExistentCamera999", installedVersion: "01.00")
        XCTAssertNil(unknown)
    }
}

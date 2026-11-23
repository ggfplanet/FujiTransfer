import Foundation
import CFujiBridge

/// Swift-Client fuer die Fujifilm WLAN-PTP/IP-Kommunikation auf Basis von libfuji/libpict.
/// Alle Operationen sind synchron/blockierend auf einem dedizierten Hintergrund-Queue nutzbar
/// und laufen identisch auf macOS und iOS.
public final class FujiWiFiClient {
    public typealias LogHandler = (String, String) -> Void
    public typealias ProgressHandler = (_ bytesReceived: Int, _ totalBytes: Int) -> Void

    internal var session: OpaquePointer?
    private let logBox: FujiLogBox

    public init(verbose: Bool = false, onLog: LogHandler? = nil) {
        self.logBox = FujiLogBox(handler: onLog)
        let ctx = Unmanaged.passUnretained(logBox).toOpaque()
        self.session = fuji_bridge_create(verbose, fujiBridgeSwiftLogCallback, ctx)
    }

    deinit {
        if let session {
            fuji_bridge_destroy(session)
        }
    }

    /// Bindet ausgehende Sockets optional an ein festes Interface (z. B. "en0").
    public func setNetworkInterface(_ interfaceName: String?) {
        guard let session else { return }
        if let interfaceName, !interfaceName.isEmpty {
            interfaceName.withCString { fuji_bridge_set_interface(session, $0) }
        } else {
            fuji_bridge_set_interface(session, nil)
        }
    }

    /// Bricht einen laufenden Download sauber ab.
    public func cancelCurrentOperation() {
        guard let session else { return }
        fuji_bridge_request_cancel(session, true)
    }

    /// Verbindet mit der Kamera (Standard: 192.168.0.1:55740) und startet den Galerie-Modus.
    public func connect(
        host: String = "192.168.0.1",
        port: Int32 = 55740,
        mode: FujiTransportMode = .wirelessComm,
        clientName: String = "FujiTransferMac"
    ) throws -> FujiSessionInfo {
        guard let session else {
            throw FujiError.notConnected
        }

        var rawInfo = FujiBridgeSessionInfo()
        let bridgeMode: FujiBridgeMode = (mode == .xapp)
            ? FUJI_BRIDGE_MODE_XAPP
            : FUJI_BRIDGE_MODE_WIRELESS_COMM

        let rc = host.withCString { hostPtr in
            clientName.withCString { namePtr in
                fuji_bridge_connect(session, hostPtr, port, bridgeMode, namePtr, &rawInfo)
            }
        }

        guard rc == 0 else {
            throw FujiError.connectionFailed(code: rc, detail: lastErrorDetail(fallbackCode: rc))
        }

        return convertSessionInfo(rawInfo)
    }

    /// Trennt die Verbindung sauber (sendet CloseSession + Fujifilm Goodbye-Paket).
    public func disconnect() {
        guard let session else { return }
        fuji_bridge_disconnect(session)
    }

    /// Gibt die Anzahl der erreichbaren Dateien auf der aktiven SD-Karte zurueck.
    public func objectCount() -> Int {
        guard let session else { return 0 }
        return Int(fuji_bridge_get_object_count(session))
    }

    /// Liest Metadaten fuer bis zu `limit` Fotos ab `offset` aus.
    public func listPhotos(offset: Int = 0, limit: Int = 20) throws -> [FujiPhotoInfo] {
        guard let session else { throw FujiError.notConnected }
        let total = Int(fuji_bridge_get_object_count(session))
        guard total > 0, offset < total else { return [] }

        let end = min(total, offset + max(0, limit))
        var results: [FujiPhotoInfo] = []
        results.reserveCapacity(end - offset)

        for idx in offset..<end {
            let handle = fuji_bridge_get_handle_at(session, Int32(idx))
            guard handle > 0 else { continue }

            var rawObj = FujiBridgeObjectInfo()
            let rc = fuji_bridge_get_object_info(session, UInt32(handle), &rawObj)
            if rc != 0 {
                throw FujiError.protocolError(
                    operation: "GetObjectInfo(handle=\(handle))",
                    code: rc,
                    detail: lastErrorDetail(fallbackCode: rc)
                )
            }
            results.append(convertObjectInfo(rawObj, index: idx))
        }
        return results
    }

    /// Laedt das JPEG-Vorschaubild (Thumbnail) fuer ein Objekt-Handle.
    public func fetchThumbnail(handle: UInt32) throws -> Data {
        guard let session else { throw FujiError.notConnected }

        var ptr: UnsafeMutablePointer<UInt8>?
        var length: UInt32 = 0
        let rc = fuji_bridge_get_thumbnail(session, handle, &ptr, &length)
        guard rc == 0, let buffer = ptr, length > 0 else {
            if let ptr { fuji_bridge_free_buffer(ptr) }
            throw FujiError.protocolError(
                operation: "GetThumbnail(handle=\(handle))",
                code: rc,
                detail: lastErrorDetail(fallbackCode: rc)
            )
        }

        let data = Data(bytes: buffer, count: Int(length))
        fuji_bridge_free_buffer(buffer)
        return data
    }

    /// Laedt eine Datei (JPEG) in 1-MiB-Chunks direkt in den Zielordner und prueft die JPEG-Marker.
    public func downloadPhoto(
        handle: UInt32,
        toDirectory directoryURL: URL,
        compressForSmartphone: Bool = false,
        onProgress: ProgressHandler? = nil
    ) throws -> FujiDownloadResult {
        guard let session else { throw FujiError.notConnected }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let tempURL = directoryURL.appendingPathComponent(".fuji_tmp_\(handle)_\(UUID().uuidString)")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: tempURL)

        let writeState = FujiDownloadWriteState(fileHandle: fileHandle, onProgress: onProgress)
        let ctx = Unmanaged.passUnretained(writeState).toOpaque()
        var rawInfo = FujiBridgeObjectInfo()

        let start = Date()
        let rc = fuji_bridge_download_object(
            session,
            handle,
            compressForSmartphone,
            &rawInfo,
            fujiBridgeSwiftChunkCallback,
            ctx
        )
        let duration = Date().timeIntervalSince(start)
        try? fileHandle.close()

        if let writeError = writeState.writeError {
            try? FileManager.default.removeItem(at: tempURL)
            throw writeError
        }

        guard rc == 0 else {
            try? FileManager.default.removeItem(at: tempURL)
            throw FujiError.protocolError(
                operation: "DownloadObject(handle=\(handle))",
                code: rc,
                detail: lastErrorDetail(fallbackCode: rc)
            )
        }

        let rawFilename = cStringFromTuple(rawInfo.filename)
        let safeFilename = sanitizeFilename(rawFilename.isEmpty ? "FUJI_\(handle).JPG" : rawFilename)
        let finalURL = directoryURL.appendingPathComponent(safeFilename)
        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: finalURL)

        let validHeader = writeState.firstTwoBytes == [0xFF, 0xD8]
        let validFooter = writeState.lastTwoBytes == [0xFF, 0xD9]

        return FujiDownloadResult(
            handle: handle,
            filename: safeFilename,
            bytesWritten: writeState.bytesWritten,
            expectedSize: Int(rawInfo.compressed_size),
            durationSeconds: duration,
            validJPEGHeader: validHeader,
            validJPEGFooter: validFooter,
            outputURL: finalURL
        )
    }

    /// Wechselt auf SD-Kartenslot 1 oder 2 (XApp-Modus).
    public func switchCard(cardID: Int) throws -> FujiSessionInfo {
        guard let session else { throw FujiError.notConnected }
        var rawInfo = FujiBridgeSessionInfo()
        let rc = fuji_bridge_switch_card(session, Int32(cardID), &rawInfo)
        guard rc == 0 else {
            throw FujiError.protocolError(
                operation: "SwitchCard(\(cardID))",
                code: rc,
                detail: lastErrorDetail(fallbackCode: rc)
            )
        }
        return convertSessionInfo(rawInfo)
    }

    // MARK: - Internal helpers

    internal func lastErrorDetail(fallbackCode: Int32) -> String {
        if let session {
            var buf = [CChar](repeating: 0, count: 256)
            fuji_bridge_get_last_error(session, &buf, buf.count)
            let msg = String(cString: buf)
            if !msg.isEmpty {
                return msg
            }
        }
        if let errPtr = fuji_bridge_error_string(fallbackCode) {
            return String(cString: errPtr)
        }
        return "Code \(fallbackCode)"
    }

    internal func convertSessionInfo(_ raw: FujiBridgeSessionInfo) -> FujiSessionInfo {
        let rawCards = [raw.cards.0, raw.cards.1]
        let cards: [FujiCardInfo] = rawCards.prefix(Int(raw.card_count)).map { c in
            FujiCardInfo(
                id: Int(c.card_id),
                name: cStringFromTuple(c.name),
                objectCount: Int(c.object_count)
            )
        }
        return FujiSessionInfo(
            cameraName: cStringFromTuple(raw.camera_name),
            cameraState: Int(raw.camera_state),
            remoteVersion: Int(raw.remote_version),
            remoteImageViewVersion: Int(raw.remote_image_view_version),
            remoteImageViewExVersion: Int(raw.remote_image_view_ex_version),
            activeCardID: Int(raw.active_card_id),
            totalObjectCount: Int(raw.total_object_count),
            hasExplicitHandleList: raw.has_explicit_handle_list,
            effectiveMode: raw.effective_mode == FUJI_BRIDGE_MODE_XAPP ? .xapp : .wirelessComm,
            cards: cards
        )
    }

    private func convertObjectInfo(_ raw: FujiBridgeObjectInfo, index: Int) -> FujiPhotoInfo {
        FujiPhotoInfo(
            index: index,
            handle: raw.handle,
            storageID: raw.storage_id,
            objectFormat: raw.object_format,
            compressedSize: raw.compressed_size,
            width: raw.image_width,
            height: raw.image_height,
            filename: cStringFromTuple(raw.filename),
            dateCreated: cStringFromTuple(raw.date_created)
        )
    }

    private func sanitizeFilename(_ name: String) -> String {
        let base = URL(fileURLWithPath: name).lastPathComponent
        return base.isEmpty ? "photo.jpg" : base
    }
}

// MARK: - C callback trampolines & boxes

private final class FujiLogBox {
    let handler: FujiWiFiClient.LogHandler?
    init(handler: FujiWiFiClient.LogHandler?) {
        self.handler = handler
    }
}

private final class FujiDownloadWriteState {
    let fileHandle: FileHandle
    let onProgress: FujiWiFiClient.ProgressHandler?
    var bytesWritten: Int = 0
    var firstTwoBytes: [UInt8] = []
    var lastTwoBytes: [UInt8] = []
    var writeError: Error?

    init(fileHandle: FileHandle, onProgress: FujiWiFiClient.ProgressHandler?) {
        self.fileHandle = fileHandle
        self.onProgress = onProgress
    }

    func append(_ bytes: UnsafePointer<UInt8>, length: Int, totalSize: Int) -> Int32 {
        let chunk = Data(bytes: bytes, count: length)
        if firstTwoBytes.count < 2 {
            let needed = 2 - firstTwoBytes.count
            firstTwoBytes.append(contentsOf: chunk.prefix(needed))
        }
        if length >= 2 {
            lastTwoBytes = [bytes[length - 2], bytes[length - 1]]
        } else if length == 1 {
            if let prev = lastTwoBytes.last {
                lastTwoBytes = [prev, bytes[0]]
            } else {
                lastTwoBytes = [bytes[0]]
            }
        }

        do {
            try fileHandle.write(contentsOf: chunk)
            bytesWritten += length
            onProgress?(bytesWritten, totalSize)
            return 0
        } catch {
            writeError = error
            return -1
        }
    }
}

private func fujiBridgeSwiftLogCallback(
    userCtx: UnsafeMutableRawPointer?,
    level: FujiBridgeLogLevel,
    message: UnsafePointer<CChar>?
) {
    guard let userCtx, let message else { return }
    let box = Unmanaged<FujiLogBox>.fromOpaque(userCtx).takeUnretainedValue()
    let levelText: String
    switch level {
    case FUJI_LOG_VERBOSE: levelText = "DBG"
    case FUJI_LOG_INFO: levelText = "INFO"
    case FUJI_LOG_ERROR: levelText = "ERR"
    default: levelText = "LOG"
    }
    box.handler?(levelText, String(cString: message))
}

private func fujiBridgeSwiftChunkCallback(
    userCtx: UnsafeMutableRawPointer?,
    bytes: UnsafePointer<UInt8>?,
    length: UInt32,
    offset: UInt32,
    totalSize: UInt32
) -> Int32 {
    guard let userCtx, let bytes else { return -1 }
    _ = offset
    let state = Unmanaged<FujiDownloadWriteState>.fromOpaque(userCtx).takeUnretainedValue()
    return state.append(bytes, length: Int(length), totalSize: Int(totalSize))
}

private func cStringFromTuple<T>(_ tuple: T) -> String {
    var copy = tuple
    return withUnsafeBytes(of: &copy) { raw -> String in
        let bytes = raw.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
}

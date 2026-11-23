import Foundation
import CFujiBridge

/// WLAN-Live-View, Kamera-Steuerung und XApp-Galeriefilter als Erweiterung von `FujiWiFiClient`.
public extension FujiWiFiClient {
    /// Wechselt die laufende WLAN-Session in den Live-View-Modus (oeffnet Event- & Video-Port 55741/55742).
    func enterLiveView() throws {
        guard let session else { throw FujiError.notConnected }
        let rc = fuji_bridge_enter_liveview(session)
        guard rc == 0 else {
            throw FujiError.protocolError(
                operation: "EnterLiveView",
                code: rc,
                detail: lastErrorDetail(fallbackCode: rc)
            )
        }
    }

    /// Beendet Live-View und kehrt sauber in den Galerie-Modus zurueck, ohne das Kamera-WLAN zu trennen.
    func exitLiveView() throws -> FujiSessionInfo {
        guard let session else { throw FujiError.notConnected }
        var rawInfo = FujiBridgeSessionInfo()
        let rc = fuji_bridge_exit_liveview(session, &rawInfo)
        guard rc == 0 else {
            throw FujiError.protocolError(
                operation: "ExitLiveView",
                code: rc,
                detail: lastErrorDetail(fallbackCode: rc)
            )
        }
        return convertSessionInfo(rawInfo)
    }

    /// Liest den naechsten MJPEG-Live-View-Frame von Port 55742.
    /// Gibt `nil` zurueck, wenn aktuell noch kein neuer Frame bereitliegt.
    func readLiveViewFrame() throws -> Data? {
        guard let session else { throw FujiError.notConnected }
        var ptr: UnsafeMutablePointer<UInt8>?
        var length: UInt32 = 0
        let rc = fuji_bridge_read_liveview_frame(session, &ptr, &length)
        guard rc == 0 else {
            if let ptr { fuji_bridge_free_buffer(ptr) }
            throw FujiError.protocolError(
                operation: "ReadLiveViewFrame",
                code: rc,
                detail: lastErrorDetail(fallbackCode: rc)
            )
        }
        guard let buffer = ptr, length > 0 else {
            return nil
        }
        let data = Data(bytes: buffer, count: Int(length))
        fuji_bridge_free_buffer(buffer)
        return data
    }

    /// Fragt aktuelle Belichtungs- und Statuswerte (ISO, Blende, Zeit, Filmsimulation, Restfotos) ab.
    func fetchLiveViewStatus() throws -> FujiLiveViewStatus {
        guard let session else { throw FujiError.notConnected }
        var raw = FujiBridgeLiveViewStatus()
        let rc = fuji_bridge_get_liveview_status(session, &raw)
        guard rc == 0 else {
            throw FujiError.protocolError(
                operation: "GetLiveViewStatus",
                code: rc,
                detail: lastErrorDetail(fallbackCode: rc)
            )
        }
        return FujiLiveViewStatus(
            isoRaw: raw.iso,
            fNumberRaw: raw.fnumber,
            shutterSpeedRaw: raw.shutter_speed,
            filmSimulationRaw: raw.film_simulation,
            exposureBiasMillistops: raw.has_exposure_bias ? raw.exposure_bias : nil,
            whiteBalanceRaw: raw.white_balance,
            batteryLevel: raw.battery_level,
            shotsRemaining: raw.shots_remaining,
            movieRemainingSeconds: raw.movie_remaining_sec,
            isLiveViewActive: raw.liveview_active
        )
    }

    /// Loest ein Foto ueber WLAN aus (`PTP_OC_InitiateCapture`).
    func capturePhoto() throws {
        guard let session else { throw FujiError.notConnected }
        let rc = fuji_bridge_capture_photo(session)
        guard rc == 0 else {
            throw FujiError.protocolError(
                operation: "CapturePhoto",
                code: rc,
                detail: lastErrorDetail(fallbackCode: rc)
            )
        }
    }

    /// Startet oder stoppt eine Video-Aufnahme ueber WLAN (`0x9020` / `0x9021`).
    func setMovieRecording(_ start: Bool) throws {
        guard let session else { throw FujiError.notConnected }
        let rc = fuji_bridge_set_movie_recording(session, start)
        guard rc == 0 else {
            throw FujiError.protocolError(
                operation: start ? "StartMovie" : "StopMovie",
                code: rc,
                detail: lastErrorDetail(fallbackCode: rc)
            )
        }
    }

    /// Verstellt Verschlusszeit, Blende oder Belichtungskorrektur um einen Schritt nach oben/unten.
    func stepControl(_ kind: FujiStepControlKind, up: Bool) throws {
        guard let session else { throw FujiError.notConnected }
        let rawKind: FujiBridgeStepKind
        switch kind {
        case .shutterSpeed: rawKind = FUJI_BRIDGE_STEP_SHUTTER
        case .fNumber: rawKind = FUJI_BRIDGE_STEP_FNUMBER
        case .exposureBias: rawKind = FUJI_BRIDGE_STEP_EXPOSURE_BIAS
        }
        let rc = fuji_bridge_step_control(session, rawKind, up)
        guard rc == 0 else {
            throw FujiError.protocolError(
                operation: "StepControl(\(kind))",
                code: rc,
                detail: lastErrorDetail(fallbackCode: rc)
            )
        }
    }

    /// Liest die von der Kamera gemeldeten ISO-Optionen aus `GetPropertyDescriptors` (`0xD02A`).
    func supportedISOOptions() -> [FujiPropOption] {
        readPropOptions(propCode: 0xD02A).map { raw in
            FujiPropOption(rawValue: raw, label: FujiLiveViewStatus.formatISO(raw))
        }
    }

    /// Liest die von der Kamera gemeldeten Filmsimulationen aus `GetPropertyDescriptors` (`0xD001`).
    func supportedFilmSimulationOptions() -> [FujiPropOption] {
        readPropOptions(propCode: 0xD001).map { raw in
            FujiPropOption(rawValue: raw, label: FujiLiveViewStatus.formatFilmSimulation(raw))
        }
    }

    /// Setzt den ISO-Wert ueber PTP Property `0xD02A`.
    func setISO(_ rawValue: UInt32) throws {
        guard let session else { throw FujiError.notConnected }
        let rc = fuji_bridge_set_prop_u32(session, 0xD02A, rawValue)
        guard rc == 0 else {
            throw FujiError.protocolError(
                operation: "SetISO",
                code: rc,
                detail: lastErrorDetail(fallbackCode: rc)
            )
        }
    }

    /// Setzt die Filmsimulation ueber PTP Property `0xD001`.
    func setFilmSimulation(_ rawValue: UInt16) throws {
        guard let session else { throw FujiError.notConnected }
        let rc = fuji_bridge_set_prop_u16(session, 0xD001, rawValue)
        guard rc == 0 else {
            throw FujiError.protocolError(
                operation: "SetFilmSimulation",
                code: rc,
                detail: lastErrorDetail(fallbackCode: rc)
            )
        }
    }

    /// Wendet einen kameraseitigen Sternbewertungs-Filter (XApp `0xD603` -> `0xD621`) an.
    func applyCameraStarFilter(_ filter: FujiStarRatingFilter) throws -> FujiSessionInfo {
        guard let session else { throw FujiError.notConnected }
        var rawInfo = FujiBridgeSessionInfo()
        let rc = fuji_bridge_apply_star_filter(session, filter.rawValue, &rawInfo)
        guard rc == 0 else {
            throw FujiError.protocolError(
                operation: "ApplyStarFilter(\(filter.label))",
                code: rc,
                detail: lastErrorDetail(fallbackCode: rc)
            )
        }
        return convertSessionInfo(rawInfo)
    }

    private func readPropOptions(propCode: UInt16) -> [UInt32] {
        guard let session else { return [] }
        var buffer = [UInt32](repeating: 0, count: 128)
        var count: UInt32 = 0
        let rc = fuji_bridge_get_prop_options(session, propCode, &buffer, UInt32(buffer.count), &count)
        guard rc == 0, count > 0 else { return [] }
        return Array(buffer.prefix(Int(count)))
    }
}

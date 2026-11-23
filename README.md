# FujiTransfer

Eine schnelle, native iOS-App (SwiftUI, iOS 17+) und wiederverwendbare Swift-Bibliothek (`FujiCore`) zur direkten Kommunikation mit **Fujifilm-X-Kameras** (entwickelt und getestet mit einer **Fujifilm X-T4, Firmware 02.12**) – als schlanke, zuverlässige Open-Source-Alternative zur offiziellen Fujifilm XApp.

## Funktionen auf einen Blick

Die App trennt bewusst zwischen **schnellen, stromsparenden Bluetooth-Funktionen** und **bandbreitenintensiven WLAN-Funktionen** in drei klaren Tabs:

| Tab | Verbindung | Funktionen |
| --- | --- | --- |
| **Fotos** | **WLAN** | Galerie mit SD-Slot-Umschaltung (Slot 1 / 2), Vollbild-Zoom-Vorschau, Filter nach **Aufnahmedatum**, **Import-Status** (*Alle / Neu / Importiert*) und **Kamera-Sternen** (XApp), verlustfreier Original-JPEG-Import (z. B. 6240 × 4160 inkl. EXIF) direkt in Apple Fotos |
| **Live-View** | **WLAN** | Live-Sucherbild (MJPEG-Stream), Foto-Auslöser, Video-Aufnahme (Start/Stopp), Live-Telemetrie (Blende, Verschlusszeit, ISO, EV, Restfotos), schrittweise Belichtungssteuerung sowie ISO- & Filmsimulations-Auswahl |
| **BLE-Steuerung** | **nur Bluetooth (ohne WLAN)** | Sofort startklarer Fernauslöser (Einzelbild, Autofokus, Bulb mit Timer), Intervallometer / Zeitraffer, automatisches & manuelles GPS-Geotagging (Koordinaten & Höhe in EXIF), automatische Uhrzeit-Synchronisation, Kamera- & Objektiv-Info inkl. Live-Firmware-Prüfung gegen offizielle Fujifilm-Updates |

### Automatische Verbindungsübergabe zwischen den Tabs
Da Fujifilm-Kameras jeweils nur eine aktive Funk-Session (Bluetooth **oder** Kamera-WLAN) zulassen, übernimmt die App den Wechsel automatisch:
- **Bluetooth → WLAN:** Ist `BLE-Steuerung` verbunden, weckt *„WLAN direkt per BLE starten“* das Kamera-WLAN über die bestehende BLE-Verbindung und gibt Bluetooth danach sauber frei.
- **WLAN → Bluetooth:** Ein Tipp auf *„WLAN trennen & per Bluetooth verbinden“* beendet Live-View, schließt die PTP/IP-Session sauber (`CloseSession` + Goodbye) und verbindet nach kurzem Kamera-Wechsel per Bluetooth.
- **Fotos ↔ Live-View:** Beide Tabs teilen sich eine einzige offene WLAN-Session, damit die Kamera ihren Hotspot beim Wechsel nicht abschaltet.

---

## Voraussetzungen

- **Mac** mit Xcode 16+ (und optional [XcodeGen](https://github.com/yonaskolb/XcodeGen), falls `ios/project.yml` geändert wird)
- **iPhone** mit iOS 17 oder neuer
- **Fujifilm-Kamera** mit Bluetooth LE & WLAN (getestet mit **Fujifilm X-T4, FW 02.12**; sollte weitgehend auch mit anderen X-Trans-IV/V-Modellen mit XApp-/Wireless-PTP-Protokoll funktionieren)

---

## Installation auf dem iPhone

### 1. Projekt klonen und in Xcode öffnen
```bash
git clone https://github.com/ggfplanet/FujiTransfer.git
cd FujiTransfer
open ios/FujiTransfer.xcodeproj
```

### 2. Signing in Xcode einstellen
1. In Xcode links das Projekt **FujiTransfer** → Target **FujiTransfer** → Tab **Signing & Capabilities** öffnen.
2. Unter **Team** deine eigene Apple-ID (auch kostenloser Apple-Account reicht) auswählen.
3. Unter **Bundle Identifier** eine eigene eindeutige ID eintragen (z. B. `de.deinname.fujitransfer.app`).
4. iPhone verbinden, oben als Ziel auswählen und mit **Cmd + R** starten.
5. Beim ersten Start auf dem iPhone ggf. unter **Einstellungen → Allgemein → VPN & Geräteverwaltung** dem eigenen Entwicklerprofil vertrauen.

### Optional: 1-Klick-Refresh per Skript (alle 7 Tage bei kostenlosem Apple-Account)
```bash
cp .deploy.local.example .deploy.local
```
Trage in `.deploy.local` deine `DEVELOPMENT_TEAM`, `BUNDLE_ID` und `DEVICE_ID` (zu finden via `xcrun devicectl list devices`) ein. Danach kannst du die App jederzeit per Doppelklick oder Terminal neu signieren und drahtlos aufs iPhone laden:
```bash
./refresh-iphone.command
```
*(Die Datei `.deploy.local` steht in `.gitignore` und wird nicht in Git eingecheckt.)*

---

## Einrichtung an der Kamera (Fujifilm X-T4)

1. **Einmalig koppeln:**  
   An der Kamera **Einrichtung → Verbindungseinstellung → Bluetooth/Smartphone-Einstellung → Kopplungsregistrierung** öffnen und in der App im Tab **Fotos** auf **Koppeln** tippen. Danach das Kameramenü zurück in den normalen Liveview verlassen.
2. **Schnelle Fernsteuerung (nur Bluetooth):**  
   Kamera einfach einschalten → Tab **BLE-Steuerung** → **Per Bluetooth verbinden**.
3. **Fotos laden & Live-View (WLAN):**  
   Kamera einschalten → in der App **WLAN per BLE wecken** tippen → in den iOS-WLAN-Einstellungen mit dem Kamera-Hotspot (`FUJIFILM-X-T4-...`) verbinden → **Mit Kamera verbinden**.

> **Hinweis zu Live-View-Belichtung & Video:** Blende, Verschlusszeit und ISO lassen sich über WLAN nur verstellen, wenn die entsprechenden physischen Wahlräder an der Kamera auf Automatik/App-Steuerung (`A` / `T` / `C`) stehen. Für Video-Aufnahme muss der Still/Movie-Schalter der X-T4 auf `MOVIE` stehen.

---

## Mac-CLI-Tool (`fuji-probe`) & Tests

Das Swift-Package bringt zusätzlich ein Diagnose-CLI für macOS sowie Unit-Tests mit:

```bash
# Unit-Tests ausfuehren
swift test

# Bluetooth-Scan nach Fujifilm-Kameras
swift run fuji-probe ble-scan

# Kamera-WLAN per BLE wecken
swift run fuji-probe ble-wifi

# WLAN-Verbindung & Protokoll-Handshake testen
swift run fuji-probe probe --mode auto --verbose

# Fotos auflisten und herunterladen
swift run fuji-probe list --limit 15
swift run fuji-probe download --count 2 --thumb --out ./downloads
```

---

## Projektstruktur

```text
.
├── Package.swift                 # Swift Package (macOS 14+ & iOS 17+)
├── Sources/
│   ├── CFujiBridge/              # C-Bridge (PTP/IP, Live-View-Stream, Socket-Binding, Filter)
│   ├── FujiCore/                 # Wiederverwendbare Swift-Library (WLAN PTP/IP + CoreBluetooth BLE)
│   └── fuji-probe/               # macOS CLI-Diagnosetool
├── Tests/
│   └── FujiCoreTests/            # Unit-Tests fuer FujiCore & CFujiBridge
├── ios/
│   ├── project.yml               # XcodeGen-Projektdefinition (ohne persoenliche IDs)
│   ├── FujiTransfer.xcodeproj/   # Generiertes Xcode-Projekt
│   └── FujiTransfer/             # Native SwiftUI iPhone-App (Models, Services, Views)
├── vendor/
│   └── libfuji/                  # Vendored Open-Source-Protokollbasis (libfuji + libpict)
├── refresh-iphone.command        # Optionales lokales Build-/Signier-Skript (liest .deploy.local)
├── .deploy.local.example         # Vorlage fuer lokale Signing-Werte
├── LICENSE                       # MIT-Lizenz
└── THIRD_PARTY_LICENSES.md       # Drittanbieter-Lizenzen
```

---

## Architektur & Danksagung

Das Fujifilm-Protokoll (PTP/IP über TCP-Ports `55740–55742` sowie die Bluetooth-LE-GATT-Services) basiert auf der offenen Reverse-Engineering-Arbeit von:
- **[petabyt/libfuji](https://github.com/petabyt/libfuji)** (MIT-Lizenz)
- **[petabyt/camlib (`libpict`)](https://github.com/petabyt/camlib)** (Apache-2.0-Lizenz)

Die C-Bridge (`CFujiBridge`), der komplette native Apple-`CoreBluetooth`-Stack (`FujiBLEManager`, `FujiBLESession`), die Swift-API (`FujiCore`), die Live-View-Steuerung und die gesamte SwiftUI-iOS-App (`FujiTransfer`) wurden eigens für dieses Projekt entwickelt.

Siehe [LICENSE](LICENSE) und [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) für vollständige Lizenzangaben.

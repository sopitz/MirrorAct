// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation

/// Aussehen eines Geräts: Bildschirmecken, Notch/Dynamic Island/Kameraloch, Home-Button.
/// Alle Verhältnisse beziehen sich auf die Bildschirmbreite im Hochformat.
/// Die Tabellen dazu stehen in `Shared/DeviceProfiles.json`, gemeinsam mit den anderen MirrorAct-Apps.
struct DeviceProfile: Equatable {
    enum Family: Equatable { case iPhone, iPad, android }

    enum Cutout: Equatable {
        case none
        case notch(width: CGFloat, height: CGFloat)
        case island(width: CGFloat, height: CGFloat, top: CGFloat)
        /// rundes Kameraloch (Android), Mittelpunkt von links/oben
        case hole(centerX: CGFloat, centerY: CGFloat, diameter: CGFloat)
    }

    var family: Family
    var marketingName: String?
    var homeButton: Bool
    var cutout: Cutout
    var screenCornerRatio: CGFloat
    /// Bildschirmgrösse in iOS-Punkten (Hochformat), für "Tatsächliche Grösse"
    var pointSize: CGSize?
    /// physische Pixelbreite und Pixeldichte des Displays, für "Lebensgross"
    var nativePixelWidth: CGFloat?
    var ppi: CGFloat?

    /// Breite des Bildschirms in Millimetern (Hochformat)
    var physicalWidthMM: CGFloat? {
        guard let px = nativePixelWidth, let ppi, ppi > 0 else { return nil }
        return px / ppi * 25.4
    }

    var displayName: String {
        if let marketingName { return marketingName }
        switch family {
        case .iPhone: return "iPhone"
        case .iPad: return "iPad"
        case .android: return "Android"
        }
    }

    // MARK: Gemeinsame Tabelle

    /// Inhalt von `Shared/DeviceProfiles.json`, einmal dekodiert. Ohne die Tabelle kann die App
    /// nicht arbeiten, darum bricht ein Fehler beim Laden hart ab.
    private static let table: DeviceProfileTable = {
        let url: URL
        if let bundled = Bundle.main.url(forResource: "DeviceProfiles", withExtension: "json") {
            url = bundled
        } else if let path = ProcessInfo.processInfo.environment["MIRRORACT_DEVICE_PROFILES"], !path.isEmpty {
            url = URL(fileURLWithPath: path)
        } else {
            fatalError("DeviceProfiles.json is missing: neither bundled as a resource nor named in MIRRORACT_DEVICE_PROFILES")
        }
        let table: DeviceProfileTable
        do {
            table = try JSONDecoder().decode(DeviceProfileTable.self, from: Data(contentsOf: url))
        } catch {
            fatalError("Cannot read the device profiles \(url.path): \(error)")
        }
        if let problem = table.problem {
            fatalError("Malformed device profiles \(url.path): \(problem)")
        }
        return table
    }()

    private static func cutout(_ name: String) -> Cutout {
        // Vorhandensein wurde beim Laden geprüft
        table.cutouts[name]!.cutout
    }

    private static func phone(_ name: String?, _ cutout: Cutout, corner: CGFloat, points: CGSize?,
                              pixels: CGFloat? = nil, ppi: CGFloat? = nil) -> DeviceProfile {
        DeviceProfile(family: .iPhone, marketingName: name, homeButton: false, cutout: cutout,
                      screenCornerRatio: corner, pointSize: points,
                      nativePixelWidth: pixels ?? points.map { $0.width * 3 },
                      ppi: ppi ?? table.fallbacks.defaultPhonePpi)
    }

    private static func homeButtonPhone(_ name: String?, points: CGSize?, pixels: CGFloat? = nil,
                                        ppi: CGFloat? = nil) -> DeviceProfile {
        DeviceProfile(family: .iPhone, marketingName: name, homeButton: true, cutout: .none,
                      screenCornerRatio: 0, pointSize: points,
                      nativePixelWidth: pixels ?? points.map { $0.width * 2 },
                      ppi: ppi ?? table.fallbacks.defaultHomeButtonPhonePpi)
    }

    private static func pad(_ name: String?, homeButton: Bool, corner: CGFloat, points: CGSize?,
                            ppi: CGFloat? = nil) -> DeviceProfile {
        DeviceProfile(family: .iPad, marketingName: name, homeButton: homeButton, cutout: .none,
                      screenCornerRatio: homeButton ? 0 : corner, pointSize: points,
                      nativePixelWidth: points.map { $0.width * 2 },
                      ppi: ppi ?? table.fallbacks.defaultPadPpi)
    }

    /// Tabelleneintrag → Profil; `pixels` ist die Bildschirmgrösse für Einträge mit `scale` statt `points`
    private static func profile(_ entry: DeviceProfileTable.Entry, pixels: (width: Int, height: Int)? = nil) -> DeviceProfile {
        // Namen stehen englisch in der Tabelle; der String Catalog übersetzt die, die er kennt
        let name = entry.name.map { String(localized: String.LocalizationValue($0)) }
        var points = entry.points.map { CGSize(width: $0[0], height: $0[1]) }
        if points == nil, let scale = entry.scale, let pixels {
            points = CGSize(width: CGFloat(pixels.width) / scale, height: CGFloat(pixels.height) / scale)
        }
        if entry.family == .iPad {
            return pad(name, homeButton: entry.homeButton, corner: entry.corner, points: points, ppi: entry.ppi)
        }
        if entry.homeButton {
            return homeButtonPhone(name, points: points, pixels: entry.pixels, ppi: entry.ppi)
        }
        return phone(name, entry.cutout.map(cutout) ?? .none, corner: entry.corner, points: points,
                     pixels: entry.pixels, ppi: entry.ppi)
    }

    /// Android-Gerät nach seinen eigenen Angaben (Pixel, dpi-Stufe, Aussparung, Eckenradius)
    static func android(name: String?, screenPixels: CGSize? = nil, densityDpi: CGFloat? = nil, ppi: CGFloat? = nil,
                        cutoutRect: CGRect? = nil, cornerRadius: CGFloat? = nil) -> DeviceProfile {
        let defaults = table.android
        var cutout = Cutout.hole(centerX: defaults.hole.centerX, centerY: defaults.hole.centerY, diameter: defaults.hole.diameter)
        var corner = defaults.corner
        var points: CGSize?
        if let pixels = screenPixels, pixels.width > 0 {
            let W = pixels.width
            if let rect = cutoutRect, rect.width > 0, rect.height > 0 {
                // freistehend und quadratisch: das Loch selbst; am Rand anliegend oder höher als breit:
                // eine Begrenzung mit Abstand, das Loch ist kleiner
                let square = abs(rect.width - rect.height) < 0.2 * max(rect.width, rect.height)
                let diameter = min(rect.width, rect.height) * (square && rect.minY > 0 ? 1 : 0.65)
                cutout = .hole(centerX: rect.midX / W, centerY: rect.midY / W, diameter: diameter / W)
            }
            if let cornerRadius, cornerRadius > 0 { corner = cornerRadius / W }
            if let densityDpi, densityDpi > 0 {
                points = CGSize(width: pixels.width * 160 / densityDpi, height: pixels.height * 160 / densityDpi)
            }
        }
        return DeviceProfile(family: .android, marketingName: name, homeButton: false, cutout: cutout,
                             screenCornerRatio: corner, pointSize: points, nativePixelWidth: screenPixels?.width,
                             ppi: ppi)
    }

    /// Modellkennung (z. B. "iPhone14,2") → Profil
    static func forModelIdentifier(_ identifier: String) -> DeviceProfile? {
        if let entry = table.models[identifier] {
            return profile(entry)
        }
        let fallbacks = table.fallbacks
        if identifier.hasPrefix("android") {
            return android(name: nil)
        }
        if identifier.hasPrefix("iPad") {
            return pad(nil, homeButton: false, corner: fallbacks.iPadCorner, points: nil)
        }
        // neuere, hier nicht aufgeführte iPhones haben eine Dynamic Island
        if identifier.hasPrefix("iPhone"),
           let major = Int(identifier.dropFirst(6).split(separator: ",").first ?? ""), major >= fallbacks.islandFromMajor {
            return phone(nil, cutout("island"), corner: fallbacks.islandCorner, points: nil)
        }
        return nil
    }

    /// Bildschirmauflösung in Pixeln (beliebige Ausrichtung) → Profil
    static func forScreenPixels(_ size: CGSize) -> DeviceProfile? {
        let w = Int(min(size.width, size.height).rounded()), h = Int(max(size.width, size.height).rounded())
        guard let entry = table.byPixels["\(w)x\(h)"] else { return nil }
        return profile(entry, pixels: (w, h))
    }

    /// Fallback über das Seitenverhältnis (z. B. skalierte AirPlay-Ströme)
    static func forAspect(_ size: CGSize) -> DeviceProfile {
        let ratio = max(size.width, size.height) / max(1, min(size.width, size.height))
        let aspect = table.byAspect
        if ratio < aspect.padBelow {
            return pad(nil, homeButton: ratio < aspect.padHomeBelow, corner: table.fallbacks.iPadCorner, points: nil)
        }
        if ratio < aspect.homeButtonPhoneBelow {
            return homeButtonPhone(nil, points: nil)
        }
        return phone(nil, cutout("island"), corner: aspect.islandCorner, points: nil)
    }

    /// Auswahl im Editor (neueste zuerst); "auto" = nach Auflösung
    static let selectableModels: [(id: String, name: String)] = {
        var list = table.selectable.models.compactMap { id in
            forModelIdentifier(id)?.marketingName.map { (id: id, name: $0) }
        }
        for pad in table.selectable.pads {
            list.append((id: pad.id, name: String(localized: String.LocalizationValue(pad.name))))
        }
        return list
    }()

    static func profile(forSelection id: String) -> DeviceProfile? {
        if let generic = table.selectable.pads.first(where: { $0.id == id }) {
            return pad("iPad", homeButton: generic.homeButton, corner: generic.corner, points: nil)
        }
        return forModelIdentifier(id)
    }

    /// Bestes verfügbares Profil
    static func resolve(modelIdentifier: String?, screenPixels: CGSize?, frameSize: CGSize) -> DeviceProfile {
        var profile: DeviceProfile?
        if let id = modelIdentifier { profile = forModelIdentifier(id) }
        if profile == nil, let px = screenPixels { profile = forScreenPixels(px) }
        if profile == nil { profile = forScreenPixels(frameSize) }
        return profile ?? forAspect(frameSize)
    }
}

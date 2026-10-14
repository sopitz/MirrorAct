// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation

/// Inhalt von `Shared/DeviceProfiles.json`: die Gerätetabellen, die alle MirrorAct-Apps teilen.
/// Nur Daten; die Profile daraus baut `DeviceProfile`.
struct DeviceProfileTable: Decodable {
    /// Aussparung oben im Bildschirm, benannt (z. B. "notch13", "island", ein Kameraloch "hole")
    struct CutoutSpec: Decodable {
        var type: String
        var width: CGFloat?
        var height: CGFloat?
        var top: CGFloat?
        /// nur "hole": Mittelpunkt von links/oben und Durchmesser
        var centerX: CGFloat?
        var centerY: CGFloat?
        var diameter: CGFloat?

        static let knownTypes = ["notch", "island", "hole"]

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case type, width, height, top, centerX, centerY, diameter
        }

        init(from decoder: Decoder) throws {
            try rejectUnknownKeys(in: decoder, allowed: CodingKeys.allCases.map(\.stringValue))
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decode(String.self, forKey: .type)
            width = try c.decodeIfPresent(CGFloat.self, forKey: .width)
            height = try c.decodeIfPresent(CGFloat.self, forKey: .height)
            top = try c.decodeIfPresent(CGFloat.self, forKey: .top)
            centerX = try c.decodeIfPresent(CGFloat.self, forKey: .centerX)
            centerY = try c.decodeIfPresent(CGFloat.self, forKey: .centerY)
            diameter = try c.decodeIfPresent(CGFloat.self, forKey: .diameter)
        }

        var cutout: DeviceProfile.Cutout {
            switch type {
            case "notch": return .notch(width: width ?? 0, height: height ?? 0)
            case "island": return .island(width: width ?? 0, height: height ?? 0, top: top ?? 0)
            case "hole": return .hole(centerX: centerX ?? 0, centerY: centerY ?? 0, diameter: diameter ?? 0)
            default: return .none
            }
        }

        /// Beschreibung des ersten Fehlers, nil wenn die Angaben zum Typ passen
        var problem: String? {
            let required: [(String, CGFloat?)]
            switch type {
            case "notch": required = [("width", width), ("height", height)]
            case "island": required = [("width", width), ("height", height), ("top", top)]
            case "hole": required = [("centerX", centerX), ("centerY", centerY), ("diameter", diameter)]
            default: return "has the unknown type \(type) (known: \(Self.knownTypes.joined(separator: ", ")))"
            }
            let missing = required.filter { $0.1 == nil }.map(\.0)
            if !missing.isEmpty {
                return "has type \(type) with missing values: \(missing.joined(separator: ", "))"
            }
            return nil
        }
    }

    /// Ein iPhone oder iPad in `models` oder `byPixels`
    struct Entry: Decodable {
        var family: DeviceProfile.Family = .iPhone
        var name: String?
        var homeButton = false
        var cutout: String?
        var corner: CGFloat = 0
        /// Bildschirm in Punkten (Hochformat); fehlt er, ergibt er sich aus Pixeln / `scale`
        var points: [CGFloat]?
        var scale: CGFloat?
        /// physische Pixelbreite, falls nicht Punkte × 3 (Notch/Island) bzw. × 2 (Home-Button);
        /// nur für iPhones, iPads rechnen immer Punkte × 2
        var pixels: CGFloat?
        var ppi: CGFloat?

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case family, name, homeButton, cutout, corner, points, scale, pixels, ppi
        }

        init(from decoder: Decoder) throws {
            // ein vertippter Schlüssel fiele sonst still auf den Standardwert zurück
            try rejectUnknownKeys(in: decoder, allowed: CodingKeys.allCases.map(\.stringValue))
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let family = try c.decodeIfPresent(String.self, forKey: .family) {
                switch family {
                case "iPhone": self.family = .iPhone
                case "iPad": self.family = .iPad
                default:
                    throw DecodingError.dataCorruptedError(forKey: .family, in: c, debugDescription: "unknown family \(family)")
                }
            }
            name = try c.decodeIfPresent(String.self, forKey: .name)
            homeButton = try c.decodeIfPresent(Bool.self, forKey: .homeButton) ?? false
            cutout = try c.decodeIfPresent(String.self, forKey: .cutout)
            corner = try c.decodeIfPresent(CGFloat.self, forKey: .corner) ?? 0
            points = try c.decodeIfPresent([CGFloat].self, forKey: .points)
            scale = try c.decodeIfPresent(CGFloat.self, forKey: .scale)
            pixels = try c.decodeIfPresent(CGFloat.self, forKey: .pixels)
            ppi = try c.decodeIfPresent(CGFloat.self, forKey: .ppi)
        }
    }

    /// Unbekannte Kennungen und Standardwerte
    struct Fallbacks: Decodable {
        var islandFromMajor: Int
        var islandCorner: CGFloat
        var iPadCorner: CGFloat
        var defaultPhonePpi: CGFloat
        var defaultHomeButtonPhonePpi: CGFloat
        var defaultPadPpi: CGFloat
    }

    /// Letzter Ausweg über das Seitenverhältnis (lange Seite / kurze Seite)
    struct ByAspect: Decodable {
        var padHomeBelow: CGFloat
        var padBelow: CGFloat
        var homeButtonPhoneBelow: CGFloat
        var islandCorner: CGFloat
    }

    /// Vorgaben für Android-Geräte
    struct Android: Decodable {
        struct Hole: Decodable {
            var centerX: CGFloat
            var centerY: CGFloat
            var diameter: CGFloat
        }
        var hole: Hole
        var corner: CGFloat
    }

    /// Modellauswahl im Editor
    struct Selectable: Decodable {
        struct Pad: Decodable {
            var id: String
            var name: String
            var homeButton: Bool
            var corner: CGFloat
        }
        var models: [String]
        var pads: [Pad]
    }

    /// Wörterbuch mit Einträgen, in dem ein "comment"-Schlüssel erlaubt ist
    struct Entries<Value: Decodable>: Decodable {
        var entries: [String: Value] = [:]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            for key in c.allKeys where key.stringValue != "comment" {
                entries[key.stringValue] = try c.decode(Value.self, forKey: key)
            }
        }

        subscript(key: String) -> Value? { entries[key] }
    }

    static let supportedVersion = 1

    var version: Int
    var cutouts: Entries<CutoutSpec>
    var models: Entries<Entry>
    var fallbacks: Fallbacks
    var byPixels: Entries<Entry>
    var byAspect: ByAspect
    var android: Android
    var selectable: Selectable

    /// Beschreibung des ersten inhaltlichen Fehlers, nil wenn die Tabelle stimmig ist
    var problem: String? {
        if version != Self.supportedVersion {
            return "version \(version) is not supported (expected \(Self.supportedVersion))"
        }
        for (name, spec) in cutouts.entries.sorted(by: { $0.key < $1.key }) {
            if let problem = spec.problem { return "cutout \(name) \(problem)" }
        }
        if cutouts["island"] == nil {
            return "cutout island is missing"
        }
        for (table, entries) in [("models", models.entries), ("byPixels", byPixels.entries)] {
            for (key, entry) in entries.sorted(by: { $0.key < $1.key }) {
                if let problem = entry.problem(in: self) { return "\(table) \(key) \(problem)" }
                if table == "byPixels" {
                    guard Self.pixelKey(key) != nil else {
                        return "byPixels \(key) is not a portrait pixel size WxH (width ≤ height, no leading zeros)"
                    }
                    if entry.points == nil, entry.scale == nil {
                        return "byPixels \(key) needs points or scale"
                    }
                }
            }
        }
        for id in selectable.models where models[id]?.name == nil {
            return "selectable model \(id) has no entry with a name"
        }
        return nil
    }

    /// "1170x2532" → (1170, 2532), so wie `DeviceProfile.forScreenPixels` den Schlüssel bildet
    static func pixelKey(_ key: String) -> (width: Int, height: Int)? {
        let parts = key.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]),
              w > 0, w <= h, "\(w)x\(h)" == key else { return nil }
        return (w, h)
    }
}

extension DeviceProfileTable.Entry {
    /// Fehler eines einzelnen Eintrags, nil wenn er stimmig ist
    func problem(in table: DeviceProfileTable) -> String? {
        if let cutout, table.cutouts[cutout] == nil {
            return "refers to the unknown cutout \(cutout)"
        }
        if let points, points.count != 2 || points.contains(where: { $0 <= 0 }) {
            return "needs points as [width, height], both above 0"
        }
        if let scale, scale <= 0 {
            return "needs a scale above 0"
        }
        if let pixels, pixels <= 0 {
            return "needs pixels above 0"
        }
        if let ppi, ppi <= 0 {
            return "needs a ppi above 0"
        }
        if family == .iPad {
            if pixels != nil { return "is an iPad; pixels applies to iPhones only (iPads use points × 2)" }
            if cutout != nil { return "is an iPad; iPads have no cutout" }
        } else if homeButton {
            if cutout != nil { return "has a home button and therefore no cutout" }
        } else if cutout == nil {
            return "needs a cutout (iPhones without a home button have a notch or an island)"
        }
        return nil
    }
}

/// Beliebiger Schlüssel eines JSON-Objekts
private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Wirft bei Schlüsseln ausserhalb von `allowed`, damit Tippfehler in der Tabelle auffallen
private func rejectUnknownKeys(in decoder: Decoder, allowed: [String]) throws {
    let c = try decoder.container(keyedBy: AnyKey.self)
    for key in c.allKeys where !allowed.contains(key.stringValue) {
        throw DecodingError.dataCorruptedError(
            forKey: key, in: c,
            debugDescription: "unknown key \(key.stringValue) (allowed: \(allowed.joined(separator: ", ")))")
    }
}

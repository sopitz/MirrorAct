// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation

/// Inhalt von `Shared/DeviceProfiles.json`: die Gerätetabellen, die alle MirrorAct-Apps teilen.
/// Nur Daten; die Profile daraus baut `DeviceProfile`.
struct DeviceProfileTable: Decodable {
    /// Aussparung oben im Bildschirm, benannt (z. B. "notch13", "island")
    struct CutoutSpec: Decodable {
        var type: String
        var width: CGFloat?
        var height: CGFloat?
        var top: CGFloat?

        var cutout: DeviceProfile.Cutout {
            switch type {
            case "notch": return .notch(width: width ?? 0, height: height ?? 0)
            case "island": return .island(width: width ?? 0, height: height ?? 0, top: top ?? 0)
            default: return .none
            }
        }

        var isValid: Bool {
            switch type {
            case "notch": return width != nil && height != nil
            case "island": return width != nil && height != nil && top != nil
            default: return false
            }
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
        /// physische Pixelbreite, falls nicht Punkte × 3 (Phone) bzw. × 2 (Home-Button, iPad)
        var pixels: CGFloat?
        var ppi: CGFloat?

        private enum CodingKeys: String, CodingKey {
            case family, name, homeButton, cutout, corner, points, scale, pixels, ppi
        }

        init(from decoder: Decoder) throws {
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

        private struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
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
        for (name, spec) in cutouts.entries where !spec.isValid {
            return "cutout \(name) has type \(spec.type) with missing values"
        }
        if cutouts["island"] == nil {
            return "cutout island is missing"
        }
        for (table, entries) in [("models", models.entries), ("byPixels", byPixels.entries)] {
            for (key, entry) in entries {
                if let cutout = entry.cutout, cutouts[cutout] == nil {
                    return "\(table) \(key) refers to the unknown cutout \(cutout)"
                }
                if let points = entry.points, points.count != 2 {
                    return "\(table) \(key) needs points as [width, height]"
                }
                if table == "byPixels", entry.points == nil, entry.scale == nil {
                    return "byPixels \(key) needs points or scale"
                }
            }
        }
        for id in selectable.models where models[id]?.name == nil {
            return "selectable model \(id) has no entry with a name"
        }
        return nil
    }
}

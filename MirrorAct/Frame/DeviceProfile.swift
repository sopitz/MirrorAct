// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation

/// Aussehen eines Geräts: Bildschirmecken, Notch/Dynamic Island/Kameraloch, Home-Button.
/// Alle Verhältnisse beziehen sich auf die Bildschirmbreite im Hochformat.
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

    // MARK: Bekannte Bauformen

    private static let notch13 = Cutout.notch(width: 0.415, height: 0.085)   // iPhone 13, 13 Pro, 14, 16e
    private static let notch12 = Cutout.notch(width: 0.536, height: 0.082)   // iPhone 12-Reihe
    private static let notchX = Cutout.notch(width: 0.557, height: 0.080)    // X, XS, 11 Pro
    private static let notchMax = Cutout.notch(width: 0.505, height: 0.073)  // XS Max, 11 Pro Max
    private static let notchXR = Cutout.notch(width: 0.565, height: 0.073)   // XR, 11
    private static let island = Cutout.island(width: 0.320, height: 0.095, top: 0.029)

    private static func phone(_ name: String?, _ cutout: Cutout, corner: CGFloat, points: CGSize?,
                              pixels: CGFloat? = nil, ppi: CGFloat? = 460) -> DeviceProfile {
        DeviceProfile(family: .iPhone, marketingName: name, homeButton: false, cutout: cutout,
                      screenCornerRatio: corner, pointSize: points,
                      nativePixelWidth: pixels ?? points.map { $0.width * 3 }, ppi: ppi)
    }

    private static func homeButtonPhone(_ name: String?, points: CGSize?, pixels: CGFloat? = nil,
                                        ppi: CGFloat? = 326) -> DeviceProfile {
        DeviceProfile(family: .iPhone, marketingName: name, homeButton: true, cutout: .none,
                      screenCornerRatio: 0, pointSize: points,
                      nativePixelWidth: pixels ?? points.map { $0.width * 2 }, ppi: ppi)
    }

    private static func pad(_ name: String?, homeButton: Bool, corner: CGFloat, points: CGSize?,
                            ppi: CGFloat? = 264) -> DeviceProfile {
        DeviceProfile(family: .iPad, marketingName: name, homeButton: homeButton, cutout: .none,
                      screenCornerRatio: homeButton ? 0 : corner, pointSize: points,
                      nativePixelWidth: points.map { $0.width * 2 }, ppi: ppi)
    }

    /// Android-Gerät nach seinen eigenen Angaben (Pixel, dpi-Stufe, Aussparung, Eckenradius)
    static func android(name: String?, screenPixels: CGSize? = nil, densityDpi: CGFloat? = nil, ppi: CGFloat? = nil,
                        cutoutRect: CGRect? = nil, cornerRadius: CGFloat? = nil) -> DeviceProfile {
        var cutout = Cutout.hole(centerX: 0.5, centerY: 0.045, diameter: 0.034)
        var corner: CGFloat = 0.085
        var points: CGSize?
        if let pixels = screenPixels, pixels.width > 0 {
            let W = pixels.width
            if let rect = cutoutRect, rect.width > 0, rect.height > 0 {
                // quadratisch: das Loch selbst (Samsung); höher als breit: reicht bis zum oberen Rand (Pixel)
                let square = abs(rect.width - rect.height) < 0.2 * max(rect.width, rect.height)
                let diameter = min(rect.width, rect.height) * (square ? 1 : 0.85)
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
        let p390 = CGSize(width: 390, height: 844), p428 = CGSize(width: 428, height: 926)
        let p375 = CGSize(width: 375, height: 812), p414 = CGSize(width: 414, height: 896)
        let p393 = CGSize(width: 393, height: 852), p430 = CGSize(width: 430, height: 932)
        let p402 = CGSize(width: 402, height: 874), p440 = CGSize(width: 440, height: 956)
        let p375se = CGSize(width: 375, height: 667)

        switch identifier {
        case "iPhone10,3", "iPhone10,6": return phone("iPhone X", notchX, corner: 0.104, points: p375, ppi: 458)
        case "iPhone11,2": return phone("iPhone XS", notchX, corner: 0.104, points: p375, ppi: 458)
        case "iPhone11,4", "iPhone11,6": return phone("iPhone XS Max", notchMax, corner: 0.096, points: p414, ppi: 458)
        case "iPhone11,8": return phone("iPhone XR", notchXR, corner: 0.100, points: p414, pixels: 828, ppi: 326)
        case "iPhone12,1": return phone("iPhone 11", notchXR, corner: 0.100, points: p414, pixels: 828, ppi: 326)
        case "iPhone12,3": return phone("iPhone 11 Pro", notchX, corner: 0.104, points: p375, ppi: 458)
        case "iPhone12,5": return phone("iPhone 11 Pro Max", notchMax, corner: 0.096, points: p414, ppi: 458)
        case "iPhone12,8": return homeButtonPhone(String(localized: "iPhone SE (2nd generation)"), points: p375se)
        case "iPhone13,1": return phone("iPhone 12 mini", notchX, corner: 0.117, points: p375, pixels: 1080, ppi: 476)
        case "iPhone13,2": return phone("iPhone 12", notch12, corner: 0.121, points: p390)
        case "iPhone13,3": return phone("iPhone 12 Pro", notch12, corner: 0.121, points: p390)
        case "iPhone13,4": return phone("iPhone 12 Pro Max", .notch(width: 0.488, height: 0.075), corner: 0.125, points: p428, ppi: 458)
        case "iPhone14,4": return phone("iPhone 13 mini", .notch(width: 0.450, height: 0.092), corner: 0.117, points: p375, pixels: 1080, ppi: 476)
        case "iPhone14,5": return phone("iPhone 13", notch13, corner: 0.121, points: p390)
        case "iPhone14,2": return phone("iPhone 13 Pro", notch13, corner: 0.121, points: p390)
        case "iPhone14,3": return phone("iPhone 13 Pro Max", .notch(width: 0.379, height: 0.077), corner: 0.125, points: p428, ppi: 458)
        case "iPhone14,6": return homeButtonPhone(String(localized: "iPhone SE (3rd generation)"), points: p375se)
        case "iPhone14,7": return phone("iPhone 14", notch13, corner: 0.121, points: p390)
        case "iPhone14,8": return phone("iPhone 14 Plus", .notch(width: 0.379, height: 0.077), corner: 0.125, points: p428, ppi: 458)
        case "iPhone15,2": return phone("iPhone 14 Pro", island, corner: 0.140, points: p393)
        case "iPhone15,3": return phone("iPhone 14 Pro Max", island, corner: 0.128, points: p430)
        case "iPhone15,4": return phone("iPhone 15", island, corner: 0.140, points: p393)
        case "iPhone15,5": return phone("iPhone 15 Plus", island, corner: 0.128, points: p430)
        case "iPhone16,1": return phone("iPhone 15 Pro", island, corner: 0.140, points: p393)
        case "iPhone16,2": return phone("iPhone 15 Pro Max", island, corner: 0.128, points: p430)
        case "iPhone17,3": return phone("iPhone 16", island, corner: 0.140, points: p393)
        case "iPhone17,4": return phone("iPhone 16 Plus", island, corner: 0.128, points: p430)
        case "iPhone17,1": return phone("iPhone 16 Pro", island, corner: 0.154, points: p402)
        case "iPhone17,2": return phone("iPhone 16 Pro Max", island, corner: 0.141, points: p440)
        case "iPhone17,5": return phone("iPhone 16e", notch13, corner: 0.121, points: p390)
        default:
            if identifier.hasPrefix("android") {
                return android(name: nil)
            }
            if identifier.hasPrefix("iPad") {
                return pad(nil, homeButton: false, corner: 0.022, points: nil)
            }
            // neuere, hier nicht aufgeführte iPhones haben eine Dynamic Island
            if identifier.hasPrefix("iPhone"),
               let major = Int(identifier.dropFirst(6).split(separator: ",").first ?? ""), major >= 18 {
                return phone(nil, island, corner: 0.150, points: nil)
            }
            return nil
        }
    }

    /// Bildschirmauflösung in Pixeln (beliebige Ausrichtung) → Profil
    static func forScreenPixels(_ size: CGSize) -> DeviceProfile? {
        let w = Int(min(size.width, size.height).rounded()), h = Int(max(size.width, size.height).rounded())
        switch (w, h) {
        case (1125, 2436): return phone("iPhone X/XS/11 Pro", notchX, corner: 0.104, points: CGSize(width: 375, height: 812), ppi: 458)
        case (1242, 2688): return phone("iPhone XS Max/11 Pro Max", notchMax, corner: 0.096, points: CGSize(width: 414, height: 896), ppi: 458)
        case (828, 1792): return phone("iPhone XR/11", notchXR, corner: 0.100, points: CGSize(width: 414, height: 896), pixels: 828, ppi: 326)
        case (1080, 2340): return phone("iPhone mini", .notch(width: 0.480, height: 0.088), corner: 0.117, points: CGSize(width: 375, height: 812), pixels: 1080, ppi: 476)
        case (1170, 2532): return phone(nil, notch13, corner: 0.121, points: CGSize(width: 390, height: 844))
        case (1284, 2778): return phone(nil, .notch(width: 0.379, height: 0.077), corner: 0.125, points: CGSize(width: 428, height: 926), ppi: 458)
        case (1179, 2556): return phone(nil, island, corner: 0.140, points: CGSize(width: 393, height: 852))
        case (1290, 2796): return phone(nil, island, corner: 0.128, points: CGSize(width: 430, height: 932))
        case (1206, 2622): return phone(nil, island, corner: 0.154, points: CGSize(width: 402, height: 874))
        case (1320, 2868): return phone(nil, island, corner: 0.141, points: CGSize(width: 440, height: 956))
        case (1260, 2736): return phone(nil, island, corner: 0.150, points: CGSize(width: 420, height: 912))
        case (750, 1334), (640, 1136), (1080, 1920), (1242, 2208):
            return homeButtonPhone(nil, points: CGSize(width: CGFloat(w) / (w >= 1080 ? 3 : 2),
                                                        height: CGFloat(h) / (w >= 1080 ? 3 : 2)))
        case (1668, 2388), (2048, 2732), (1640, 2360), (1488, 2266), (1668, 2420), (2064, 2752), (1620, 2360):
            return pad(nil, homeButton: false, corner: w == 1488 ? 0.029 : 0.022,
                       points: CGSize(width: CGFloat(w) / 2, height: CGFloat(h) / 2), ppi: w == 1488 ? 326 : 264)
        case (1536, 2048), (1620, 2160), (1668, 2224):
            return pad(nil, homeButton: true, corner: 0, points: CGSize(width: CGFloat(w) / 2, height: CGFloat(h) / 2))
        default:
            return nil
        }
    }

    /// Fallback über das Seitenverhältnis (z. B. skalierte AirPlay-Ströme)
    static func forAspect(_ size: CGSize) -> DeviceProfile {
        let ratio = max(size.width, size.height) / max(1, min(size.width, size.height))
        if ratio < 1.6 {
            return pad(nil, homeButton: ratio < 1.36, corner: 0.022, points: nil)
        }
        if ratio < 1.9 {
            return homeButtonPhone(nil, points: nil)
        }
        return phone(nil, island, corner: 0.140, points: nil)
    }

    /// Auswahl im Editor (neueste zuerst); "auto" = nach Auflösung
    static let selectableModels: [(id: String, name: String)] = {
        let ids = ["iPhone17,2", "iPhone17,1", "iPhone17,4", "iPhone17,3", "iPhone17,5",
                   "iPhone16,2", "iPhone16,1", "iPhone15,5", "iPhone15,4", "iPhone15,3", "iPhone15,2",
                   "iPhone14,8", "iPhone14,7", "iPhone14,3", "iPhone14,2", "iPhone14,5", "iPhone14,4",
                   "iPhone13,4", "iPhone13,3", "iPhone13,2", "iPhone13,1",
                   "iPhone12,5", "iPhone12,3", "iPhone12,1", "iPhone11,8", "iPhone11,6", "iPhone11,2", "iPhone10,3",
                   "iPhone14,6", "iPhone12,8"]
        var list = ids.compactMap { id in forModelIdentifier(id)?.marketingName.map { (id: id, name: $0) } }
        list.append((id: "iPad-modern", name: String(localized: "iPad (without Home button)")))
        list.append((id: "iPad-home", name: String(localized: "iPad (with Home button)")))
        return list
    }()

    static func profile(forSelection id: String) -> DeviceProfile? {
        switch id {
        case "iPad-modern": return pad("iPad", homeButton: false, corner: 0.022, points: nil)
        case "iPad-home": return pad("iPad", homeButton: true, corner: 0, points: nil)
        default: return forModelIdentifier(id)
        }
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

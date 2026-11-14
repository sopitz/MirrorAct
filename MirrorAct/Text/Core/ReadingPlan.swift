// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
// CGRect is a Foundation type on Linux; on Apple platforms its members come with CoreGraphics
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A part of the picture that has to be read, in thumbnail pixels of the current frame
struct UnreadArea: Equatable {
    enum Kind: Equatable {
        /// new or changed in place (a new screen, a pop-up, text that was replaced): read once
        /// it has stopped changing
        case changed
        /// came into view while content scrolled: read at once when it can hold a line
        case strip
        /// a block was cut off at an edge, or two blocks may be one paragraph: read once all of
        /// it can be seen, or else once its scrolling area has rested for `restDelay` (only when
        /// it was asked for before that: one asked for while the area rests already waits for
        /// its next movement and the rest after it, `ReadingPlan.dueAtRest`)
        case reread
        /// was read while it moved fast (the link loses detail then), not found again while it
        /// moved, or the place of a block that could not be found for a while and was forgotten
        /// there: read again once all that moves over or under it rests
        case confirm
        /// where a paragraph may go on: read once its scrolling area has not moved up or down for
        /// `restDelay`, if nothing read it before – when it was asked for before that rest began;
        /// asked for while the area rests already, it waits for its next movement and the rest
        /// after it (`ReadingPlan.dueAtRest`)
        case rest
    }

    var rect: CGRect
    var kind: Kind
    /// when it appeared, or changed last
    var since: TimeInterval
    /// how often a reread was asked for at this place already
    var attempts = 0
    /// the scrolling area it lies in, -1 = none or not known: a place read at rest waits for
    /// that area to rest, else for the motion near it (`ReadingPlan.RestClock`);
    /// `everythingOver`: it waits for every scrolling area it overlaps or that lies near it
    var areaID = -1

    /// What was read while the picture moved fast, or not found again while it moved
    /// (`Kind.confirm`), waits for every scrolling area it overlaps, or that lies within
    /// `readMargin` of it, to rest (for the picture as a whole when there is none): what moves over
    /// it or under it may belong to another area than the one its centre lies in (a page that
    /// slides in beside the one that slides out), and a pass reads that margin around it too
    static let everythingOver = -2
}

/// What has to be read, and when: areas of the picture that move with the content they belong
/// to until a recognition pass takes them.
final class ReadingPlan {
    /// When the content of a place last moved (`vertically`: up or down): that of its
    /// scrolling area (`areaID`), for a place outside of every area (-1) the motion near `rect`,
    /// for `UnreadArea.everythingOver` that of every scrolling area `rect` overlaps
    typealias RestClock = (_ areaID: Int, _ rect: CGRect, _ vertically: Bool) -> TimeInterval

    private let configuration: OverlayTracker.Configuration
    private(set) var areas: [UnreadArea] = []
    /// the areas the running pass reads (they come back when it fails)
    private(set) var inFlight: [UnreadArea] = []

    init(configuration: OverlayTracker.Configuration) {
        self.configuration = configuration
    }

    func reset() {
        areas = []
        inFlight = []
    }

    /// Adds an area, merged with one of its kind that it touches when that wastes little. A new
    /// change is cut out of older changed areas: the rest of them keeps its own time (a video
    /// that keeps changing must not keep the page around it from being read).
    func add(_ area: UnreadArea) {
        guard area.rect.width >= 1, area.rect.height >= 1 else { return }
        if area.kind == .changed {
            var kept: [UnreadArea] = []
            for other in areas {
                guard other.kind == .changed, other.since < area.since,
                      other.rect.intersects(area.rect) else {
                    kept.append(other)
                    continue
                }
                for piece in ReadingPlan.subtract(area.rect, from: other.rect) where piece.width >= 1 && piece.height >= 1 {
                    var copy = other
                    copy.rect = piece
                    kept.append(copy)
                }
            }
            areas = kept
        }
        var merged = area
        var index = 0
        while index < areas.count {
            let other = areas[index]
            // (changes are carved out of each other above, not merged: each keeps its own time)
            if other.kind == merged.kind, merged.kind != .changed,
               ReadingPlan.isWorthMerging(other.rect, merged.rect, slack: configuration.mergeSlack) {
                merged = ReadingPlan.merging(other, merged)
                areas.remove(at: index)
                index = 0
                continue
            }
            index += 1
        }
        areas.append(merged)
        limitCount()
    }

    private static func merging(_ first: UnreadArea, _ second: UnreadArea) -> UnreadArea {
        var result = first
        result.rect = first.rect.union(second.rect)
        // a change counts from its last step; a strip from when it came in, a place to read
        // again from when it was first asked for (it may be due once the picture rests)
        result.since = first.kind == .strip || first.kind == .reread || first.kind == .rest
            ? min(first.since, second.since) : max(first.since, second.since)
        result.attempts = max(first.attempts, second.attempts)
        // (a place outside of every area joined with one in an area waits for that area; one in
        // two areas waits for the picture as a whole)
        if first.areaID == UnreadArea.everythingOver || second.areaID == UnreadArea.everythingOver {
            result.areaID = UnreadArea.everythingOver
        } else if first.areaID < 0 {
            result.areaID = second.areaID
        } else if second.areaID >= 0, second.areaID != first.areaID {
            result.areaID = -1
        }
        return result
    }

    /// Two rectangles touch or overlap and their union is not much more than the two
    static func isWorthMerging(_ first: CGRect, _ second: CGRect, slack: Double) -> Bool {
        let touching = first.minX <= second.maxX + 1 && second.minX <= first.maxX + 1
            && first.minY <= second.maxY + 1 && second.minY <= first.maxY + 1
        guard touching else { return false }
        let union = first.union(second)
        return Double(union.width * union.height) <= slack * Double(first.width * first.height + second.width * second.height)
    }

    /// Too many small areas: the two whose union wastes least become one
    private func limitCount() {
        while areas.count > configuration.maxUnreadAreas {
            var bestFirst = 0, bestSecond = 1
            var bestWaste = Double.infinity
            for first in 0..<areas.count {
                for second in (first + 1)..<areas.count where areas[first].kind == areas[second].kind {
                    let union = areas[first].rect.union(areas[second].rect)
                    let waste = Double(union.width * union.height - areas[first].rect.width * areas[first].rect.height
                                       - areas[second].rect.width * areas[second].rect.height)
                    if waste < bestWaste {
                        bestWaste = waste
                        bestFirst = first
                        bestSecond = second
                    }
                }
            }
            guard bestWaste.isFinite else {
                areas.removeFirst()
                continue
            }
            let merged = ReadingPlan.merging(areas[bestFirst], areas[bestSecond])
            areas.remove(at: bestSecond)
            areas[bestFirst] = merged
        }
    }

    /// Moves the areas with the content: the part of an area inside the moving part of the
    /// picture `regions[i]` moves by `shifts[i]` and is cut to that part (what scrolled out of
    /// view need not be read any more); the rest stays.
    func move(regions: [CGRect], shifts: [(dx: Double, dy: Double)], bounds: CGRect) {
        areas = ReadingPlan.clipped(ReadingPlan.moved(areas, regions: regions, shifts: shifts), to: bounds)
        inFlight = ReadingPlan.clipped(ReadingPlan.moved(inFlight, regions: regions, shifts: shifts), to: bounds)
    }

    /// What lies outside of the frame cannot be read
    private static func clipped(_ list: [UnreadArea], to bounds: CGRect) -> [UnreadArea] {
        var result: [UnreadArea] = []
        for area in list {
            let inside = area.rect.intersection(bounds)
            guard !inside.isNull, inside.width >= 1, inside.height >= 1 else { continue }
            var copy = area
            copy.rect = inside
            result.append(copy)
        }
        return result
    }

    private static func moved(_ list: [UnreadArea], regions: [CGRect], shifts: [(dx: Double, dy: Double)]) -> [UnreadArea] {
        guard !list.isEmpty, !regions.isEmpty else { return list }
        var result: [UnreadArea] = []
        for area in list {
            var pieces = [area.rect]
            for (index, region) in regions.enumerated() {
                var rest: [CGRect] = []
                for piece in pieces {
                    let inside = piece.intersection(region)
                    guard !inside.isNull, inside.width > 0, inside.height > 0 else {
                        rest.append(piece)
                        continue
                    }
                    let shifted = inside.offsetBy(dx: shifts[index].dx, dy: shifts[index].dy).intersection(region)
                    if !shifted.isNull, shifted.width >= 1, shifted.height >= 1 {
                        var copy = area
                        copy.rect = shifted
                        result.append(copy)
                    }
                    rest += ReadingPlan.subtract(region, from: piece)
                }
                pieces = rest
            }
            for piece in pieces where piece.width >= 1 && piece.height >= 1 {
                var copy = area
                copy.rect = piece
                result.append(copy)
            }
        }
        return result
    }

    /// `rect` without `hole`: up to four rectangles
    static func subtract(_ hole: CGRect, from rect: CGRect) -> [CGRect] {
        let cut = rect.intersection(hole)
        guard !cut.isNull, cut.width > 0, cut.height > 0 else { return [rect] }
        var pieces: [CGRect] = []
        if cut.minY > rect.minY {
            pieces.append(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: cut.minY - rect.minY))
        }
        if cut.maxY < rect.maxY {
            pieces.append(CGRect(x: rect.minX, y: cut.maxY, width: rect.width, height: rect.maxY - cut.maxY))
        }
        if cut.minX > rect.minX {
            pieces.append(CGRect(x: rect.minX, y: cut.minY, width: cut.minX - rect.minX, height: cut.height))
        }
        if cut.maxX < rect.maxX {
            pieces.append(CGRect(x: cut.maxX, y: cut.minY, width: rect.maxX - cut.maxX, height: cut.height))
        }
        return pieces
    }

    // MARK: When and what

    /// When `area` may be read; nil = not yet (a reread that cannot be seen completely).
    /// `areaMotion` says when the content of a place last moved: a place that waits for movement
    /// to end (a thin strip, a place read at rest) waits for its scrolling area, or for the motion
    /// near it when it lies in none, not for the whole picture; a confirm read waits for every
    /// area it overlaps (`UnreadArea.everythingOver`); where a paragraph may go on (`.rest`, beyond
    /// its top or bottom) waits only for movement up or down. Without `areaMotion`,
    /// everything waits for `lastMotion`.
    func due(of area: UnreadArea, lastMotion: TimeInterval, isFullyVisible: (CGRect) -> Bool,
             areaMotion: RestClock? = nil) -> TimeInterval? {
        switch area.kind {
        case .changed:
            return area.since + configuration.settleTime
        case .strip:
            let thickness = min(area.rect.width, area.rect.height)
            return thickness >= configuration.minStripThickness ? area.since
                : max(area.since, restingSince(area, vertically: false, lastMotion: lastMotion, areaMotion: areaMotion)
                    + configuration.thinStripDelay)
        case .reread:
            if isFullyVisible(area.rect) { return area.since }
            // what cannot be seen completely (it lies at a bar) is read once the picture rests
            return dueAtRest(area, lastMotion: restingSince(area, vertically: false, lastMotion: lastMotion,
                                                            areaMotion: areaMotion))
        case .confirm:
            return max(area.since, restingSince(area, vertically: false, lastMotion: lastMotion, areaMotion: areaMotion)
                + configuration.confirmDelay)
        case .rest:
            return dueAtRest(area, lastMotion: restingSince(area, vertically: true, lastMotion: lastMotion,
                                                            areaMotion: areaMotion))
        }
    }

    /// When what `area` lies in last moved: its scrolling area, or the motion near it
    /// (`RestClock`); the picture as a whole when no clock is given
    private func restingSince(_ area: UnreadArea, vertically: Bool, lastMotion: TimeInterval,
                              areaMotion: RestClock?) -> TimeInterval {
        guard let areaMotion else { return lastMotion }
        return areaMotion(area.areaID, area.rect, vertically)
    }

    /// Once what the place lies in (`lastMotion`: its scrolling area, or the content near it) has
    /// rested for `restDelay`; once for each time it comes to rest: a place asked for after that
    /// rest began (while it rests already) is not due before the next movement, nil until then
    private func dueAtRest(_ area: UnreadArea, lastMotion: TimeInterval) -> TimeInterval? {
        let rest = lastMotion + configuration.restDelay
        return area.since <= rest ? max(area.since, rest) : nil
    }

    /// The earliest time something is due
    func due(lastMotion: TimeInterval, isFullyVisible: (CGRect) -> Bool,
             areaMotion: RestClock? = nil) -> TimeInterval? {
        var earliest: TimeInterval?
        for area in areas {
            guard let due = due(of: area, lastMotion: lastMotion, isFullyVisible: isFullyVisible,
                                areaMotion: areaMotion) else { continue }
            earliest = min(earliest ?? due, due)
        }
        return earliest
    }

    /// The region the next pass reads (thumbnail pixels, inside `bounds`): the largest area
    /// that is due, with the other due areas that lie close to it, and a margin all around so
    /// that text at its edges can be read completely. The areas it covers are in flight then.
    /// nil when nothing is due.
    func takeRegion(at time: TimeInterval, lastMotion: TimeInterval, bounds: CGRect,
                    isFullyVisible: (CGRect) -> Bool, areaMotion: RestClock? = nil) -> CGRect? {
        var dueAreas: [UnreadArea] = []
        for area in areas {
            if let due = due(of: area, lastMotion: lastMotion, isFullyVisible: isFullyVisible, areaMotion: areaMotion),
               due <= time + 1e-9 {
                dueAreas.append(area)
            }
        }
        guard !dueAreas.isEmpty else { return nil }
        dueAreas.sort { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }
        var region = dueAreas[0].rect
        for area in dueAreas.dropFirst() {
            let union = region.union(area.rect)
            if Double(union.width * union.height) <= configuration.regionSlack
                * Double(region.width * region.height + area.rect.width * area.rect.height) {
                region = union
            }
        }
        let margin = configuration.readMargin
        region = region.insetBy(dx: -margin, dy: -margin).intersection(bounds)
        guard !region.isNull, region.width >= 1, region.height >= 1 else { return nil }
        if Double(region.width * region.height) >= configuration.wholeFrameShare * Double(bounds.width * bounds.height) {
            region = bounds
        }
        // whole pixels, so that the frame region is exact
        region = CGRect(x: floor(region.minX), y: floor(region.minY), width: ceil(region.maxX) - floor(region.minX),
                        height: ceil(region.maxY) - floor(region.minY)).intersection(bounds)
        var kept: [UnreadArea] = []
        inFlight = []
        for area in areas {
            let inside = area.rect.intersection(region)
            guard !inside.isNull, inside.width > 0, inside.height > 0 else {
                kept.append(area)
                continue
            }
            if area.kind == .reread {
                // a paragraph to read as a whole: taken if most of it is read, else left whole
                if inside.width * inside.height * 2 >= area.rect.width * area.rect.height {
                    inFlight.append(area)
                } else {
                    kept.append(area)
                }
                continue
            }
            var taken = area
            taken.rect = inside
            inFlight.append(taken)
            for piece in ReadingPlan.subtract(region, from: area.rect) where piece.width >= 1 && piece.height >= 1 {
                var copy = area
                copy.rect = piece
                kept.append(copy)
            }
        }
        areas = kept
        return region
    }

    /// The pass that read the areas in flight is over; when it failed they have to be read again
    func finishPass(succeeded: Bool) {
        let taken = inFlight
        inFlight = []
        guard !succeeded else { return }
        for area in taken {
            add(area)
        }
    }

    /// The areas in flight were all rereads (besides places read at rest, which ride along with
    /// whatever is read over them): the highest number of attempts among them, else nil. A confirm
    /// read in flight makes it nil: it follows movement, so what it finds cut off is taken for a
    /// first reading and waits for the page to rest, not taken as it shows
    var rereadAttemptsInFlight: Int? {
        var most: Int?
        for area in inFlight where area.kind != .rest {
            guard area.kind == .reread else { return nil }
            most = max(most ?? 0, area.attempts)
        }
        return most
    }
}

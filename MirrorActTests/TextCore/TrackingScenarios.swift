// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@testable import MirrorAct

// The scenarios the bench plays: every one is a screen and a few seconds of what happens on it,
// made from a seed. Another seed gives another page (other texts, other layout within the same
// profile) and other speeds, distances and pauses within the same script.

// MARK: - A phone screen

/// The layers of the screens built here, from back to front. A scene has at most one layer in
/// every slot.
enum SimSlot {
    static let backdrop = 0
    static let page = 10
    /// the part of a page that something arriving late has pushed down, and that something
    static let pageBelow = 11
    static let pushed = 12
    /// something inside the page that moves or changes on its own
    static let inset = 20
    static let cursor = 30
    static let sticky = 40
    static let sidebar = 50
    /// a screen that lies on top of another one and is swiped away
    static let cover = 55
    /// the thin bar that shows how far a page is scrolled
    static let indicator = 58
    static let topBar = 60
    static let bottomBar = 70
    static let pill = 80
    static let button = 90
    static let keyboard = 95
    static let popup = 100
}

/// Content that scrolls, with room at its ends to overshoot
struct SimPage {
    var sprite: Int
    /// pixels of empty margin before and after the content
    var pad: Int
    /// length of the content in the direction it scrolls
    var length: Int
    /// header bands of its sections, in pixels of the sprite
    var sections: [SimRect] = []
    /// the same seen through frosted glass, for bars that let the content shine through
    var frosted: Int?
    var isHorizontal = false
    /// pixels of empty margin left and right of a page that is wider than the screen
    var sidePad = 0
}

/// Something that lies on top of the screen for a while
struct SimOverlay {
    var sprite: Int
    var rect: SimRect
}

/// Builds the sprites and scenes of an app screen: bars, a page, things on top
final class SimStage {
    let scenario: SimScenario
    var random: SimRandom
    let words: SimWords
    let theme: SimTheme
    /// pixels per point
    let unit: Int
    let width: Int
    let height: Int
    /// where the page shows
    private(set) var viewport: SimRect
    /// sprite of the bar at the top; change it to show another title
    var topBar = -1
    var sticksHeaders = false

    private let backdrop: Int
    private var bottomBar = -1
    private var topHeight = 0
    private var bottomHeight = 0
    private var isFrosted = false
    private var pill = SimOverlay(sprite: -1, rect: SimRect())
    private var button = SimOverlay(sprite: -1, rect: SimRect())
    private var sidebar = SimOverlay(sprite: -1, rect: SimRect())
    private var dimmedTwins: [Int: Int] = [:]
    private var indicatorSprite = -1

    init(_ name: String, seed: UInt64, width: Int = 780, height: Int = 1688, unit: Int = 2, dark: Bool = false) {
        scenario = SimScenario(name: name, seed: seed, frameWidth: width, frameHeight: height)
        random = SimRandom(seed: seed).branch(0x7374_6167_65)
        words = SimWords(random: SimRandom(seed: seed).branch(0x776F_7264_73))
        var themeRandom = SimRandom(seed: seed).branch(0x7468_656D_65)
        theme = dark ? SimTheme.dark(&themeRandom) : SimTheme.light(&themeRandom)
        self.unit = unit
        self.width = width
        self.height = height
        viewport = SimRect(x: 0, y: 0, width: width, height: height)
        backdrop = scenario.add(SimSprite(width: width, height: height, level: theme.background))
    }

    /// The largest multiple of the thumbnail factor up to `pixels`: bars and pop-ups lie on the
    /// grid of thumbnail cells
    func snapped(_ pixels: Int) -> Int {
        pixels / scenario.scale * scenario.scale
    }

    private var frame: SimRect { scenario.frameRect }
    private var topRect: SimRect { SimRect(x: 0, y: 0, width: width, height: topHeight) }
    private var bottomRect: SimRect { SimRect(x: 0, y: height - bottomHeight, width: width, height: bottomHeight) }

    // MARK: Chrome

    /// A title bar and a tab bar; `frosted` = the content shines through them, blurred;
    /// `title`: see `makeTopBar`
    func addBars(top: Bool = true, bottom: Bool = true, frosted: Bool = false, title: String? = nil,
                 back: String? = nil) {
        let points = height / unit
        topHeight = top ? snapped(min(94, points / 9) * unit) : 0
        // the upper edge of the lower bar lies on the grid too, whatever the height of the frame
        bottomHeight = bottom ? height - snapped(height - min(82, points / 10) * unit) : 0
        viewport = SimRect(x: viewport.x, y: topHeight, width: viewport.width, height: height - topHeight - bottomHeight)
        isFrosted = frosted
        if frosted {
            // the title on a plate of its own
            guard top else { return }
            let plateWidth = snapped(width * 45 / 100), plateHeight = snapped(30 * unit)
            let plate = SimSprite(width: plateWidth, height: plateHeight, level: theme.card)
            let title = words.word(minLength: 5, maxLength: 9, capitalized: true)
            let size = 17 * unit
            plate.addText(title, alternate: words.misreading(of: title),
                          x: (plateWidth - SimFont.width(of: title, size: size, bold: true)) / 2,
                          y: (plateHeight - size) / 2, size: size, level: theme.text, background: theme.card, bold: true)
            pill = SimOverlay(sprite: scenario.add(plate),
                              rect: SimRect(x: snapped((width - plateWidth) / 2),
                                            y: snapped(topHeight - plateHeight - 6 * unit), width: plateWidth,
                                            height: plateHeight))
        } else {
            if top { topBar = makeTopBar(title: title, back: back) }
            if bottom { bottomBar = makeBottomBar() }
        }
    }

    /// A title bar with a clock, a title and a label to go back. `title` and `back`: nil = words
    /// of their own; an empty title = none. `backMisreading`: what the recognition sometimes reads
    /// instead of `back`, nil = a misreading of its own (give that of another bar when this one
    /// shows the same label at the same place: the same label read wrong in one frame would
    /// otherwise belong to one of the two bars only).
    func makeTopBar(title givenTitle: String? = nil, back givenBack: String? = nil,
                    backMisreading: String? = nil) -> Int {
        let bar = SimSprite(width: width, height: topHeight, level: theme.bar)
        let size = 17 * unit, baseline = topHeight - 12 * unit - size
        if topHeight >= 80 * unit {
            bar.addText("9:41", alternate: "9:41", x: 24 * unit, y: 14 * unit, size: 15 * unit, level: theme.text,
                        background: theme.bar, bold: true)
            for icon in 0..<3 {
                bar.fill(SimRect(x: width - (30 + icon * 24) * unit, y: 16 * unit, width: 16 * unit, height: 11 * unit),
                         level: theme.text)
            }
        }
        let title = givenTitle ?? words.word(minLength: 5, maxLength: 10, capitalized: true)
        if !title.isEmpty {
            bar.addText(title, alternate: words.misreading(of: title),
                        x: (width - SimFont.width(of: title, size: size, bold: true)) / 2, y: baseline, size: size,
                        level: theme.text, background: theme.bar, bold: true)
        }
        let back = givenBack ?? words.word(minLength: 4, maxLength: 6, capitalized: true)
        bar.fill(SimRect(x: 10 * unit, y: baseline + 3 * unit, width: 3 * unit, height: size - 6 * unit),
                 level: theme.accent)
        // (drawn in any case, so that the words of everything made after it stay the same)
        let misreading = words.misreading(of: back)
        bar.addText(back, alternate: backMisreading ?? misreading, x: 18 * unit, y: baseline, size: size,
                    level: theme.accent, background: theme.bar)
        bar.fill(SimRect(x: 0, y: topHeight - 1, width: width, height: 1), level: theme.separator)
        return scenario.add(bar)
    }

    private func makeBottomBar() -> Int {
        let bar = SimSprite(width: width, height: bottomHeight, level: theme.bar)
        bar.fill(SimRect(x: 0, y: 0, width: width, height: 1), level: theme.separator)
        let tabs = random.int(3, 5)
        let size = 11 * unit
        for tab in 0..<tabs {
            let center = width * (2 * tab + 1) / (2 * tabs)
            let level = tab == 0 ? theme.accent : theme.secondary
            bar.fill(SimRect(x: center - 12 * unit, y: 7 * unit, width: 24 * unit, height: 22 * unit), level: level)
            let label = words.word(minLength: 4, maxLength: 7, capitalized: true)
            bar.addText(label, alternate: words.misreading(of: label),
                        x: center - SimFont.width(of: label, size: size) / 2, y: 33 * unit, size: size, level: level,
                        background: theme.bar)
        }
        return scenario.add(bar)
    }

    /// A round button that floats over the lower right corner of the page
    func addButton() {
        let side = snapped(56 * unit)
        let sprite = SimSprite(width: side, height: side, level: theme.accent)
        sprite.fill(SimRect(x: side / 2 - 2 * unit, y: side / 4, width: 4 * unit, height: side / 2),
                    level: theme.onAccent)
        sprite.fill(SimRect(x: side / 4, y: side / 2 - 2 * unit, width: side / 2, height: 4 * unit),
                    level: theme.onAccent)
        button = SimOverlay(sprite: scenario.add(sprite),
                            rect: SimRect(x: snapped(viewport.maxX - side - 16 * unit),
                                          y: snapped(viewport.maxY - side - 20 * unit), width: side, height: side))
    }

    /// A list at the left that does not scroll (the two columns of a tablet); the page gets the rest
    func addSidebar() {
        let sideWidth = snapped(viewport.width * 30 / 100)
        let sprite = SimSprite(width: sideWidth, height: viewport.height, level: theme.card)
        let builder = SimPageBuilder(sprite: sprite, unit: unit, theme: theme, words: words,
                                     random: random.branch(0x7369_6465), top: 12 * unit)
        builder.list(rows: min(12, (viewport.height - 40 * unit) / (48 * unit)), kind: .distinct, icons: true)
        sprite.fill(SimRect(x: sideWidth - 1, y: 0, width: 1, height: viewport.height), level: theme.separator)
        sidebar = SimOverlay(sprite: scenario.add(sprite),
                             rect: SimRect(x: 0, y: viewport.y, width: sideWidth, height: viewport.height))
        viewport = SimRect(x: sideWidth, y: viewport.y, width: viewport.width - sideWidth, height: viewport.height)
    }

    // MARK: Pages

    /// A page `tenths`/10 screens long. `build` adds what it must have; the profile fills the rest.
    func page(tenths: Int, profile: SimPageProfile, build: ((SimPageBuilder) -> Void)? = nil) -> SimPage {
        let pad = height
        let length = max(viewport.height, viewport.height * tenths / 10)
        let sprite = SimSprite(width: viewport.width, height: pad + length + pad, level: theme.background)
        let builder = SimPageBuilder(sprite: sprite, unit: unit, theme: theme, words: words,
                                     random: random.branch(UInt64(scenario.sprites.count)), top: pad + 14 * unit)
        build?(builder)
        builder.fill(profile, to: pad + length - 10 * unit)
        var page = SimPage(sprite: scenario.add(sprite), pad: pad, length: length, sections: builder.sections)
        if isFrosted { page.frosted = scenario.add(sprite.frosted(tint: theme.bar)) }
        return page
    }

    /// `count` screens side by side that are swiped through
    func pager(screens count: Int, profile: SimPageProfile) -> SimPage {
        let pad = viewport.width
        let sprite = SimSprite(width: pad + count * viewport.width + pad, height: viewport.height,
                               level: theme.background)
        for screen in 0..<count {
            let builder = SimPageBuilder(sprite: sprite, unit: unit, theme: theme, words: words,
                                         random: random.branch(UInt64(100 + screen)), top: 14 * unit,
                                         left: pad + screen * viewport.width, width: viewport.width)
            builder.fill(profile, to: viewport.height - 10 * unit)
        }
        return SimPage(sprite: scenario.add(sprite), pad: pad, length: count * viewport.width, isHorizontal: true)
    }

    /// A page `columns` screens wide and `tenths`/10 screens long that moves both ways, like a
    /// web page that was zoomed in
    func sheet(columns: Int, tenths: Int, profile: SimPageProfile) -> SimPage {
        let pad = height, sidePad = viewport.width / 2
        let length = max(viewport.height, viewport.height * tenths / 10)
        let sprite = SimSprite(width: sidePad + columns * viewport.width + sidePad, height: pad + length + pad,
                               level: theme.background)
        for column in 0..<columns {
            let builder = SimPageBuilder(sprite: sprite, unit: unit, theme: theme, words: words,
                                         random: random.branch(UInt64(200 + column)), top: pad + 14 * unit,
                                         left: sidePad + column * viewport.width, width: viewport.width)
            builder.fill(profile, to: pad + length - 10 * unit)
        }
        return SimPage(sprite: scenario.add(sprite), pad: pad, length: length, sidePad: sidePad)
    }

    /// How far a page can scroll
    func maxOffset(of page: SimPage) -> Int {
        page.length - (page.isHorizontal ? viewport.width : viewport.height)
    }

    /// The position of the sprite of a page in the frame when the page is scrolled by `offset`,
    /// and a wide page sideways by `across` (only x and y of the result mean something)
    func position(of page: SimPage, offset: Int, across: Int = 0) -> SimRect {
        page.isHorizontal
            ? SimRect(x: viewport.x - page.pad - offset, y: viewport.y, width: 0, height: 0)
            : SimRect(x: viewport.x - page.sidePad - across, y: viewport.y - page.pad - offset, width: 0, height: 0)
    }

    /// What a page shows between the bars when it is scrolled by `offset`, as a picture of its
    /// own (with the text that reaches into it)
    func crop(_ page: SimPage, offset: Int) -> SimSprite {
        let sprite = SimSprite(width: viewport.width, height: viewport.height, level: theme.background)
        sprite.copy(from: scenario.sprites[page.sprite],
                    rect: SimRect(x: page.sidePad, y: page.pad + offset, width: viewport.width, height: viewport.height),
                    toX: 0, toY: 0)
        return sprite
    }

    /// A picture of the size of the view as a page that cannot scroll
    func fixedPage(_ sprite: Int) -> SimPage {
        SimPage(sprite: sprite, pad: 0, length: viewport.height)
    }

    /// The thin bar at the right edge that shows how far `page` is scrolled
    func indicator(for page: SimPage, offset: Int) -> SimLayer {
        let length = snapped(max(36 * unit, viewport.height * viewport.height / max(1, page.length)))
        if indicatorSprite < 0 {
            indicatorSprite = scenario.add(SimSprite(width: max(scenario.scale, snapped(3 * unit)), height: length,
                                                     level: theme.secondary))
        }
        let limit = max(1, maxOffset(of: page))
        let way = (viewport.height - length) * min(limit, max(0, offset)) / limit
        let barWidth = scenario.sprites[indicatorSprite].width
        let rect = SimRect(x: snapped(viewport.maxX - barWidth - 3 * unit), y: viewport.y + snapped(way), width: barWidth,
                           height: length)
        return SimLayer(slot: SimSlot.indicator, sprite: indicatorSprite, x: rect.x, y: rect.y, clip: rect)
    }

    /// Pushes everything below row `row` of a page down by `height` pixels and shows `filler`
    /// in the gap: something that arrived late and took its place
    func split(_ scene: inout SimScene, page: SimPage, row: Int, offset: Int, height: Int, filler: Int) {
        guard let index = scene.layers.firstIndex(where: { $0.slot == SimSlot.page }) else { return }
        let line = position(of: page, offset: offset).y + row
        var upper = scene.layers[index]
        var lower = upper
        upper.clip = viewport.intersection(SimRect(x: viewport.x, y: viewport.y, width: viewport.width,
                                                   height: max(0, line - viewport.y)))
        lower.slot = SimSlot.pageBelow
        lower.y += height
        lower.clip = viewport.intersection(SimRect(x: viewport.x, y: line + height, width: viewport.width,
                                                   height: max(0, viewport.maxY - line - height)))
        scene.layers[index] = upper
        put(lower, into: &scene)
        let gap = SimRect(x: viewport.x, y: line, width: viewport.width, height: height)
        put(SimLayer(slot: SimSlot.pushed, sprite: filler, x: gap.x, y: gap.y, clip: gap.intersection(viewport)),
            into: &scene)
    }

    /// A keyboard at the lower edge of the screen: rows of keys with a letter each, and a bottom
    /// row with a wide key and two keys with words on them
    func keyboard() -> SimOverlay {
        let boardHeight = snapped(min(300, height / unit * 36 / 100) * unit)
        let sprite = SimSprite(width: width, height: boardHeight, level: theme.separator)
        let keyGap = 6 * unit
        let keyWidth = (width - 11 * keyGap) / 10
        let rowPitch = (boardHeight - 16 * unit) / 4
        let keyHeight = rowPitch - 10 * unit
        let letters = Array("qwertyuiopasdfghjklzxcvbnm".utf8)
        var next = 0
        var top = 10 * unit
        for count in [10, 9, 7] {
            var x = (width - count * keyWidth - (count - 1) * keyGap) / 2
            for _ in 0..<count {
                sprite.fill(SimRect(x: x, y: top, width: keyWidth, height: keyHeight), level: theme.background)
                // (a single letter is nothing to translate, so it is not recorded as text)
                let letter = String(decoding: [letters[next % letters.count]], as: UTF8.self)
                let size = min(22 * unit, keyHeight - 4 * unit)
                sprite.drawText(letter, x: x + (keyWidth - SimFont.width(of: letter, size: size)) / 2,
                                y: top + (keyHeight - size) / 2, size: size, level: theme.text)
                next += 1
                x += keyWidth + keyGap
            }
            top += rowPitch
        }
        let size = min(16 * unit, keyHeight - 4 * unit), labelY = top + (keyHeight - size) / 2
        let digits = SimRect(x: keyGap, y: top, width: width * 22 / 100, height: keyHeight)
        sprite.fill(digits, level: theme.card)
        sprite.addText("123", alternate: "123", x: digits.x + (digits.width - SimFont.width(of: "123", size: size)) / 2,
                       y: labelY, size: size, level: theme.text, background: theme.card)
        let enter = SimRect(x: width - keyGap - width * 24 / 100, y: top, width: width * 24 / 100, height: keyHeight)
        sprite.fill(enter, level: theme.accent)
        let enterLabel = words.word(minLength: 4, maxLength: 6)
        sprite.addText(enterLabel, alternate: words.misreading(of: enterLabel),
                       x: enter.x + (enter.width - SimFont.width(of: enterLabel, size: size)) / 2, y: labelY, size: size,
                       level: theme.onAccent, background: theme.accent)
        let space = SimRect(x: digits.maxX + keyGap, y: top, width: enter.x - digits.maxX - 2 * keyGap, height: keyHeight)
        sprite.fill(space, level: theme.background)
        let spaceLabel = words.word(minLength: 5, maxLength: 8)
        sprite.addText(spaceLabel, alternate: words.misreading(of: spaceLabel),
                       x: space.x + (space.width - SimFont.width(of: spaceLabel, size: size)) / 2, y: labelY, size: size,
                       level: theme.secondary, background: theme.background)
        return SimOverlay(sprite: scenario.add(sprite),
                          rect: SimRect(x: 0, y: height - boardHeight, width: width, height: boardHeight))
    }

    // MARK: Scenes

    private func twin(_ sprite: Int, dimmed: Bool) -> Int {
        guard dimmed else { return sprite }
        if let twin = dimmedTwins[sprite] { return twin }
        let twin = scenario.add(scenario.sprites[sprite].dimmed())
        dimmedTwins[sprite] = twin
        return twin
    }

    /// The screen with `page` scrolled by `offset` (a wide one sideways by `across`); `dimmed` =
    /// under the veil of a dialog
    func scene(_ page: SimPage, offset: Int, across: Int = 0, dimmed: Bool = false) -> SimScene {
        var layers = [SimLayer(slot: SimSlot.backdrop, sprite: twin(backdrop, dimmed: dimmed), x: 0, y: 0, clip: frame)]
        let origin = position(of: page, offset: offset, across: across)
        layers.append(SimLayer(slot: SimSlot.page, sprite: twin(page.sprite, dimmed: dimmed), x: origin.x, y: origin.y,
                               clip: viewport, degrades: true))
        if sticksHeaders {
            // the header of the section the top of the screen is in stays there
            var stuck: SimRect?
            for band in page.sections where band.y <= page.pad + offset {
                stuck = band
            }
            if let band = stuck {
                layers.append(SimLayer(slot: SimSlot.sticky, sprite: twin(page.sprite, dimmed: dimmed), x: origin.x,
                                       y: viewport.y - band.y,
                                       clip: SimRect(x: viewport.x, y: viewport.y, width: viewport.width,
                                                     height: snapped(band.height))))
            }
        }
        if sidebar.sprite >= 0 {
            layers.append(SimLayer(slot: SimSlot.sidebar, sprite: twin(sidebar.sprite, dimmed: dimmed), x: sidebar.rect.x,
                                   y: sidebar.rect.y, clip: sidebar.rect))
        }
        if isFrosted, let frosted = page.frosted {
            if topHeight > 0 {
                layers.append(SimLayer(slot: SimSlot.topBar, sprite: twin(frosted, dimmed: dimmed), x: origin.x,
                                       y: origin.y, clip: topRect))
            }
            if bottomHeight > 0 {
                layers.append(SimLayer(slot: SimSlot.bottomBar, sprite: twin(frosted, dimmed: dimmed), x: origin.x,
                                       y: origin.y, clip: bottomRect))
            }
            if pill.sprite >= 0 {
                layers.append(SimLayer(slot: SimSlot.pill, sprite: twin(pill.sprite, dimmed: dimmed), x: pill.rect.x,
                                       y: pill.rect.y, clip: pill.rect))
            }
        } else {
            if topBar >= 0 {
                layers.append(SimLayer(slot: SimSlot.topBar, sprite: twin(topBar, dimmed: dimmed), x: 0, y: 0,
                                       clip: topRect))
            }
            if bottomBar >= 0 {
                layers.append(SimLayer(slot: SimSlot.bottomBar, sprite: twin(bottomBar, dimmed: dimmed), x: 0,
                                       y: height - bottomHeight, clip: bottomRect))
            }
        }
        if button.sprite >= 0 {
            layers.append(SimLayer(slot: SimSlot.button, sprite: twin(button.sprite, dimmed: dimmed), x: button.rect.x,
                                   y: button.rect.y, clip: button.rect))
        }
        return SimScene(layers: layers)
    }

    /// Puts a layer of its own into a scene, above the layers with a lower slot
    func put(_ layer: SimLayer, into scene: inout SimScene) {
        var index = 0
        while index < scene.layers.count, scene.layers[index].slot <= layer.slot {
            index += 1
        }
        scene.layers.insert(layer, at: index)
    }

    /// A layer inside a page: `sprite` covers `box` (pixels of the page sprite) and moves with it
    func inset(_ sprite: Int, box: SimRect, in page: SimPage, offset: Int, shiftX: Int = 0, shiftY: Int = 0,
               slot: Int = SimSlot.inset, degrades: Bool = false) -> SimLayer {
        let origin = position(of: page, offset: offset)
        return SimLayer(slot: slot, sprite: sprite, x: origin.x + box.x - shiftX, y: origin.y + box.y - shiftY,
                        clip: box.offsetBy(dx: origin.x, dy: origin.y).intersection(viewport), degrades: degrades)
    }

    // MARK: Things on top

    /// A dialog in the middle of the screen: a title, a message, two buttons
    func alert() -> SimOverlay {
        let cardWidth = snapped(min(width - 48 * unit, 280 * unit)), cardHeight = snapped(176 * unit)
        let sprite = SimSprite(width: cardWidth, height: cardHeight, level: theme.card)
        let builder = SimPageBuilder(sprite: sprite, unit: unit, theme: theme, words: words,
                                     random: random.branch(0x616C_6572_74), top: 18 * unit)
        let inner = cardWidth - 2 * builder.margin
        let title = words.word(minLength: 5, maxLength: 8, capitalized: true) + " "
            + words.word(minLength: 3, maxLength: 7)
        builder.text([title], size: 17 * unit, x: builder.margin, width: inner, align: .center, level: theme.text,
                     background: theme.card, bold: true)
        var message: [String] = []
        for _ in 0..<random.int(2, 3) {
            var text = words.word()
            while SimFont.width(of: text + " " + "mmmmmm", size: 13 * unit) < inner * 80 / 100 {
                text += " " + words.word()
            }
            message.append(text)
        }
        builder.text(message, size: 13 * unit, x: builder.margin, width: inner, align: .center, level: theme.text,
                     background: theme.card)
        let buttonsTop = cardHeight - 46 * unit
        sprite.fill(SimRect(x: 0, y: buttonsTop, width: cardWidth, height: 1), level: theme.separator)
        sprite.fill(SimRect(x: cardWidth / 2, y: buttonsTop, width: 1, height: 46 * unit), level: theme.separator)
        for side in 0..<2 {
            let label = words.word(minLength: 4, maxLength: 7, capitalized: true)
            let labelWidth = SimFont.width(of: label, size: 17 * unit, bold: side == 1)
            sprite.addText(label, alternate: words.misreading(of: label),
                           x: cardWidth / 4 + side * cardWidth / 2 - labelWidth / 2, y: buttonsTop + (46 - 17) * unit / 2,
                           size: 17 * unit, level: theme.accent, background: theme.card, bold: side == 1)
        }
        return SimOverlay(sprite: scenario.add(sprite),
                          rect: SimRect(x: snapped((width - cardWidth) / 2), y: snapped((height - cardHeight) / 2),
                                        width: cardWidth, height: cardHeight))
    }

    /// A notice that slides in over the top of the screen: an icon, a headline, a line of text
    func banner() -> SimOverlay {
        let cardWidth = snapped(width - 16 * unit), cardHeight = snapped(72 * unit)
        let sprite = SimSprite(width: cardWidth, height: cardHeight, level: theme.card)
        sprite.fill(SimRect(x: 12 * unit, y: 16 * unit, width: 40 * unit, height: 40 * unit), level: theme.accent)
        let headline = words.word(minLength: 5, maxLength: 9, capitalized: true)
        sprite.addText(headline, alternate: words.misreading(of: headline), x: 64 * unit, y: 12 * unit, size: 15 * unit,
                       level: theme.text, background: theme.card, bold: true)
        var text = words.word(capitalized: true)
        while SimFont.width(of: text + " " + "mmmmmm", size: 13 * unit) < (cardWidth - 80 * unit) * 85 / 100 {
            text += " " + words.word()
        }
        sprite.addText(text, alternate: words.misreading(of: text), x: 64 * unit, y: 44 * unit, size: 13 * unit,
                       level: theme.secondary, background: theme.card)
        return SimOverlay(sprite: scenario.add(sprite),
                          rect: SimRect(x: snapped((width - cardWidth) / 2), y: snapped(10 * unit), width: cardWidth,
                                        height: cardHeight))
    }

    /// The layer of something on top; `dy` moves it (while it slides in)
    func layer(of overlay: SimOverlay, dy: Int = 0) -> SimLayer {
        SimLayer(slot: SimSlot.popup, sprite: overlay.sprite, x: overlay.rect.x, y: overlay.rect.y + snapped(dy),
                 clip: overlay.rect.offsetBy(dx: 0, dy: snapped(dy)))
    }

    /// The scenario with all its scenes; `frames` = which ticks bring a frame (default: all)
    func finish(frames: [Bool]? = nil) -> SimScenario {
        if let frames { scenario.frameDue = frames }
        scenario.finish()
        return scenario
    }
}

// MARK: - The catalogue

struct TrackingScenarioSpec {
    let name: String
    /// builds it from a seed
    let make: (UInt64) -> SimScenario
    /// one line of description
    let summary: String
}

enum TrackingScenarios {
    static let all: [TrackingScenarioSpec] = [
        // nothing moves
        TrackingScenarioSpec(name: "stillScreen", make: stillScreen,
                             summary: "wireless source, a still screen: one frame, one reading"),
        TrackingScenarioSpec(name: "stillCable", make: stillCable,
                             summary: "cable source, a still screen: 60 identical frames per second"),
        TrackingScenarioSpec(name: "noisyCable", make: noisyCable,
                             summary: "cable source with noise that differs in every frame, and a blinking cursor"),
        // scrolling
        TrackingScenarioSpec(name: "slowDrag", make: slowDrag,
                             summary: "a finger drags the page slowly up, then down"),
        TrackingScenarioSpec(name: "steadyScroll", make: steadyScroll,
                             summary: "constant speed for 2.5 s: new text keeps coming in"),
        TrackingScenarioSpec(name: "flick", make: flick,
                             summary: "a flick that slows down exponentially"),
        TrackingScenarioSpec(name: "fastFlick", make: fastFlick,
                             summary: "a very fast flick, 30 to 40 % of the scroll area per frame at first"),
        TrackingScenarioSpec(name: "reverse", make: reverse,
                             summary: "a flick is caught and dragged back: text leaves and returns"),
        TrackingScenarioSpec(name: "tremble", make: tremble,
                             summary: "a resting finger: steps of a few pixels back and forth"),
        TrackingScenarioSpec(name: "rubberBand", make: rubberBand,
                             summary: "runs past both ends of the page and springs back"),
        TrackingScenarioSpec(name: "stopAndGo", make: stopAndGo,
                             summary: "short drags with pauses in between"),
        TrackingScenarioSpec(name: "alikeRows", make: alikeRows,
                             summary: "list rows that look almost alike, scrolled by a row and by half a row per frame"),
        TrackingScenarioSpec(name: "identicalRows", make: identicalRows,
                             summary: "list rows with the same text and look, a few of their own in between"),
        TrackingScenarioSpec(name: "sparsePage", make: sparsePage,
                             summary: "little text, large empty areas and pictures"),
        TrackingScenarioSpec(name: "darkTheme", make: darkTheme,
                             summary: "light text on dark, text in several shades"),
        // what does not scroll
        TrackingScenarioSpec(name: "frostedBars", make: frostedBars,
                             summary: "bars that let the blurred content shine through"),
        TrackingScenarioSpec(name: "floatingButton", make: floatingButton,
                             summary: "a button floating over the scrolling list"),
        TrackingScenarioSpec(name: "stickyHeader", make: stickyHeader,
                             summary: "section headers that stick to the top while their section scrolls"),
        TrackingScenarioSpec(name: "pager", make: pager,
                             summary: "screens swiped sideways, snapping into place"),
        TrackingScenarioSpec(name: "ticker", make: { ticker(seed: $0, moving: true) },
                             summary: "a row of cards glides sideways all the time; the page scrolls once, then rests"),
        TrackingScenarioSpec(name: "tickerStill", make: { ticker(seed: $0, moving: false) },
                             summary: "as ticker, but the cards stay"),
        TrackingScenarioSpec(name: "tickerLow", make: { ticker(seed: $0, moving: true, paragraphsAbove: 7) },
                             summary: "as ticker, with the cards low on the page, where they glide before the page is dragged"),
        TrackingScenarioSpec(name: "carousel", make: carousel,
                             summary: "a row of cards scrolls sideways inside a page, then the page scrolls"),
        TrackingScenarioSpec(name: "diagonalPan", make: diagonalPan,
                             summary: "a page wider than the screen is dragged and flicked diagonally"),
        // changes that are not scrolling
        TrackingScenarioSpec(name: "alert", make: alert,
                             summary: "a dialog dims the screen, stays and goes"),
        TrackingScenarioSpec(name: "banner", make: banner,
                             summary: "a notice slides over the top of a slowly scrolling page"),
        TrackingScenarioSpec(name: "newScreen", make: newScreen,
                             summary: "another screen at once, later the first one again"),
        TrackingScenarioSpec(name: "slideOver", make: slideOver,
                             summary: "another screen slides in from the right and out again"),
        TrackingScenarioSpec(name: "textReplaced", make: textReplaced,
                             summary: "a line of text changes in place several times"),
        TrackingScenarioSpec(name: "video", make: video,
                             summary: "a video plays inside the page, at rest and while scrolling"),
        // sources and sizes
        TrackingScenarioSpec(name: "slowTranslator", make: slowTranslator,
                             summary: "translations take 1.2 s and wait for rest; text that returns needs none"),
        TrackingScenarioSpec(name: "halfRate", make: halfRate,
                             summary: "30 frames per second"),
        TrackingScenarioSpec(name: "droppedFrames", make: droppedFrames,
                             summary: "one frame in eight is lost, sometimes several in a row"),
        TrackingScenarioSpec(name: "cableScroll", make: cableScroll,
                             summary: "cable source: stop and go between runs of identical frames"),
        TrackingScenarioSpec(name: "iPhone", make: iPhone,
                             summary: "1170 × 2532, thumbnail factor 3"),
        TrackingScenarioSpec(name: "android", make: android,
                             summary: "1440 × 3200, thumbnail factor 4"),
        TrackingScenarioSpec(name: "iPadLandscape", make: iPadLandscape,
                             summary: "2732 × 2048, thumbnail factor 6: small text, a list beside the page that stays"),
        // what a phone does besides scrolling
        TrackingScenarioSpec(name: "crossFade", make: crossFade,
                             summary: "one screen fades into another within a third of a second, and back"),
        TrackingScenarioSpec(name: "swipeBack", make: swipeBack,
                             summary: "the screen on top follows a finger sideways, the one below moves slower"),
        TrackingScenarioSpec(name: "keyboard", make: keyboard,
                             summary: "a keyboard slides in while the page moves up by less, and out again"),
        TrackingScenarioSpec(name: "lateContent", make: lateContent,
                             summary: "a picture loads, a paragraph appears, something pushes the rest of the page down"),
        TrackingScenarioSpec(name: "zoom", make: zoom,
                             summary: "the page is pinched larger, rests and shrinks back"),
        TrackingScenarioSpec(name: "largeTitle", make: largeTitle,
                             summary: "a large title scrolls away and fades in in the bar; a picture moves at half the speed"),
        TrackingScenarioSpec(name: "typography", make: typography,
                             summary: "huge, tiny, faint and right-aligned text, text on pictures, a paragraph longer than the screen"),
        TrackingScenarioSpec(name: "pullToRefresh", make: pullToRefresh,
                             summary: "pulled down past the top: a spinner turns, new rows push the page down"),
        TrackingScenarioSpec(name: "rotation", make: rotation,
                             summary: "the phone is turned while scrolling: frames of another size, the same texts"),
        TrackingScenarioSpec(name: "services", make: services,
                             summary: "recognition passes fail and translations are put off; then the page scrolls"),
        TrackingScenarioSpec(name: "roughLink", make: roughLink,
                             summary: "fast flicks at 30 frames per second with lost frames and heavy compression"),
    ]

    static func make(_ name: String, seed: UInt64) -> SimScenario? {
        all.first { $0.name == name }?.make(seed)
    }

    // MARK: Building blocks

    /// A stage with bars and one page, and the track of that page
    private struct Scroller {
        var stage: SimStage
        var page: SimPage
        var track: SimTrack
        /// height of the area the page shows in
        var view: Int
        /// height of a list row in pixels, where the page has only one
        var rowPitch = 0
        /// The thin bar at the right edge that shows the position while the page moves and for
        /// 0.6 s after: a change of the picture that is neither scrolling nor text
        var showsIndicator = false
    }

    private static func makeScroller(_ name: String, seed: UInt64, width: Int = 780, height: Int = 1688, unit: Int = 2,
                                 dark: Bool = false, tenths: Int = 35, profile: SimPageProfile = .article,
                                 startPercent: Int = 30, prepare: ((SimStage) -> Void)? = nil,
                                 build: ((SimPageBuilder) -> Void)? = nil) -> Scroller {
        let stage = SimStage(name, seed: seed, width: width, height: height, unit: unit, dark: dark)
        if let prepare {
            prepare(stage)
        } else {
            stage.addBars()
        }
        let page = stage.page(tenths: tenths, profile: profile, build: build)
        let limit = stage.maxOffset(of: page)
        return Scroller(stage: stage, page: page,
                        track: SimTrack(start: limit * startPercent / 100, lower: 0, upper: limit),
                        view: stage.viewport.height)
    }

    /// One scene per position of the track
    private static func finish(_ scroller: Scroller, frames: [Bool]? = nil) -> SimScenario {
        let stage = scroller.stage
        var lastMove = -1000
        var before = scroller.track.positions.first ?? 0
        for (tick, offset) in scroller.track.positions.enumerated() {
            if offset != before { lastMove = tick }
            before = offset
            var scene = stage.scene(scroller.page, offset: offset)
            if scroller.showsIndicator, tick - lastMove <= 36 {
                stage.put(stage.indicator(for: scroller.page, offset: offset), into: &scene)
            }
            stage.scenario.scenes.append(scene)
        }
        return stage.finish(frames: frames)
    }

    /// 0…1024 for step `tick` of `ticks`: starts and ends gently
    private static func eased(_ tick: Int, of ticks: Int) -> Int {
        let t = min(1024, max(0, tick * 1024 / max(1, ticks)))
        return (3 * t * t - 2 * t * t * t / 1024) / 1024
    }

    /// Speed in 1/1024 pixel per tick for a share of the view per tick, in 1/1000
    private static func speed(_ view: Int, permille: Int) -> Int {
        view * permille * 1024 / 1000
    }

    // MARK: Nothing moves

    private static func stillScreen(seed: UInt64) -> SimScenario {
        var scroller = makeScroller("stillScreen", seed: seed, width: 720, height: 1560, tenths: 20, profile: .settings)
        scroller.track.rest(150)
        return finish(scroller)
    }

    private static func stillCable(seed: UInt64) -> SimScenario {
        var scroller = makeScroller("stillCable", seed: seed, tenths: 20)
        scroller.track.rest(150)
        scroller.stage.scenario.sendsOnlyChanges = false
        return finish(scroller)
    }

    private static func noisyCable(seed: UInt64) -> SimScenario {
        // a text field with a cursor that blinks twice a second
        var field = SimRect()
        var scroller = makeScroller("noisyCable", seed: seed, width: 720, height: 1560, tenths: 20, startPercent: 0,
                                    build: { builder in
            builder.paragraph(lines: 2)
            field = builder.reserve(points: 44)
        })
        let stage = scroller.stage
        let unit = stage.unit
        let cursor = SimSprite(width: stage.snapped(12 * unit), height: stage.snapped(34 * unit),
                               level: stage.theme.background)
        cursor.fill(SimRect(x: 4 * unit, y: 2 * unit, width: 3 * unit, height: 30 * unit), level: stage.theme.text)
        let cursorSprite = stage.scenario.add(cursor)
        let box = SimRect(x: field.x + 20 * unit, y: field.y + 6 * unit, width: cursor.width, height: cursor.height)
        scroller.track.rest(210)
        for (tick, offset) in scroller.track.positions.enumerated() {
            var scene = stage.scene(scroller.page, offset: offset)
            if (tick / 30) % 2 == 0 {
                stage.put(stage.inset(cursorSprite, box: box, in: scroller.page, offset: offset, slot: SimSlot.cursor),
                          into: &scene)
            }
            stage.scenario.scenes.append(scene)
        }
        stage.scenario.sendsOnlyChanges = false
        stage.scenario.noiseOnRepeats = true
        stage.scenario.noise = 3
        return stage.finish()
    }

    // MARK: Scrolling

    private static func slowDrag(seed: UInt64) -> SimScenario {
        var scroller = makeScroller("slowDrag", seed: seed)
        var random = scroller.stage.random
        scroller.track.rest(45)
        scroller.track.drag(by: scroller.view * random.int(35, 60) / 100, ticks: random.int(100, 130))
        scroller.track.rest(random.int(25, 40))
        scroller.track.drag(by: -scroller.view * random.int(20, 45) / 100, ticks: random.int(80, 110))
        scroller.track.rest(60)
        scroller.showsIndicator = true
        return finish(scroller)
    }

    private static func steadyScroll(seed: UInt64) -> SimScenario {
        var scroller = makeScroller("steadyScroll", seed: seed, width: 720, height: 1560, tenths: 45, startPercent: 50)
        var random = scroller.stage.random
        let direction = random.chance(50) ? 1 : -1
        scroller.track.rest(45)
        scroller.track.glide(speed: direction * (random.int(9, 17) * 1024 + random.int(0, 1023)), ticks: 150)
        scroller.track.rest(70)
        return finish(scroller)
    }

    private static func flick(seed: UInt64) -> SimScenario {
        var scroller = makeScroller("flick", seed: seed, tenths: 50, profile: seed % 2 == 0 ? .feed : .article,
                                    startPercent: 5)
        var random = scroller.stage.random
        scroller.track.rest(45)
        scroller.track.flick(speed: speed(scroller.view, permille: random.int(50, 90)))
        scroller.track.rest(75)
        scroller.showsIndicator = true
        return finish(scroller)
    }

    private static func fastFlick(seed: UInt64) -> SimScenario {
        var scroller = makeScroller("fastFlick", seed: seed, width: 720, height: 1560, tenths: 85, startPercent: 3)
        var random = scroller.stage.random
        scroller.track.rest(45)
        scroller.track.flick(speed: speed(scroller.view, permille: random.int(300, 400)), keep: 940)
        scroller.track.rest(80)
        return finish(scroller)
    }

    private static func reverse(seed: UInt64) -> SimScenario {
        var scroller = makeScroller("reverse", seed: seed, tenths: 45, profile: .settings, startPercent: 25)
        var random = scroller.stage.random
        scroller.track.rest(45)
        let start = scroller.track.position
        scroller.track.flick(speed: speed(scroller.view, permille: random.int(45, 70)), maxTicks: random.int(22, 36))
        // caught by a finger and dragged back past where it started
        scroller.track.rest(random.int(2, 5))
        scroller.track.drag(by: start - scroller.track.position - scroller.view * random.int(8, 20) / 100,
                            ticks: random.int(40, 60))
        scroller.track.rest(random.int(20, 30))
        scroller.track.flick(speed: speed(scroller.view, permille: random.int(25, 40)))
        scroller.track.rest(70)
        scroller.showsIndicator = true
        return finish(scroller)
    }

    private static func tremble(seed: UInt64) -> SimScenario {
        var scroller = makeScroller("tremble", seed: seed, width: 720, height: 1560)
        var random = scroller.stage.random
        scroller.track.rest(45)
        scroller.track.tremble(amplitude: random.int(1, 3), ticks: 100, random: &random)
        scroller.track.rest(20)
        for step in 0..<6 {
            scroller.track.drag(by: (step % 2 == 0 ? 1 : -1) * random.int(5, 14), ticks: random.int(5, 9))
            scroller.track.rest(random.int(3, 9))
        }
        scroller.track.rest(60)
        return finish(scroller)
    }

    private static func rubberBand(seed: UInt64) -> SimScenario {
        var scroller = makeScroller("rubberBand", seed: seed, tenths: 17, startPercent: 10)
        var random = scroller.stage.random
        scroller.track.rest(45)
        // into the lower end at speed
        scroller.track.flick(speed: speed(scroller.view, permille: random.int(60, 90)))
        scroller.track.rest(random.int(30, 45))
        // back up and past the upper end with the finger, then let go
        scroller.track.drag(by: -scroller.track.position - scroller.view * random.int(8, 16) / 100,
                            ticks: random.int(40, 55))
        scroller.track.rest(random.int(3, 8))
        scroller.track.release()
        scroller.track.rest(70)
        return finish(scroller)
    }

    private static func stopAndGo(seed: UInt64) -> SimScenario {
        var scroller = makeScroller("stopAndGo", seed: seed, width: 720, height: 1560, tenths: 40,
                                profile: seed % 2 == 0 ? .settings : .article, startPercent: 5)
        var random = scroller.stage.random
        scroller.track.rest(45)
        for _ in 0..<random.int(4, 6) {
            scroller.track.drag(by: scroller.view * random.int(20, 42) / 100, ticks: random.int(14, 24))
            scroller.track.rest(random.int(8, 25))
        }
        scroller.track.rest(60)
        scroller.showsIndicator = true
        return finish(scroller)
    }

    /// Lists with one row height for the whole page
    private static func rows(_ name: String, seed: UInt64, kind: SimListKind, width: Int, height: Int) -> Scroller {
        var random = SimRandom(seed: seed).branch(0x726F_7773)
        let points = random.int(44, 52)
        let everyNth = kind == .identical ? random.int(4, 7) : 0
        var scroller = makeScroller(name, seed: seed, width: width, height: height, tenths: 60, profile: .sparse,
                                    startPercent: 4, build: { builder in
            // only lists, so that every part of the page repeats at the same distance
            while builder.y < builder.sprite.height - height - 80 * builder.unit {
                builder.list(rows: 12, kind: kind, points: points, icons: true, values: kind == .identical,
                             everyNthDistinct: everyNth)
            }
        })
        scroller.rowPitch = points * scroller.stage.unit
        return scroller
    }

    private static func alikeRows(seed: UInt64) -> SimScenario {
        var scroller = rows("alikeRows", seed: seed, kind: .alike, width: 780, height: 1688)
        var random = scroller.stage.random
        let pitch = scroller.rowPitch
        scroller.track.rest(45)
        // about one row per frame: the picture hardly seems to move
        scroller.track.glide(speed: pitch * 1024 + random.int(-3, 3) * 1024 + random.int(0, 1023), ticks: 36)
        scroller.track.rest(random.int(12, 20))
        // about half a row per frame: up and down look the same
        scroller.track.glide(speed: -(pitch * 512 + random.int(-2, 2) * 1024 + random.int(0, 1023)), ticks: 40)
        scroller.track.rest(random.int(12, 20))
        scroller.track.flick(speed: speed(scroller.view, permille: random.int(40, 70)))
        scroller.track.rest(70)
        return finish(scroller)
    }

    private static func identicalRows(seed: UInt64) -> SimScenario {
        var scroller = rows("identicalRows", seed: seed, kind: .identical, width: 720, height: 1560)
        var random = scroller.stage.random
        let pitch = scroller.rowPitch
        scroller.track.rest(45)
        scroller.track.drag(by: pitch * random.int(4, 7) + random.int(0, pitch), ticks: random.int(50, 70))
        scroller.track.rest(random.int(15, 25))
        scroller.track.flick(speed: speed(scroller.view, permille: random.int(40, 70)))
        scroller.track.rest(70)
        return finish(scroller)
    }

    private static func sparsePage(seed: UInt64) -> SimScenario {
        var scroller = makeScroller("sparsePage", seed: seed, tenths: 45, profile: .sparse, startPercent: 10)
        var random = scroller.stage.random
        scroller.track.rest(45)
        scroller.track.drag(by: scroller.view * random.int(40, 70) / 100, ticks: random.int(60, 90))
        scroller.track.rest(random.int(15, 30))
        scroller.track.flick(speed: speed(scroller.view, permille: random.int(40, 70)))
        scroller.track.rest(70)
        return finish(scroller)
    }

    private static func darkTheme(seed: UInt64) -> SimScenario {
        var scroller = makeScroller("darkTheme", seed: seed, width: 720, height: 1560, dark: true, tenths: 45,
                                    startPercent: 8)
        var random = scroller.stage.random
        scroller.track.rest(45)
        scroller.track.flick(speed: speed(scroller.view, permille: random.int(45, 75)))
        scroller.track.rest(random.int(15, 25))
        scroller.track.drag(by: -scroller.view * random.int(30, 60) / 100, ticks: random.int(50, 80))
        scroller.track.rest(65)
        scroller.showsIndicator = true
        return finish(scroller)
    }

    // MARK: What does not scroll

    private static func frostedBars(seed: UInt64) -> SimScenario {
        var scroller = makeScroller("frostedBars", seed: seed, tenths: 40, startPercent: 15,
                                prepare: { $0.addBars(frosted: true) })
        var random = scroller.stage.random
        scroller.track.rest(45)
        scroller.track.drag(by: scroller.view * random.int(30, 50) / 100, ticks: random.int(70, 100))
        scroller.track.rest(random.int(20, 30))
        scroller.track.flick(speed: speed(scroller.view, permille: random.int(40, 65)))
        scroller.track.rest(70)
        return finish(scroller)
    }

    private static func floatingButton(seed: UInt64) -> SimScenario {
        var scroller = makeScroller("floatingButton", seed: seed, width: 720, height: 1560, tenths: 40, profile: .settings,
                                startPercent: 10, prepare: { stage in
            stage.addBars()
            stage.addButton()
        })
        var random = scroller.stage.random
        scroller.track.rest(45)
        for _ in 0..<3 {
            scroller.track.drag(by: scroller.view * random.int(18, 35) / 100, ticks: random.int(25, 45))
            scroller.track.rest(random.int(12, 25))
        }
        scroller.track.drag(by: -scroller.view * random.int(25, 45) / 100, ticks: random.int(40, 60))
        scroller.track.rest(65)
        return finish(scroller)
    }

    private static func stickyHeader(seed: UInt64) -> SimScenario {
        var scroller = makeScroller("stickyHeader", seed: seed, tenths: 45, profile: .sections, startPercent: 0,
                                prepare: { stage in
            stage.addBars()
            stage.sticksHeaders = true
        })
        var random = scroller.stage.random
        scroller.track.rest(45)
        scroller.track.glide(speed: random.int(7, 12) * 1024 + random.int(0, 1023), ticks: 110)
        scroller.track.rest(random.int(15, 25))
        scroller.track.flick(speed: speed(scroller.view, permille: random.int(35, 55)))
        scroller.track.rest(random.int(15, 25))
        scroller.track.drag(by: -scroller.view * random.int(30, 60) / 100, ticks: random.int(50, 70))
        scroller.track.rest(65)
        return finish(scroller)
    }

    private static func pager(seed: UInt64) -> SimScenario {
        let stage = SimStage("pager", seed: seed, width: 720, height: 1560)
        stage.addBars()
        let page = stage.pager(screens: 4, profile: seed % 2 == 0 ? .article : .settings)
        var random = stage.random
        let screen = stage.viewport.width
        var track = SimTrack(start: 0, lower: 0, upper: stage.maxOffset(of: page))
        track.rest(45)
        // dragged part of the way, then it snaps to the next screen
        var target = 0
        for step in [1, 1, -1, 1] {
            target += step * screen
            track.drag(by: step * screen * random.int(30, 55) / 100, ticks: random.int(10, 16))
            track.settle(at: target, ticks: random.int(14, 20))
            track.rest(random.int(30, 45))
        }
        track.rest(40)
        for offset in track.positions {
            stage.scenario.scenes.append(stage.scene(page, offset: offset))
        }
        return stage.finish()
    }

    /// A row of cards with captions that glides sideways without a pause (a news ticker, a
    /// carousel that turns by itself) on a page that is dragged once and then rests: the page
    /// rests although the cards move, and its paragraphs at the bottom bar are translated. With
    /// `paragraphsAbove`, the row lies below that many paragraphs, near the bottom bar: it glides
    /// before the page is dragged, and the drag covers it, and the page rests for 11 s.
    private static func ticker(seed: UInt64, moving: Bool, paragraphsAbove: Int = 0) -> SimScenario {
        var box = SimRect()
        let name = paragraphsAbove > 0 ? "tickerLow" : moving ? "ticker" : "tickerStill"
        var scroller = makeScroller(name, seed: seed, tenths: 30, startPercent: 0, build: { builder in
            builder.heading(points: 22)
            for _ in 0..<paragraphsAbove { builder.paragraph(lines: 3) }
            box = builder.reserve(points: 190)
        })
        let stage = scroller.stage
        let unit = stage.unit
        var random = stage.random
        let cards = 8, cardWidth = stage.viewport.width * 62 / 100, gap = 12 * unit, pad = stage.viewport.width / 2
        let strip = SimSprite(width: pad + cards * (cardWidth + gap) + pad, height: box.height,
                              level: stage.theme.background)
        for card in 0..<cards {
            let x = pad + card * (cardWidth + gap)
            strip.fillTexture(SimRect(x: x, y: 8 * unit, width: cardWidth, height: 130 * unit), base: random.int(80, 180),
                              spread: random.int(25, 60), random: &random)
            let caption = stage.words.word(minLength: 5, maxLength: 9, capitalized: true) + " " + stage.words.word()
            strip.addText(caption, alternate: stage.words.misreading(of: caption), x: x + 4 * unit, y: 148 * unit,
                          size: 15 * unit, level: stage.theme.text, background: stage.theme.background)
        }
        let stripSprite = stage.scenario.add(strip)
        scroller.track.rest(45)
        scroller.track.drag(by: scroller.view * random.int(15, 30) / 100, ticks: random.int(40, 60))
        scroller.track.rest(paragraphsAbove > 0 ? 660 : 300)
        var side = SimTrack(start: 0, lower: 0, upper: strip.width)
        if moving { side.glide(speed: 2048, ticks: scroller.track.positions.count) } else { side.rest(scroller.track.positions.count) }
        for (tick, offset) in scroller.track.positions.enumerated() {
            var scene = stage.scene(scroller.page, offset: offset)
            let shift = pad - 16 * unit + side.positions[min(tick, side.positions.count - 1)]
            stage.put(stage.inset(stripSprite, box: box, in: scroller.page, offset: offset, shiftX: shift, degrades: true),
                      into: &scene)
            stage.scenario.scenes.append(scene)
        }
        return stage.finish()
    }

    private static func carousel(seed: UInt64) -> SimScenario {
        var box = SimRect()
        var scroller = makeScroller("carousel", seed: seed, tenths: 30, startPercent: 0, build: { builder in
            builder.heading(points: 22)
            box = builder.reserve(points: 190)
        })
        let stage = scroller.stage
        let unit = stage.unit
        var random = stage.random
        // cards with a picture and a caption, with empty margins all around
        let cards = 6, cardWidth = stage.viewport.width * 62 / 100, gap = 12 * unit, pad = stage.viewport.width / 2
        let strip = SimSprite(width: pad + cards * (cardWidth + gap) + pad, height: box.height,
                              level: stage.theme.background)
        for card in 0..<cards {
            let x = pad + card * (cardWidth + gap)
            strip.fillTexture(SimRect(x: x, y: 8 * unit, width: cardWidth, height: 130 * unit), base: random.int(80, 180),
                              spread: random.int(25, 60), random: &random)
            let caption = stage.words.word(minLength: 5, maxLength: 9, capitalized: true) + " " + stage.words.word()
            strip.addText(caption, alternate: stage.words.misreading(of: caption), x: x + 4 * unit, y: 148 * unit,
                          size: 15 * unit, level: stage.theme.text, background: stage.theme.background)
        }
        let stripSprite = stage.scenario.add(strip)
        let pitch = cardWidth + gap
        var side = SimTrack(start: 0, lower: 0, upper: (cards - 1) * pitch)

        // first the cards move and the page rests, then the page scrolls
        side.rest(45)
        var target = 0
        for step in [1, 2, -1] {
            target += step * pitch
            side.drag(by: step * pitch * random.int(40, 70) / 100, ticks: random.int(10, 16))
            side.settle(at: target, ticks: random.int(14, 20))
            side.rest(random.int(25, 40))
        }
        scroller.track.rest(side.positions.count)
        scroller.track.drag(by: scroller.view * random.int(15, 30) / 100, ticks: random.int(40, 60))
        scroller.track.rest(random.int(20, 30))
        scroller.track.drag(by: -scroller.view * random.int(8, 14) / 100, ticks: random.int(25, 35))
        scroller.track.rest(65)
        for (tick, offset) in scroller.track.positions.enumerated() {
            var scene = stage.scene(scroller.page, offset: offset)
            let shift = pad - 16 * unit + side.positions[min(tick, side.positions.count - 1)]
            stage.put(stage.inset(stripSprite, box: box, in: scroller.page, offset: offset, shiftX: shift, degrades: true),
                      into: &scene)
            stage.scenario.scenes.append(scene)
        }
        return stage.finish()
    }

    private static func diagonalPan(seed: UInt64) -> SimScenario {
        let stage = SimStage("diagonalPan", seed: seed, width: 720, height: 1560)
        stage.addBars()
        let page = stage.sheet(columns: 2, tenths: 25, profile: .article)
        var random = stage.random
        let view = stage.viewport
        var down = SimTrack(start: stage.maxOffset(of: page) / 10, lower: 0, upper: stage.maxOffset(of: page))
        var across = SimTrack(start: view.width / 5, lower: 0, upper: view.width)
        down.rest(45)
        across.rest(45)
        // both ways at once, at different speeds
        let ticks = random.int(60, 85)
        down.drag(by: view.height * random.int(25, 45) / 100, ticks: ticks)
        across.drag(by: view.width * random.int(20, 40) / 100, ticks: ticks)
        let pause = random.int(18, 28)
        down.rest(pause)
        across.rest(pause)
        down.flick(speed: speed(view.height, permille: random.int(25, 40)))
        across.flick(speed: -speed(view.width, permille: random.int(25, 45)))
        // the two come to rest at different times
        let end = max(down.positions.count, across.positions.count) + 70
        down.rest(end - down.positions.count)
        across.rest(end - across.positions.count)
        for tick in 0..<end {
            stage.scenario.scenes.append(stage.scene(page, offset: down.positions[tick], across: across.positions[tick]))
        }
        return stage.finish()
    }

    // MARK: Changes that are not scrolling

    private static func alert(seed: UInt64) -> SimScenario {
        var scroller = makeScroller("alert", seed: seed, width: 720, height: 1560, tenths: 20, profile: .settings)
        let stage = scroller.stage
        var random = stage.random
        let dialog = stage.alert()
        let appears = random.int(50, 65), stays = random.int(70, 90)
        scroller.track.rest(appears + stays + 80)
        for (tick, offset) in scroller.track.positions.enumerated() {
            let isUp = tick >= appears && tick < appears + stays
            var scene = stage.scene(scroller.page, offset: offset, dimmed: isUp)
            if isUp { scene.layers.append(stage.layer(of: dialog)) }
            stage.scenario.scenes.append(scene)
        }
        return stage.finish()
    }

    private static func banner(seed: UInt64) -> SimScenario {
        var scroller = makeScroller("banner", seed: seed, tenths: 35, startPercent: 20)
        let stage = scroller.stage
        var random = stage.random
        let notice = stage.banner()
        let appears = random.int(70, 90), stays = random.int(70, 90), slide = 10
        scroller.track.rest(45)
        scroller.track.glide(speed: random.int(3, 6) * 1024 + random.int(0, 1023), ticks: appears + stays + 2 * slide)
        scroller.track.rest(70)
        let hidden = -(notice.rect.maxY + 4 * stage.unit)
        for (tick, offset) in scroller.track.positions.enumerated() {
            var scene = stage.scene(scroller.page, offset: offset)
            let since = tick - appears
            if since >= 0 && since < slide {
                scene.layers.append(stage.layer(of: notice, dy: hidden * (slide - since) / slide))
            } else if since >= slide && since < slide + stays {
                scene.layers.append(stage.layer(of: notice))
            } else if since >= slide + stays && since < 2 * slide + stays {
                scene.layers.append(stage.layer(of: notice, dy: hidden * (since - slide - stays + 1) / slide))
            }
            stage.scenario.scenes.append(scene)
        }
        return stage.finish()
    }

    private static func newScreen(seed: UInt64) -> SimScenario {
        let stage = SimStage("newScreen", seed: seed, width: 720, height: 1560)
        stage.addBars()
        var random = stage.random
        let firstBar = stage.topBar, secondBar = stage.makeTopBar()
        let first = stage.page(tenths: 20, profile: .settings), second = stage.page(tenths: 20, profile: .article)
        let offset = stage.maxOffset(of: first) * random.int(0, 40) / 100
        let leaves = random.int(50, 65), returns = leaves + random.int(80, 100)
        for tick in 0..<(returns + 80) {
            let isAway = tick >= leaves && tick < returns
            stage.topBar = isAway ? secondBar : firstBar
            stage.scenario.scenes.append(stage.scene(isAway ? second : first, offset: isAway ? 0 : offset))
        }
        return stage.finish()
    }

    private static func slideOver(seed: UInt64) -> SimScenario {
        let stage = SimStage("slideOver", seed: seed)
        stage.addBars()
        var random = stage.random
        let firstBar = stage.topBar, secondBar = stage.makeTopBar()
        let first = stage.page(tenths: 20, profile: .article), second = stage.page(tenths: 20, profile: .settings)
        let offset = stage.maxOffset(of: first) * random.int(0, 40) / 100
        // both screens side by side, as they are during the slide
        let view = stage.viewport
        let both = SimSprite(width: 2 * view.width, height: view.height, level: stage.theme.background)
        let firstSprite = stage.scenario.sprites[first.sprite], secondSprite = stage.scenario.sprites[second.sprite]
        both.copy(from: firstSprite, rect: SimRect(x: 0, y: first.pad + offset, width: view.width, height: view.height),
                  toX: 0, toY: 0)
        both.copy(from: secondSprite, rect: SimRect(x: 0, y: second.pad, width: view.width, height: view.height),
                  toX: view.width, toY: 0)
        let slide = SimPage(sprite: stage.scenario.add(both), pad: 0, length: 2 * view.width, isHorizontal: true)

        let leaves = random.int(50, 65), duration = random.int(18, 26), stays = random.int(75, 95)
        var track = SimTrack(start: 0, lower: 0, upper: view.width)
        track.rest(leaves)
        track.settle(at: view.width, ticks: duration)
        track.rest(stays)
        track.settle(at: 0, ticks: duration)
        track.rest(75)
        for (tick, position) in track.positions.enumerated() {
            // the title changes when the slide starts
            let isAway = tick >= leaves && tick < leaves + duration + stays
            stage.topBar = isAway ? secondBar : firstBar
            if position == 0 {
                stage.scenario.scenes.append(stage.scene(first, offset: offset))
            } else if position == view.width {
                stage.scenario.scenes.append(stage.scene(second, offset: 0))
            } else {
                stage.scenario.scenes.append(stage.scene(slide, offset: position))
            }
        }
        return stage.finish()
    }

    private static func textReplaced(seed: UInt64) -> SimScenario {
        var box = SimRect()
        var scroller = makeScroller("textReplaced", seed: seed, width: 720, height: 1560, tenths: 25, profile: .settings,
                                startPercent: 0, build: { builder in
            builder.paragraph(lines: 2)
            box = builder.reserve(points: 56)
        })
        let stage = scroller.stage
        let unit = stage.unit
        var random = stage.random
        // the states of a status line
        var states: [Int] = []
        for _ in 0..<4 {
            let label = SimSprite(width: box.width, height: box.height, level: stage.theme.background)
            let text = stage.words.word(minLength: 4, maxLength: 9, capitalized: true) + " " + stage.words.word() + " "
                + stage.words.word()
            label.addText(text, alternate: stage.words.misreading(of: text), x: 16 * unit, y: (box.height - 17 * unit) / 2,
                          size: 17 * unit, level: stage.theme.accent, background: stage.theme.background)
            states.append(stage.scenario.add(label))
        }
        var changes: [Int] = []
        var tick = random.int(50, 65)
        for _ in 1..<states.count {
            changes.append(tick)
            tick += random.int(45, 70)
        }
        scroller.track.rest(tick)
        scroller.track.drag(by: scroller.view * random.int(10, 20) / 100, ticks: random.int(30, 45))
        scroller.track.rest(65)
        for (tick, offset) in scroller.track.positions.enumerated() {
            var scene = stage.scene(scroller.page, offset: offset)
            let state = changes.filter { $0 <= tick }.count
            stage.put(stage.inset(states[state], box: box, in: scroller.page, offset: offset), into: &scene)
            stage.scenario.scenes.append(scene)
        }
        return stage.finish()
    }

    private static func video(seed: UInt64) -> SimScenario {
        var box = SimRect()
        var scroller = makeScroller("video", seed: seed, tenths: 30, startPercent: 0, build: { builder in
            builder.paragraph(lines: 2)
            box = builder.reserve(points: 210)
        })
        let stage = scroller.stage
        let unit = stage.unit
        var random = stage.random
        // a handful of pictures that follow each other, with an empty margin around them
        var pictures: [Int] = []
        let base = random.int(70, 170)
        for index in 0..<8 {
            let picture = SimSprite(width: box.width, height: box.height, level: stage.theme.background)
            let area = SimRect(x: 16 * unit, y: 8 * unit, width: box.width - 32 * unit, height: box.height - 16 * unit)
            picture.fillGradient(area, from: base + index * 6, to: base + 60 - index * 5, down: index * 8 - 30)
            for _ in 0..<12 {
                picture.fill(SimRect(x: area.x + random.below(area.width - 60 * unit),
                                     y: area.y + random.below(area.height - 40 * unit),
                                     width: random.int(20, 60) * unit, height: random.int(12, 40) * unit),
                             level: SimLevel.clamped(base + random.int(-50, 70)))
            }
            pictures.append(stage.scenario.add(picture))
        }
        scroller.track.rest(80)
        scroller.track.drag(by: scroller.view * random.int(20, 35) / 100, ticks: random.int(60, 90))
        scroller.track.rest(random.int(30, 45))
        scroller.track.drag(by: -scroller.view * random.int(8, 15) / 100, ticks: random.int(30, 40))
        scroller.track.rest(60)
        for (tick, offset) in scroller.track.positions.enumerated() {
            var scene = stage.scene(scroller.page, offset: offset)
            // 30 pictures per second
            stage.put(stage.inset(pictures[(tick / 2) % pictures.count], box: box, in: scroller.page, offset: offset),
                      into: &scene)
            stage.scenario.scenes.append(scene)
        }
        return stage.finish()
    }

    // MARK: Sources and sizes

    private static func slowTranslator(seed: UInt64) -> SimScenario {
        var scroller = makeScroller("slowTranslator", seed: seed, width: 720, height: 1560, tenths: 30, profile: .settings,
                                startPercent: 5)
        var random = scroller.stage.random
        scroller.track.rest(190)
        let start = scroller.track.position
        scroller.track.drag(by: scroller.view * random.int(55, 80) / 100, ticks: random.int(40, 60))
        scroller.track.rest(330)
        // back to where everything is translated already
        scroller.track.drag(by: start - scroller.track.position, ticks: random.int(40, 60))
        scroller.track.rest(80)
        scroller.stage.scenario.translatorLatency = 1.2
        scroller.stage.scenario.translatorWaitsForRest = true
        return finish(scroller)
    }

    private static func halfRate(seed: UInt64) -> SimScenario {
        var scroller = makeScroller("halfRate", seed: seed, tenths: 45, startPercent: 8)
        var random = scroller.stage.random
        scroller.track.rest(45)
        scroller.track.flick(speed: speed(scroller.view, permille: random.int(35, 60)))
        scroller.track.rest(random.int(15, 25))
        scroller.track.drag(by: -scroller.view * random.int(30, 55) / 100, ticks: random.int(60, 80))
        scroller.track.rest(65)
        let frames = SimCadence.frames(ticks: scroller.track.positions.count, interval: 2, random: &random)
        return finish(scroller, frames: frames)
    }

    private static func droppedFrames(seed: UInt64) -> SimScenario {
        var scroller = makeScroller("droppedFrames", seed: seed, width: 720, height: 1560, tenths: 50, startPercent: 8)
        var random = scroller.stage.random
        scroller.track.rest(45)
        scroller.track.glide(speed: random.int(8, 14) * 1024 + random.int(0, 1023), ticks: 80)
        scroller.track.rest(random.int(10, 20))
        scroller.track.flick(speed: speed(scroller.view, permille: random.int(45, 70)))
        scroller.track.rest(65)
        let frames = SimCadence.frames(ticks: scroller.track.positions.count, dropPercent: 12, random: &random)
        return finish(scroller, frames: frames)
    }

    private static func cableScroll(seed: UInt64) -> SimScenario {
        var scroller = makeScroller("cableScroll", seed: seed, tenths: 40, profile: .settings, startPercent: 5)
        var random = scroller.stage.random
        scroller.track.rest(45)
        for _ in 0..<3 {
            scroller.track.drag(by: scroller.view * random.int(25, 45) / 100, ticks: random.int(16, 28))
            scroller.track.rest(random.int(20, 35))
        }
        scroller.track.flick(speed: -speed(scroller.view, permille: random.int(30, 50)))
        scroller.track.rest(60)
        scroller.stage.scenario.sendsOnlyChanges = false
        scroller.showsIndicator = true
        return finish(scroller)
    }

    private static func iPhone(seed: UInt64) -> SimScenario {
        var scroller = makeScroller("iPhone", seed: seed, width: 1170, height: 2532, unit: 3, tenths: 40, startPercent: 8)
        var random = scroller.stage.random
        scroller.track.rest(45)
        scroller.track.flick(speed: speed(scroller.view, permille: random.int(45, 75)))
        scroller.track.rest(random.int(15, 25))
        scroller.track.drag(by: -scroller.view * random.int(25, 50) / 100, ticks: random.int(50, 70))
        scroller.track.rest(65)
        scroller.showsIndicator = true
        return finish(scroller)
    }

    private static func android(seed: UInt64) -> SimScenario {
        var scroller = makeScroller("android", seed: seed, width: 1440, height: 3200, unit: 4, tenths: 40,
                                profile: seed % 2 == 0 ? .article : .settings, startPercent: 8)
        var random = scroller.stage.random
        scroller.track.rest(45)
        scroller.track.glide(speed: random.int(16, 30) * 1024 + random.int(0, 1023), ticks: 70)
        scroller.track.rest(random.int(15, 25))
        scroller.track.flick(speed: speed(scroller.view, permille: random.int(40, 65)))
        scroller.track.rest(65)
        scroller.showsIndicator = true
        return finish(scroller)
    }

    private static func iPadLandscape(seed: UInt64) -> SimScenario {
        var scroller = makeScroller("iPadLandscape", seed: seed, width: 2732, height: 2048, unit: 2, tenths: 35,
                                    startPercent: 8, prepare: { stage in
            stage.addBars()
            stage.addSidebar()
        })
        var random = scroller.stage.random
        scroller.track.rest(45)
        scroller.track.drag(by: scroller.view * random.int(30, 50) / 100, ticks: random.int(50, 70))
        scroller.track.rest(random.int(15, 25))
        scroller.track.flick(speed: speed(scroller.view, permille: random.int(35, 55)))
        scroller.track.rest(65)
        return finish(scroller)
    }

    // MARK: What a phone does besides scrolling

    private static func crossFade(seed: UInt64) -> SimScenario {
        let stage = SimStage("crossFade", seed: seed, width: 720, height: 1560)
        stage.addBars()
        var random = stage.random
        let firstBar = stage.topBar, secondBar = stage.makeTopBar()
        let first = stage.page(tenths: 20, profile: .article), second = stage.page(tenths: 20, profile: .settings)
        let from = stage.crop(first, offset: stage.maxOffset(of: first) * random.int(0, 40) / 100)
        let to = stage.crop(second, offset: 0)
        // The pictures in between. Only the text of the picture that dominates can be read (at
        // half and half neither): two texts on top of each other are no paragraph a recognizer
        // would return, and a translation must be gone once its text is fainter than the new one.
        let steps = random.int(14, 20)
        var pages = [stage.scenario.add(from)], tops = [firstBar]
        for step in 1..<steps {
            let keepsOld = 2 * step < steps, keepsNew = 2 * step > steps
            pages.append(stage.scenario.add(from.blended(with: to, weight: step, of: steps, keepsOwnText: keepsOld,
                                                         keepsOtherText: keepsNew)))
            let bar = stage.scenario.sprites[firstBar].blended(with: stage.scenario.sprites[secondBar], weight: step,
                                                               of: steps, keepsOwnText: keepsOld, keepsOtherText: keepsNew)
            tops.append(stage.scenario.add(bar))
        }
        pages.append(stage.scenario.add(to))
        tops.append(secondBar)
        // there, and later back again
        var mix = [Int](repeating: 0, count: random.int(50, 65))
        mix += Array(1...steps)
        mix += [Int](repeating: steps, count: random.int(80, 100))
        mix += Array((0..<steps).reversed())
        mix += [Int](repeating: 0, count: 75)
        for weight in mix {
            stage.topBar = tops[weight]
            stage.scenario.scenes.append(stage.scene(stage.fixedPage(pages[weight]), offset: 0))
        }
        return stage.finish()
    }

    private static func swipeBack(seed: UInt64) -> SimScenario {
        let stage = SimStage("swipeBack", seed: seed)
        stage.addBars()
        var random = stage.random
        let upperBar = stage.topBar, lowerBar = stage.makeTopBar()
        let lower = stage.page(tenths: 20, profile: .settings), upper = stage.page(tenths: 20, profile: .article)
        let lowerOffset = stage.maxOffset(of: lower) * random.int(0, 40) / 100
        let view = stage.viewport
        let cover = stage.scenario.add(stage.crop(upper, offset: stage.maxOffset(of: upper) * random.int(0, 40) / 100))
        var track = SimTrack(start: 0, lower: 0, upper: view.width)
        track.rest(45)
        // dragged a third of the way, held, let go: it springs back
        track.drag(by: view.width * random.int(28, 42) / 100, ticks: random.int(18, 28))
        track.rest(random.int(8, 16))
        track.settle(at: 0, ticks: random.int(10, 14))
        track.rest(random.int(35, 45))
        // dragged further and let go: the screen below takes over
        track.drag(by: view.width * random.int(55, 70) / 100, ticks: random.int(14, 22))
        track.settle(at: view.width, ticks: random.int(10, 14))
        track.rest(75)
        for position in track.positions {
            let shift = min(view.width, stage.snapped(max(0, position)))
            stage.topBar = shift * 2 > view.width ? lowerBar : upperBar
            // the screen below lies a third of the remaining way to the left
            var scene = stage.scene(lower, offset: lowerOffset, across: (view.width - shift) * 3 / 10)
            if shift < view.width {
                stage.put(SimLayer(slot: SimSlot.cover, sprite: cover, x: view.x + shift, y: view.y, clip: view,
                                   degrades: true), into: &scene)
            }
            stage.scenario.scenes.append(scene)
        }
        return stage.finish()
    }

    private static func keyboard(seed: UInt64) -> SimScenario {
        var scroller = makeScroller("keyboard", seed: seed, width: 720, height: 1560, tenths: 30, startPercent: 55)
        let stage = scroller.stage
        var random = stage.random
        let board = stage.keyboard()
        let appears = random.int(50, 65), slide = random.int(14, 20), stays = random.int(90, 110)
        // the page moves up with the keyboard, but not as far
        let lift = board.rect.height * random.int(55, 90) / 100
        let start = scroller.track.position
        scroller.track.rest(appears)
        scroller.track.settle(at: start + lift, ticks: slide)
        scroller.track.rest(stays)
        scroller.track.settle(at: start, ticks: slide)
        scroller.track.rest(75)
        // how much of the keyboard is still below the edge of the screen
        var below = SimTrack(start: board.rect.height, lower: 0, upper: board.rect.height)
        below.rest(appears)
        below.settle(at: 0, ticks: slide)
        below.rest(stays)
        below.settle(at: board.rect.height, ticks: slide)
        below.rest(75)
        for (tick, offset) in scroller.track.positions.enumerated() {
            var scene = stage.scene(scroller.page, offset: offset)
            let down = below.positions[tick]
            if down < board.rect.height {
                stage.put(SimLayer(slot: SimSlot.keyboard, sprite: board.sprite, x: board.rect.x, y: board.rect.y + down,
                                   clip: board.rect.offsetBy(dx: 0, dy: down)), into: &scene)
            }
            stage.scenario.scenes.append(scene)
        }
        return stage.finish()
    }

    private static func lateContent(seed: UInt64) -> SimScenario {
        var picture = SimRect(), hole = SimRect()
        var split = 0
        var scroller = makeScroller("lateContent", seed: seed, tenths: 30, startPercent: 0, build: { builder in
            builder.heading(points: 22)
            picture = builder.reserve(points: 150)
            builder.paragraph(lines: 3)
            hole = builder.reserve(points: 64)
            builder.paragraph(lines: 2)
            builder.gap(4)
            split = builder.y
            builder.gap(4)
        })
        let stage = scroller.stage
        let unit = stage.unit
        var random = stage.random
        let theme = stage.theme
        // the grey box that stands in for the picture, and the picture
        let inner = SimRect(x: 16 * unit, y: 0, width: picture.width - 32 * unit, height: picture.height)
        let box = SimSprite(width: picture.width, height: picture.height, level: theme.background)
        box.fill(inner, level: theme.card)
        let loaded = SimSprite(width: picture.width, height: picture.height, level: theme.background)
        loaded.fillTexture(inner, base: random.int(80, 170), spread: random.int(30, 60), random: &random)
        let boxSprite = stage.scenario.add(box), loadedSprite = stage.scenario.add(loaded)
        // the paragraph that appears in the empty place
        let late = SimSprite(width: hole.width, height: hole.height, level: theme.background)
        let lateBuilder = SimPageBuilder(sprite: late, unit: unit, theme: theme, words: stage.words,
                                         random: random.branch(0x6C61_7465), top: 8 * unit)
        lateBuilder.paragraph(lines: 2)
        let lateSprite = stage.scenario.add(late)
        // what arrives last and pushes everything below `split` down: a card with a line of text
        let pushHeight = stage.snapped(random.int(84, 130) * unit)
        let push = SimSprite(width: stage.viewport.width, height: pushHeight, level: theme.background)
        push.fill(SimRect(x: 16 * unit, y: 10 * unit, width: push.width - 32 * unit, height: pushHeight - 20 * unit),
                  level: theme.card)
        let notice = stage.words.word(minLength: 5, maxLength: 9, capitalized: true) + " " + stage.words.word() + " "
            + stage.words.word()
        push.addText(notice, alternate: stage.words.misreading(of: notice), x: 32 * unit, y: (pushHeight - 17 * unit) / 2,
                     size: 17 * unit, level: theme.text, background: theme.card, bold: true)
        let pushSprite = stage.scenario.add(push)

        let pictureLoads = random.int(55, 70), textAppears = pictureLoads + random.int(45, 60)
        let pushed = textAppears + random.int(50, 65)
        scroller.track.rest(pushed + random.int(55, 70))
        scroller.track.drag(by: scroller.view * random.int(15, 30) / 100, ticks: random.int(40, 60))
        scroller.track.rest(70)
        for (tick, offset) in scroller.track.positions.enumerated() {
            var scene = stage.scene(scroller.page, offset: offset)
            stage.put(stage.inset(tick < pictureLoads ? boxSprite : loadedSprite, box: picture, in: scroller.page,
                                  offset: offset), into: &scene)
            if tick >= textAppears {
                stage.put(stage.inset(lateSprite, box: hole, in: scroller.page, offset: offset, slot: SimSlot.cursor),
                          into: &scene)
            }
            if tick >= pushed {
                stage.split(&scene, page: scroller.page, row: split, offset: offset, height: pushHeight, filler: pushSprite)
            }
            stage.scenario.scenes.append(scene)
        }
        return stage.finish()
    }

    private static func zoom(seed: UInt64) -> SimScenario {
        let scroller = makeScroller("zoom", seed: seed, width: 720, height: 1560, tenths: 20, startPercent: 20)
        let stage = scroller.stage
        var random = stage.random
        let view = stage.viewport
        let offset = scroller.track.position
        let source = stage.crop(scroller.page, offset: offset)
        // the point between the fingers stays where it is
        let centerX = view.width * random.int(35, 65) / 100, centerY = view.height * random.int(30, 70) / 100
        let largest = random.int(140, 190)
        let grow = random.int(20, 30), shrink = random.int(14, 20)
        // size in percent, tick by tick: out with the fingers, rest, back by itself
        var percents = [Int](repeating: 100, count: 50)
        for tick in 1...grow {
            percents.append(100 + (largest - 100) * eased(tick, of: grow) / 1024)
        }
        percents += [Int](repeating: largest, count: random.int(80, 100))
        for tick in 1...shrink {
            percents.append(largest - (largest - 100) * eased(tick, of: shrink) / 1024)
        }
        percents += [Int](repeating: 100, count: 75)
        var enlarged: [Int: Int] = [:]
        for percent in percents {
            if percent <= 100 {
                stage.scenario.scenes.append(stage.scene(scroller.page, offset: offset))
                continue
            }
            let sprite: Int
            if let known = enlarged[percent] {
                sprite = known
            } else {
                let window = SimRect(x: centerX - centerX * 100 / percent, y: centerY - centerY * 100 / percent,
                                     width: view.width * 100 / percent, height: view.height * 100 / percent)
                sprite = stage.scenario.add(SimSprite.magnified(source, window: window, width: view.width,
                                                                height: view.height))
                enlarged[percent] = sprite
            }
            stage.scenario.scenes.append(stage.scene(stage.fixedPage(sprite), offset: 0))
        }
        return stage.finish()
    }

    private static func largeTitle(seed: UInt64) -> SimScenario {
        let stage = SimStage("largeTitle", seed: seed)
        let unit = stage.unit
        let title = stage.words.word(minLength: 6, maxLength: 10, capitalized: true)
        let back = stage.words.word(minLength: 4, maxLength: 6, capitalized: true)
        // the bar has no title while the large one can be seen
        stage.addBars(title: "", back: back)
        // (the label to go back is the same in both bars: so is what it is misread as)
        let plainBar = stage.topBar
        guard let backMisreading = stage.scenario.sprites[plainBar].lines.first(where: { $0.text == back })?.alternate
        else { preconditionFailure("largeTitle: the bar without a title has no label to go back") }
        let titledBar = stage.makeTopBar(title: title, back: back, backMisreading: backMisreading)
        var random = stage.random
        var hero = SimRect()
        var titleBottom = 0
        let page = stage.page(tenths: 35, profile: .article, build: { builder in
            builder.text([title], size: 34 * unit, x: builder.left + builder.margin,
                         width: builder.columnWidth - 2 * builder.margin, align: .left, level: stage.theme.text,
                         background: stage.theme.background, bold: true)
            titleBottom = builder.y
            hero = builder.reserve(points: 170)
        })
        // a picture that is taller than its frame and moves at half the speed of the page
        let extra = hero.height / 2
        let picture = SimSprite(width: hero.width, height: hero.height + extra, level: stage.theme.background)
        picture.fillTexture(SimRect(x: 16 * unit, y: 0, width: hero.width - 32 * unit, height: picture.height),
                            base: random.int(90, 160), spread: random.int(30, 55), random: &random)
        let pictureSprite = stage.scenario.add(picture)
        // the title of the bar fades in within an eighth of a second
        let steps = 8
        var bars = [plainBar]
        for step in 1..<steps {
            let bar = stage.scenario.sprites[plainBar].blended(with: stage.scenario.sprites[titledBar], weight: step,
                                                               of: steps, keepsOwnText: true,
                                                               keepsOtherText: step * 10 >= steps * 3)
            bars.append(stage.scenario.add(bar))
        }
        bars.append(titledBar)

        var track = SimTrack(start: 0, lower: 0, upper: stage.maxOffset(of: page))
        let view = stage.viewport.height
        track.rest(45)
        track.drag(by: view * random.int(18, 30) / 100, ticks: random.int(40, 55))
        track.rest(random.int(20, 30))
        track.flick(speed: speed(view, permille: random.int(25, 40)))
        track.rest(random.int(20, 30))
        track.drag(by: -track.position, ticks: random.int(55, 75))
        track.rest(70)
        var shown = 0
        for offset in track.positions {
            // the large title has gone under the bar
            let target = offset >= titleBottom - page.pad ? steps : 0
            if shown < target {
                shown += 1
            } else if shown > target {
                shown -= 1
            }
            stage.topBar = bars[shown]
            var scene = stage.scene(page, offset: offset)
            stage.put(stage.inset(pictureSprite, box: hero, in: page, offset: offset,
                                  shiftY: max(0, extra - max(0, offset) / 2)), into: &scene)
            stage.scenario.scenes.append(scene)
        }
        return stage.finish()
    }

    private static func typography(seed: UInt64) -> SimScenario {
        var scroller = makeScroller("typography", seed: seed, tenths: 50, profile: .typography, startPercent: 0,
                                    build: { builder in
            builder.heading(points: 40)
            builder.paragraph(lines: 2)
            // longer than the screen: never completely visible
            builder.paragraph(lines: 44)
        })
        var random = scroller.stage.random
        scroller.track.rest(45)
        scroller.track.drag(by: scroller.view * random.int(50, 80) / 100, ticks: random.int(70, 100))
        scroller.track.rest(random.int(20, 30))
        scroller.track.flick(speed: speed(scroller.view, permille: random.int(45, 70)))
        scroller.track.rest(random.int(20, 30))
        scroller.track.drag(by: -scroller.view * random.int(30, 50) / 100, ticks: random.int(50, 70))
        scroller.track.rest(70)
        return finish(scroller)
    }

    private static func pullToRefresh(seed: UInt64) -> SimScenario {
        var scroller = makeScroller("pullToRefresh", seed: seed, width: 720, height: 1560, tenths: 25,
                                    profile: seed % 2 == 0 ? .feed : .settings, startPercent: 0)
        let stage = scroller.stage
        let unit = stage.unit
        var random = stage.random
        let view = stage.viewport
        // the page after the refresh: new rows at the top, everything else further down
        let old = stage.scenario.sprites[scroller.page.sprite]
        let pad = scroller.page.pad
        let rows = random.int(2, 3), rowHeight = 52 * unit
        let added = rows * rowHeight
        let fresh = SimSprite(width: old.width, height: old.height + added, level: stage.theme.background)
        fresh.copy(from: old, rect: SimRect(x: 0, y: pad, width: old.width, height: old.height - pad), toX: 0,
                   toY: pad + added)
        let builder = SimPageBuilder(sprite: fresh, unit: unit, theme: stage.theme, words: stage.words,
                                     random: random.branch(0x6672_6573_68), top: pad + 14 * unit)
        builder.list(rows: rows, kind: .distinct, points: 52, icons: true)
        var refreshed = scroller.page
        refreshed.sprite = stage.scenario.add(fresh)
        refreshed.length += added

        // the spinner: eight dots in a ring, one of them dark, going round
        let side = stage.snapped(32 * unit), dot = 4 * unit
        let ringX = [0, 7, 10, 7, 0, -7, -10, -7], ringY = [-10, -7, 0, 7, 10, 7, 0, -7]
        var spinner: [Int] = []
        for phase in ringX.indices {
            let sprite = SimSprite(width: side, height: side, level: stage.theme.background)
            for index in ringX.indices {
                sprite.fill(SimRect(x: side / 2 + ringX[index] * unit - dot / 2, y: side / 2 + ringY[index] * unit - dot / 2,
                                    width: dot, height: dot),
                            level: index == phase ? stage.theme.text : stage.theme.separator)
            }
            spinner.append(stage.scenario.add(sprite))
        }
        let spinnerRect = SimRect(x: stage.snapped((stage.width - side) / 2), y: view.y + stage.snapped(14 * unit),
                                  width: side, height: side)

        let holdAt = 64 * unit
        scroller.track.rest(45)
        scroller.track.drag(by: -random.int(110, 150) * unit, ticks: random.int(30, 45))
        scroller.track.rest(random.int(4, 10))
        scroller.track.settle(at: -holdAt, ticks: random.int(10, 14))
        scroller.track.rest(random.int(50, 70))
        // the new rows are there: the page settles with them at the top
        let swap = scroller.track.positions.count
        scroller.track.settle(at: 0, ticks: random.int(14, 20))
        scroller.track.rest(75)
        for (tick, offset) in scroller.track.positions.enumerated() {
            var scene = stage.scene(tick < swap ? scroller.page : refreshed, offset: offset)
            // the spinner shows while the page leaves room for it
            if -offset >= spinnerRect.maxY - view.y + 2 * unit {
                stage.put(SimLayer(slot: SimSlot.inset, sprite: spinner[(tick / 4) % spinner.count], x: spinnerRect.x,
                                   y: spinnerRect.y, clip: spinnerRect), into: &scene)
            }
            stage.scenario.scenes.append(scene)
        }
        return stage.finish()
    }

    /// A page of list rows only: the same labels whatever the size of the frame
    private static func rowsOnly(_ name: String, seed: UInt64, width: Int, height: Int) -> Scroller {
        makeScroller(name, seed: seed, width: width, height: height, tenths: 40, profile: .sparse, startPercent: 4,
                     build: { builder in
            while builder.y < builder.sprite.height - height - 80 * builder.unit {
                builder.list(rows: 10, kind: .distinct, points: 50, icons: true)
            }
        })
    }

    private static func rotation(seed: UInt64) -> SimScenario {
        var upright = rowsOnly("rotation", seed: seed, width: 780, height: 1688)
        var random = upright.stage.random
        upright.track.rest(45)
        upright.track.drag(by: upright.view * random.int(30, 45) / 100, ticks: random.int(40, 55))
        upright.track.rest(random.int(30, 40))
        // still moving when the phone is turned: a reading is under way
        upright.track.glide(speed: random.int(4, 9) * 1024 + random.int(0, 1023), ticks: random.int(18, 26))
        let first = finish(upright)

        var turned = rowsOnly("rotation", seed: seed, width: 1688, height: 780)
        turned.track.rest(random.int(70, 90))
        turned.track.drag(by: turned.view * random.int(50, 80) / 100, ticks: random.int(35, 50))
        turned.track.rest(75)
        first.sequel = finish(turned)
        return first
    }

    private static func services(seed: UInt64) -> SimScenario {
        var scroller = makeScroller("services", seed: seed, width: 720, height: 1560, tenths: 25, profile: .settings,
                                    startPercent: 5)
        var random = scroller.stage.random
        // long enough for the texts that were put off to be offered again (after 5 s)
        scroller.track.rest(400)
        scroller.track.drag(by: scroller.view * random.int(25, 40) / 100, ticks: random.int(40, 60))
        scroller.track.rest(110)
        scroller.stage.scenario.failingPasses = [1, 3]
        scroller.stage.scenario.postponedPercent = 30
        return finish(scroller)
    }

    private static func roughLink(seed: UInt64) -> SimScenario {
        var scroller = makeScroller("roughLink", seed: seed, tenths: 70, startPercent: 5)
        var random = scroller.stage.random
        scroller.track.rest(45)
        scroller.track.flick(speed: speed(scroller.view, permille: random.int(110, 160)), keep: 955)
        scroller.track.rest(random.int(20, 30))
        scroller.track.flick(speed: -speed(scroller.view, permille: random.int(70, 110)), keep: 955)
        scroller.track.rest(70)
        let frames = SimCadence.frames(ticks: scroller.track.positions.count, interval: 2, dropPercent: 16, random: &random)
        scroller.stage.scenario.compression = 160
        return finish(scroller, frames: frames)
    }
}

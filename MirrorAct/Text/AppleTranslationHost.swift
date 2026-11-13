// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI
import Translation

/// A language pair that `AppleTranslationEngine` holds a session for. A pair that needs a
/// session again gets a new host with a new id, and so a new view: a view that is still there is
/// not given a second session.
struct AppleTranslationHost: Identifiable {
    let id = UUID()
    /// names the pair in the lists of the engine and in the log
    let pair: String
    let source: Locale.Language
    let target: Locale.Language
    /// the kind of models the session uses (see `AppleTranslationEngine`)
    let strategy: AppleTranslationStrategy
    /// Made once and never changed: SwiftUI starts the task of a view again when it is handed a
    /// configuration that differs from the last one, and the session in use is invalid from then on.
    let configuration: TranslationSession.Configuration

    init(pair: String, source: Locale.Language, target: Locale.Language, strategy: AppleTranslationStrategy) {
        self.pair = pair
        self.source = source
        self.target = target
        self.strategy = strategy
        if #available(macOS 26.4, *) {
            // without a strategy macOS takes .highFidelity, also for pairs the on-device models know
            configuration = TranslationSession.Configuration(source: source, target: target,
                                                             preferredStrategy: strategy.framework)
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }
}

/// The views that are given the sessions: one per host, none of them to be seen. A session is
/// lent to the engine for as long as `serve` runs.
struct AppleTranslationHostView: View {
    @ObservedObject var engine: AppleTranslationEngine

    var body: some View {
        ZStack {
            ForEach(engine.hosts) { host in
                Color.clear
                    .frame(width: 1, height: 1)
                    .translationTask(host.configuration) { session in
                        await engine.serve(host, with: session)
                    }
            }
        }
        .frame(width: 1, height: 1)
    }
}

/// The window for `AppleTranslationHostView`. A view only is given a session in a window that is
/// ordered in and not fully transparent. So the window is there but not to be seen: one point
/// small, nearly transparent, outside of all screens.
@MainActor
enum AppleTranslationHostWindow {
    static func make(for engine: AppleTranslationEngine) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: restingPlace, size: NSSize(width: 1, height: 1)),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        // not 0: SwiftUI does not run the task of a view in a fully transparent window
        window.alphaValue = 0.02
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        // translating goes on while the app is hidden (a recording may be running)
        window.canHide = false
        window.contentView = PassthroughHostingView(rootView: AppleTranslationHostView(engine: engine))
        // a borderless window never becomes key, and the app is not activated for it
        window.orderFrontRegardless()
        return window
    }

    /// While macOS asks whether it may load languages the window is on the main screen, because
    /// the question may be attached to the window that asked. It still is not to be seen there.
    /// Not while a sheet is attached: AppKit would move the window back where it was when the
    /// sheet ends (the engine places it again then).
    static func place(_ window: NSWindow, onScreen: Bool) {
        guard window.attachedSheet == nil else { return }
        var origin = restingPlace
        if onScreen, let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            origin = NSPoint(x: visible.midX, y: visible.minY + visible.height * 0.75)
        }
        if window.frame.origin != origin { window.setFrameOrigin(origin) }
    }

    /// above the mirror windows, which float while "Keep on top" is on
    static let questionLevel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)

    /// The question of macOS is a sheet of the window and takes its level: while it may be up the
    /// window lies above the mirror windows, or one of them could hide the question.
    static func raise(_ window: NSWindow, _ isRaised: Bool) {
        let level = isRaised ? questionLevel : .normal
        if window.level != level { window.level = level }
    }

    /// to the left of and below every screen
    private static var restingPlace: NSPoint {
        let frames = NSScreen.screens.map(\.frame)
        return NSPoint(x: (frames.map(\.minX).min() ?? 0) - 300, y: (frames.map(\.minY).min() ?? 0) - 300)
    }
}

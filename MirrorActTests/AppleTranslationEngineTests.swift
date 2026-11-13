// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Translation
import XCTest
@testable import MirrorAct

/// Translating with Apple's framework, as far as it can be tested without a session: nothing in
/// here asks macOS to translate or to load a language. (How the texts of a request are sorted by
/// language is tested with plain values in TextCore/LanguageMatchingTests.)
@MainActor
final class AppleTranslationEngineTests: XCTestCase {
    /// some of the languages macOS translates, as it lists them
    private let supported = ["de-DE", "en-GB", "en-US", "es-ES", "fr-FR", "it-IT", "ja-JP", "zh-CN", "zh-TW"]
        .map { Locale.Language(identifier: $0) }

    private func language(_ identifier: String) -> Locale.Language {
        Locale.Language(identifier: identifier)
    }

    private func languages(of texts: [String]) -> (findings: [LanguageMatching.Finding], screen: LanguageMatching.ScreenLanguage?) {
        AppleTranslationEngine.readLanguages(of: texts, tags: LanguageMatching.recognizerTags(for: supported),
                                             supported: supported)
    }

    // MARK: The engine

    func testTheEngineTranslatesOnThisMac() {
        let engine = AppleTranslationEngine()
        let client = AppleTranslationClient(engine: engine)
        XCTAssertEqual(client.name, "Apple")
        XCTAssertFalse(client.isRemote)
        XCTAssertFalse(client.prefersSettledText)
        XCTAssertTrue(engine.hosts.isEmpty)
    }

    func testAClientWithoutWorkCanBeCancelled() async throws {
        let engine = AppleTranslationEngine()
        let client = AppleTranslationClient(engine: engine)
        client.cancel()
        // from another thread it goes to the main actor by itself
        let other = AppleTranslationClient(engine: engine)
        await Task.detached { other.cancel() }.value
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(client.isCancelled)
        XCTAssertTrue(other.isCancelled)
        XCTAssertTrue(engine.hosts.isEmpty)
    }

    func testNotifyCanBeSetAndReadFromAnyThread() async {
        let client = AppleTranslationClient(engine: AppleTranslationEngine())
        XCTAssertNil(client.notify)
        client.notify = { _ in }
        let isSet = await Task.detached { client.notify != nil }.value
        XCTAssertTrue(isSet)
        await Task.detached { client.notify = nil }.value
        XCTAssertNil(client.notify)
    }

    func testARequestWithoutTextsNeedsNoSession() async throws {
        let engine = AppleTranslationEngine()
        let translations = try await AppleTranslationClient(engine: engine).translate([], into: language("de"))
        XCTAssertTrue(translations.isEmpty)
        XCTAssertTrue(engine.hosts.isEmpty)
    }

    /// A window that turns translating off ends its own turn only: another window's client
    /// goes on, and a cancelled client asks nothing of the engine anymore
    func testACancelledClientIsDoneAndLeavesTheOthersAlone() async throws {
        let engine = AppleTranslationEngine()
        let first = AppleTranslationClient(engine: engine)
        let second = AppleTranslationClient(engine: engine)
        first.cancel()
        XCTAssertTrue(first.isCancelled)
        XCTAssertFalse(second.isCancelled)
        let translations = try await first.translate(["Einstellungen", "Allgemein"], into: language("en"))
        XCTAssertEqual(translations, [nil, nil])
        XCTAssertTrue(engine.hosts.isEmpty)
        second.cancel()
    }

    func testEveryHostIsANewViewWithAConfigurationOfItsOwn() {
        let first = AppleTranslationHost(pair: "en→de", source: language("en-US"), target: language("de-DE"),
                                         strategy: .lowLatency)
        let second = AppleTranslationHost(pair: "en→de", source: language("en-US"), target: language("de-DE"),
                                          strategy: .lowLatency)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.configuration.source?.maximalIdentifier, language("en-US").maximalIdentifier)
        XCTAssertEqual(first.configuration.target?.maximalIdentifier, language("de-DE").maximalIdentifier)
        // a copy of a host hands the view the same configuration: its task is not started again
        let copy = first
        XCTAssertEqual(copy.id, first.id)
        XCTAssertEqual(copy.configuration, first.configuration)
    }

    /// The configuration names the kind of models: without it macOS would take .highFidelity
    func testTheConfigurationSaysWhichModelsTranslate() throws {
        guard #available(macOS 26.4, *) else { throw XCTSkip("one kind of models before macOS 26.4") }
        for strategy in [AppleTranslationStrategy.lowLatency, .highFidelity] {
            let host = AppleTranslationHost(pair: "en→da", source: language("en"), target: language("da"),
                                            strategy: strategy)
            XCTAssertEqual(host.strategy, strategy)
            XCTAssertEqual(host.configuration.preferredStrategy, strategy.framework)
        }
        XCTAssertEqual(AppleTranslationStrategy.lowLatency.framework, .lowLatency)
        XCTAssertEqual(AppleTranslationStrategy.highFidelity.framework, .highFidelity)
    }

    func testTheWindowForTheViewsIsNotToBeSeen() throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "no screen")
        // without hosts it holds no view that would ask for a session
        let window = AppleTranslationHostWindow.make(for: AppleTranslationEngine())
        defer { window.close() }
        XCTAssertFalse(window.isOpaque)
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertFalse(window.canBecomeKey)
        XCTAssertEqual(window.alphaValue, 0.02, accuracy: 0.001)
        XCTAssertTrue(window.contentView is PassthroughHostingView<AppleTranslationHostView>)
        // outside of every screen, except while macOS asks whether it may load languages
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(window.frame) })
        AppleTranslationHostWindow.place(window, onScreen: true)
        XCTAssertTrue(NSScreen.screens.contains { $0.frame.intersects(window.frame) })
        AppleTranslationHostWindow.place(window, onScreen: false)
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(window.frame) })
    }

    /// The question of macOS takes the level of the window it is attached to: while it may be up,
    /// the window lies above mirror windows that are kept on top (`.floating`)
    func testTheWindowIsAboveMirrorWindowsKeptOnTopWhileMacOSMayAsk() throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "no screen")
        let window = AppleTranslationHostWindow.make(for: AppleTranslationEngine())
        defer { window.close() }
        XCTAssertEqual(window.level, .normal)
        AppleTranslationHostWindow.raise(window, true)
        XCTAssertGreaterThan(window.level.rawValue, NSWindow.Level.floating.rawValue)
        AppleTranslationHostWindow.raise(window, false)
        XCTAssertEqual(window.level, .normal)
    }

    /// The engine raises its window for as long as a host waits for languages, and only then
    func testTheEngineRaisesItsWindowWhileLanguagesLoad() async throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "no screen")
        let macOS = FakeMacOS(supported: ["de", "en", "fr"])
        let engine = engine(answeredBy: macOS)
        // a window without the views, so that no session is asked for
        let window = NSWindow(contentRect: NSRect(x: -400, y: -400, width: 1, height: 1), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        engine.makeWindow = { _ in window }
        let client = AppleTranslationClient(engine: engine)
        let request = Task { try await client.translate([Self.english], into: self.language("de")) }
        try await waitUntil { engine.hosts.count == 1 }
        let host = engine.hosts[0]
        XCTAssertEqual(window.level, .normal)
        let served = Task { await engine.serve(host, prepare: { try await macOS.prepare(host) }, work: {}) }
        try await waitUntil { macOS.preparing.count == 1 }
        XCTAssertGreaterThan(window.level.rawValue, NSWindow.Level.floating.rawValue)
        macOS.finish(host, installing: true)
        await served.value
        XCTAssertEqual(window.level, .normal)
        _ = try await request.value
        client.cancel()
    }

    /// macOS's question is a sheet of the window. When a sheet ends, AppKit moves the window back
    /// to where it was when the sheet began. The window still goes back outside of the screens
    /// and down to the normal level: after a question closed by turning Translate off, and once
    /// the question is answered and the languages are on their way.
    func testTheWindowGoesBackOutsideTheScreensWhenTheQuestionEnds() async throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "no screen")
        for answered in [false, true] {
            let label = answered ? "answered" : "closed"
            let macOS = FakeMacOS(supported: ["de", "en"])
            let engine = engine(answeredBy: macOS)
            engine.loadingCheckInterval = 0.02
            // like the window of the views, but without them, so that no session is asked for
            let window = NSWindow(contentRect: NSRect(x: -400, y: -400, width: 1, height: 1), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0.02
            window.ignoresMouseEvents = true
            window.orderFrontRegardless()
            defer { window.close() }
            engine.makeWindow = { _ in window }
            func isOnAScreen() -> Bool { NSScreen.screens.contains { $0.frame.intersects(window.frame) } }
            let ended = Box(false)
            let observer = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification,
                                                                  object: window, queue: .main) { _ in
                MainActor.assumeIsolated { ended.value = true }
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            let client = AppleTranslationClient(engine: engine)
            let request = Task { try await client.translate([Self.english], into: self.language("de")) }
            try await waitUntil { engine.hosts.count == 1 }
            let host = engine.hosts[0]
            let served = Task { await engine.serve(host, prepare: { try await macOS.prepare(host) }, work: {}) }
            _ = try await request.value
            try await waitUntil { macOS.preparing.count == 1 }
            XCTAssertTrue(isOnAScreen(), label)
            XCTAssertGreaterThan(window.level.rawValue, NSWindow.Level.floating.rawValue, label)
            // the question of macOS
            let sheet = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                                backing: .buffered, defer: false)
            sheet.alphaValue = 0
            window.beginSheet(sheet) { _ in }
            try await waitUntil { window.attachedSheet === sheet }
            if answered {
                // the sheet goes, then prepareTranslation returns while the languages download
                window.endSheet(sheet)
                try await waitUntil { ended.value }
                macOS.finish(host, installing: false)
                try await waitUntil { !isOnAScreen() }
                XCTAssertEqual(window.level, .normal, label)
                macOS.installEverything()
                try await waitFor(served)
            } else {
                // turning Translate off takes the view away, which ends the sheet
                client.cancel()
                window.endSheet(sheet)
                try await waitUntil { ended.value }
                try await waitFor(served)
            }
            try await waitUntil { !isOnAScreen() }
            XCTAssertEqual(window.level, .normal, label)
            client.cancel()
            XCTAssertTrue(engine.hosts.isEmpty, label)
        }
    }

    // MARK: Loading languages (macOS answered by FakeMacOS: no session, no download)

    private static let english = "This is an ordinary English sentence about the weather today and tomorrow."
    private static let french = "Ceci est une phrase française tout à fait ordinaire sur le temps qu’il fait aujourd’hui."

    private func engine(answeredBy macOS: FakeMacOS) -> AppleTranslationEngine {
        let engine = AppleTranslationEngine()
        engine.availability = macOS.availability
        engine.makeWindow = { _ in nil }
        return engine
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("not within 10 s", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Waits for `task` to end, without hanging the tests should it never end
    private func waitFor(_ task: Task<Void, Never>?, file: StaticString = #filePath, line: UInt = #line) async throws {
        guard let task else { return }
        let done = Box<Bool>(false)
        Task { await task.value; done.value = true }
        try await waitUntil({ done.value }, file: file, line: line)
    }

    private static let german = "Das ist ein ganz gewöhnlicher deutscher Satz über das Wetter von heute und von morgen."
    private static let danish = "Dette er en helt almindelig dansk sætning om vejret i dag og i morgen eftermiddag."

    /// Some of the languages of the on-device models of macOS 26.4 and later, and those that
    /// only the models that need Apple Intelligence have
    private static let onDevice = ["de", "en", "en-GB", "es", "fr", "pt", "zh", "zh-TW"]
    private static let onlyWithAppleIntelligence = ["da", "de-CH", "en-IN", "es-MX", "pt-PT", "zh-HK"]

    /// The pair a request asks for, and with which models: the on-device ones wherever they know
    /// both languages. The language of the system gets their closest form, a language the user
    /// chose in the settings is taken as chosen.
    func testTheOnDeviceModelsTranslateEveryPairTheyKnow() async throws {
        let twoKinds = (onDevice: Self.onDevice, all: Self.onDevice + Self.onlyWithAppleIntelligence)
        let oneKind = (onDevice: twoKinds.all, all: twoKinds.all)
        let cases: [(lists: (onDevice: [String], all: [String]), wanted: String, chosen: Bool, text: String,
                     source: String, target: String, strategy: AppleTranslationStrategy)] = [
            // macOS 26.4 and later
            (twoKinds, "de-CH", false, Self.english, "en", "de", .lowLatency),
            (twoKinds, "de-CH", true, Self.english, "en", "de-CH", .highFidelity),
            (twoKinds, "de", true, Self.english, "en", "de", .lowLatency),
            (twoKinds, "es-AR", false, Self.english, "en", "es", .lowLatency),
            (twoKinds, "es-419", false, Self.english, "en", "es", .lowLatency),
            (twoKinds, "es-MX", true, Self.english, "en", "es-MX", .highFidelity),
            (twoKinds, "pt-PT", false, Self.english, "en", "pt", .lowLatency),
            (twoKinds, "pt-PT", true, Self.english, "en", "pt-PT", .highFidelity),
            (twoKinds, "zh-HK", false, Self.english, "en", "zh-TW", .lowLatency),
            (twoKinds, "en-DE", false, Self.german, "de", "en-GB", .lowLatency),
            (twoKinds, "en-IN", false, Self.german, "de", "en-GB", .lowLatency),
            (twoKinds, "en-IN", true, Self.german, "de", "en-IN", .highFidelity),
            // only the other models have the language: the target, or the language on the screen
            (twoKinds, "da", false, Self.english, "en", "da", .highFidelity),
            (twoKinds, "da", true, Self.english, "en", "da", .highFidelity),
            (twoKinds, "de", false, Self.danish, "da", "de", .highFidelity),
            // before macOS 26.4: one kind, one list, matched as before
            (oneKind, "pt-PT", false, Self.english, "en", "pt-PT", .lowLatency),
            (oneKind, "es-AR", false, Self.english, "en", "es-MX", .lowLatency),
            (oneKind, "en-DE", false, Self.german, "de", "en-GB", .lowLatency),
            (oneKind, "da", false, Self.english, "en", "da", .lowLatency),
            (oneKind, "de", false, Self.danish, "da", "de", .lowLatency),
        ]
        for entry in cases {
            let label = "\(entry.wanted) chosen: \(entry.chosen), \(entry.lists.onDevice.count) on the device"
            let macOS = FakeMacOS(onDevice: entry.lists.onDevice, all: entry.lists.all)
            let engine = engine(answeredBy: macOS)
            let client = AppleTranslationClient(engine: engine, targetIsChosen: entry.chosen)
            let request = Task { try await client.translate([entry.text], into: self.language(entry.wanted)) }
            try await waitUntil { engine.hosts.count == 1 }
            let host = engine.hosts[0]
            XCTAssertEqual(host.source.minimalIdentifier, entry.source, label)
            XCTAssertEqual(host.target.minimalIdentifier, entry.target, label)
            XCTAssertEqual(host.strategy, entry.strategy, label)
            // macOS is asked about the pair for the same models
            XCTAssertFalse(macOS.statusAsked.isEmpty, label)
            XCTAssertTrue(macOS.statusAsked.allSatisfy { $0.strategy == entry.strategy }, label)
            client.cancel()
            _ = try await request.value
            XCTAssertTrue(engine.hosts.isEmpty, label)
        }
    }

    /// The language of the system goes into a form whose pair with the language on the screen is
    /// on this Mac before the first form of the list: on a Mac set to English (Germany) with German
    /// and English (US) installed into English (US), not into British English, which macOS would
    /// have to download. A language chosen in the settings is taken as chosen.
    func testTheLanguageOfTheSystemTakesAFormThatIsOnThisMac() async throws {
        let cases: [(installed: [String], wanted: String, chosen: Bool, target: String)] = [
            (["en"], "en-DE", false, "en"),
            ([], "en-DE", false, "en-GB"),
            (["en", "en-GB"], "en-DE", false, "en-GB"),
            (["en-GB"], "en", false, "en-GB"),
            (["en"], "en-GB", true, "en-GB"),
            (["en"], "en-IN", false, "en"),
            // a language with one form only
            (["en"], "pt-PT", false, "pt"),
        ]
        for entry in cases {
            let label = "\(entry.wanted) chosen: \(entry.chosen), installed: \(entry.installed)"
            let macOS = FakeMacOS(onDevice: Self.onDevice, all: Self.onDevice + Self.onlyWithAppleIntelligence)
            for target in entry.installed { macOS.installPair("de", target) }
            let engine = engine(answeredBy: macOS)
            let client = AppleTranslationClient(engine: engine, targetIsChosen: entry.chosen)
            let request = Task { try await client.translate([Self.german], into: self.language(entry.wanted)) }
            try await waitUntil { engine.hosts.count == 1 }
            let host = engine.hosts[0]
            XCTAssertEqual(host.target.minimalIdentifier, entry.target, label)
            XCTAssertEqual(host.strategy, .lowLatency, label)
            // a chosen form asks about no other
            if entry.chosen { XCTAssertEqual(Set(macOS.targetsAsked), [entry.target], label) }
            client.cancel()
            _ = try await request.value
        }
    }

    /// A second language on the screen whose pair is not on this Mac yet goes into the form of the
    /// system language that is (English (US) next to German), so that macOS has to load only that
    /// language, not British English as well
    func testANewLanguageGoesIntoTheFormOfTheSystemLanguageThatIsOnThisMac() async throws {
        let macOS = FakeMacOS(onDevice: Self.onDevice, all: Self.onDevice + Self.onlyWithAppleIntelligence)
        macOS.installPair("de", "en")
        let engine = engine(answeredBy: macOS)
        engine.pickUpLimit = 0.2
        let client = AppleTranslationClient(engine: engine)
        _ = try await client.translate([Self.german], into: language("en-DE"))
        // the host of the French text stays until it is looked at
        engine.pickUpLimit = 20
        let request = Task { try await client.translate([Self.french], into: self.language("en-DE")) }
        try await waitUntil { engine.hosts.contains { $0.source.languageCode?.identifier == "fr" } }
        let host = try XCTUnwrap(engine.hosts.first { $0.source.languageCode?.identifier == "fr" })
        XCTAssertEqual(host.target.minimalIdentifier, "en")
        client.cancel()
        _ = try await request.value
    }

    /// The notices name the region where the models have another form of the language, as the
    /// question of macOS does: "English (United Kingdom)" next to English (US)
    func testTheNoticesNameTheRegionWhereTheLanguageAloneIsAmbiguous() async throws {
        let place = { (region: String) in
            Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en").localizedString(forRegionCode: region) ?? region
        }
        let cases: [(lists: (onDevice: [String], all: [String]), wanted: String, text: String,
                     source: String?, target: String?)] = [
            ((Self.onDevice, Self.onDevice + Self.onlyWithAppleIntelligence), "en-DE", Self.german, nil, "GB"),
            ((Self.onDevice, Self.onDevice + Self.onlyWithAppleIntelligence), "en", Self.german, nil, "US"),
            ((Self.onDevice, Self.onDevice + Self.onlyWithAppleIntelligence), "de", Self.english, "US", nil),
            ((Self.onDevice, Self.onDevice + Self.onlyWithAppleIntelligence), "de", Self.french, nil, nil),
            // one kind of models: Swiss German is listed next to German
            ((Self.onDevice + Self.onlyWithAppleIntelligence, Self.onDevice + Self.onlyWithAppleIntelligence), "en",
             Self.german, "DE", "US"),
        ]
        for entry in cases {
            let label = "\(entry.wanted) \(entry.text.prefix(10))"
            let macOS = FakeMacOS(onDevice: entry.lists.onDevice, all: entry.lists.all)
            let engine = engine(answeredBy: macOS)
            let client = AppleTranslationClient(engine: engine)
            let request = Task { try await client.translate([entry.text], into: self.language(entry.wanted)) }
            try await waitUntil { engine.hosts.count == 1 }
            let host = engine.hosts[0]
            let names = engine.noticeNames(for: host)
            let plain = (LanguageMatching.name(of: host.source, in: Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")),
                         LanguageMatching.name(of: host.target, in: Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")))
            XCTAssertEqual(names.source, entry.source.map { "\(plain.0) (\(place($0)))" } ?? plain.0, label)
            XCTAssertEqual(names.target, entry.target.map { "\(plain.1) (\(place($0)))" } ?? plain.1, label)
            XCTAssertTrue(engine.askingNotice(for: host).contains(names.target), label)
            XCTAssertTrue(engine.waitingNotice(for: host).contains(names.source), label)
            client.cancel()
            _ = try await request.value
        }
    }

    /// Without Apple Intelligence a pair that only its models know is not asked for: macOS would
    /// show "Apple Intelligence Required", and its calls would not return before the user closes
    /// that. A target that needs it ends the turn with a word; texts in a language that needs it
    /// stay as they are. Before macOS 26.4 there are no such pairs. The word says to turn Apple
    /// Intelligence on only where this Mac can run it.
    func testWithoutAppleIntelligenceItsModelsAreNotAskedFor() async throws {
        enum Outcome: Equatable {
            case host(target: String, strategy: AppleTranslationStrategy)
            case stopped
            case leftAsTheyAre
        }
        let twoKinds = (onDevice: Self.onDevice, all: Self.onDevice + Self.onlyWithAppleIntelligence)
        let oneKind = (onDevice: twoKinds.all, all: twoKinds.all)
        let cases: [(lists: (onDevice: [String], all: [String]), wanted: String, chosen: Bool, text: String,
                     outcome: Outcome)] = [
            (twoKinds, "da", false, Self.english, .stopped),
            (twoKinds, "da", true, Self.english, .stopped),
            (twoKinds, "pt-PT", true, Self.english, .stopped),
            (twoKinds, "en-IN", true, Self.german, .stopped),
            (twoKinds, "de-CH", true, Self.english, .stopped),
            // the language of the system in the form of the on-device models
            (twoKinds, "pt-PT", false, Self.english, .host(target: "pt", strategy: .lowLatency)),
            (twoKinds, "en-IN", false, Self.german, .host(target: "en-GB", strategy: .lowLatency)),
            (twoKinds, "de", true, Self.english, .host(target: "de", strategy: .lowLatency)),
            // Danish on the screen
            (twoKinds, "de", false, Self.danish, .leftAsTheyAre),
            // one kind of models
            (oneKind, "da", false, Self.english, .host(target: "da", strategy: .lowLatency)),
            (oneKind, "pt-PT", true, Self.english, .host(target: "pt-PT", strategy: .lowLatency)),
            (oneKind, "de", false, Self.danish, .host(target: "de", strategy: .lowLatency)),
        ]
        for (entry, state) in cases.flatMap({ entry in [AppleIntelligence.off, .notOnThisMac].map { (entry, $0) } }) {
            let label = "\(entry.wanted) chosen: \(entry.chosen), \(entry.lists.onDevice.count) on the device, \(state)"
            let macOS = FakeMacOS(onDevice: entry.lists.onDevice, all: entry.lists.all)
            macOS.appleIntelligence = state
            let engine = engine(answeredBy: macOS)
            let client = AppleTranslationClient(engine: engine, targetIsChosen: entry.chosen)
            let notices = Box<[String]>([])
            client.notify = { message in MainActor.assumeIsolated { notices.value.append(message) } }
            let request = Task { try await client.translate([entry.text], into: self.language(entry.wanted)) }
            switch entry.outcome {
            case .host(let target, let strategy):
                try await waitUntil { engine.hosts.count == 1 }
                XCTAssertEqual(engine.hosts[0].target.minimalIdentifier, target, label)
                XCTAssertEqual(engine.hosts[0].strategy, strategy, label)
                client.cancel()
                _ = try await request.value
            case .stopped:
                do {
                    _ = try await request.value
                    XCTFail("translated: \(label)")
                } catch let failure as TranslationFailure {
                    XCTAssertTrue(failure.isPermanent, label)
                    XCTAssertEqual(failure.message,
                                   AppleTranslationEngine.targetNeedsAppleIntelligenceNotice(language(entry.wanted), state),
                                   label)
                }
                XCTAssertTrue(macOS.statusAsked.isEmpty, label)
                client.cancel()
            case .leftAsTheyAre:
                let translations = try await request.value
                XCTAssertEqual(translations, [entry.text], label)
                XCTAssertEqual(notices.value, [AppleTranslationEngine.sourceNeedsAppleIntelligenceNotice(
                    language("da"), language(entry.wanted), state)], label)
                XCTAssertTrue(macOS.statusAsked.isEmpty, label)
                // once per turn: neither asked nor told again
                let again = try await client.translate([entry.text], into: language(entry.wanted))
                XCTAssertEqual(again, [entry.text], label)
                XCTAssertEqual(notices.value.count, 1, label)
                XCTAssertEqual(macOS.appleIntelligenceAsked, 1, label)
                client.cancel()
            }
            XCTAssertTrue(engine.hosts.isEmpty, label)
            XCTAssertTrue(macOS.asked.isEmpty, label)
            // only a pair that needs it asks whether Apple Intelligence is on
            XCTAssertEqual(macOS.appleIntelligenceAsked > 0, entry.outcome == .stopped || entry.outcome == .leftAsTheyAre,
                           label)
        }
    }

    /// A Mac that cannot run Apple Intelligence is not told to turn it on
    func testAMacWithoutAppleIntelligenceIsNotToldToTurnItOn() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("no Foundation Models before macOS 26") }
        XCTAssertEqual(AppleIntelligence(.available), .on)
        // its models are on their way: macOS says what is missing
        XCTAssertEqual(AppleIntelligence(.unavailable(.modelNotReady)), .on)
        XCTAssertEqual(AppleIntelligence(.unavailable(.appleIntelligenceNotEnabled)), .off)
        XCTAssertEqual(AppleIntelligence(.unavailable(.deviceNotEligible)), .notOnThisMac)
        let danish = language("da"), german = language("de")
        for notice in [{ AppleTranslationEngine.targetNeedsAppleIntelligenceNotice(danish, $0) },
                       { AppleTranslationEngine.sourceNeedsAppleIntelligenceNotice(danish, german, $0) }] {
            XCTAssertNotEqual(notice(.off), notice(.notOnThisMac))
            XCTAssertFalse(notice(.off).isEmpty)
            XCTAssertFalse(notice(.notOnThisMac).isEmpty)
        }
    }

    /// Turned on in the meantime: the next turn of translating asks again
    func testANewTurnAsksAgainWhetherAppleIntelligenceIsOn() async throws {
        let macOS = FakeMacOS(onDevice: Self.onDevice, all: Self.onDevice + Self.onlyWithAppleIntelligence)
        macOS.appleIntelligence = .off
        let engine = engine(answeredBy: macOS)
        let first = AppleTranslationClient(engine: engine)
        let unchanged = try await first.translate([Self.danish], into: language("de"))
        XCTAssertEqual(unchanged, [Self.danish])
        first.cancel()
        macOS.appleIntelligence = .on
        let second = AppleTranslationClient(engine: engine)
        let request = Task { try await second.translate([Self.danish], into: self.language("de")) }
        try await waitUntil { engine.hosts.count == 1 }
        XCTAssertEqual(engine.hosts[0].strategy, .highFidelity)
        XCTAssertEqual(macOS.appleIntelligenceAsked, 2)
        second.cancel()
        _ = try await request.value
    }

    /// Whether the language was chosen in the settings reaches the client
    func testTheClientKnowsWhetherTheLanguageWasChosen() throws {
        let settings = AppSettings.shared
        let before = (language: settings.translationLanguage, engine: settings.translationEngine)
        defer {
            settings.translationLanguage = before.language
            settings.translationEngine = before.engine
        }
        settings.translationEngine = "apple"
        for (language, chosen) in [("system", false), ("pt-PT", true), ("da", true)] {
            settings.translationLanguage = language
            let client = try XCTUnwrap(try TranslationEngines.make(for: settings) as? AppleTranslationClient)
            XCTAssertEqual(client.targetIsChosen, chosen, language)
            client.cancel()
        }
    }

    /// Two pairs whose languages are missing: macOS shows one question at a time, and a
    /// second prepareTranslation that starts meanwhile returns at once without loading anything.
    /// So the second pair is asked for only after the first.
    func testMacOSIsAskedToLoadOnePairAtATime() async throws {
        let macOS = FakeMacOS(supported: ["de", "en", "fr"])
        let engine = engine(answeredBy: macOS)
        let client = AppleTranslationClient(engine: engine)
        let request = Task { try await client.translate([Self.english, Self.french], into: self.language("de")) }
        try await waitUntil { engine.hosts.count == 2 }
        let hosts = engine.hosts
        // both views start in the same turn
        var served: [Task<Void, Never>] = []
        for host in hosts {
            served.append(Task { await engine.serve(host, prepare: { try await macOS.prepare(host) }, work: {}) })
        }
        // while the languages load, the texts are "not now"
        let first = try await request.value
        XCTAssertEqual(first, [nil, nil])
        try await waitUntil { macOS.preparing.count == 2 || engine.hostsWaitingToLoad == 1 }
        XCTAssertEqual(macOS.preparing.count, 1)
        let asked = try XCTUnwrap(macOS.preparing.first)
        macOS.finish(asked, installing: true)
        try await waitUntil { macOS.asked.count == 2 }
        XCTAssertNotEqual(macOS.asked[0], macOS.asked[1])
        XCTAssertEqual(Set(macOS.asked), Set(hosts.map(\.id)))
        let second = try XCTUnwrap(macOS.preparing.first)
        macOS.finish(second, installing: true)
        for task in served { await task.value }
        XCTAssertTrue(engine.hosts.isEmpty)
        XCTAssertEqual(engine.hostsWaitingToLoad, 0)
        client.cancel()
    }

    /// The turn is for the question only: once the user has answered it, the next pair is asked
    /// for while the languages of the first are still on their way (or never come)
    func testTheNextPairIsAskedForWhileTheFirstOneDownloads() async throws {
        let macOS = FakeMacOS(supported: ["de", "en", "fr"])
        let engine = engine(answeredBy: macOS)
        let client = AppleTranslationClient(engine: engine)
        let request = Task { try await client.translate([Self.english, Self.french], into: self.language("de")) }
        try await waitUntil { engine.hosts.count == 2 }
        var served: [Task<Void, Never>] = []
        for host in engine.hosts {
            served.append(Task { await engine.serve(host, prepare: { try await macOS.prepare(host) }, work: {}) })
        }
        _ = try await request.value
        try await waitUntil { engine.hostsWaitingToLoad == 1 }
        let first = try XCTUnwrap(macOS.preparing.first)
        // prepareTranslation returns, the languages are not there yet: the first pair keeps waiting
        macOS.finish(first, installing: false)
        try await waitUntil { macOS.asked.count == 2 }
        XCTAssertEqual(engine.hostsWaitingToLoad, 0)
        XCTAssertTrue(engine.hosts.contains { $0.id == first })
        let second = try XCTUnwrap(macOS.preparing.first)
        XCTAssertNotEqual(second, first)
        client.cancel()
        macOS.finish(second, installing: false)
        for task in served { await task.value }
        XCTAssertTrue(engine.hosts.isEmpty)
    }

    /// The languages the first pair loaded may be all the second one needed: it is not asked for
    func testAPairWhoseLanguagesCameMeanwhileIsNotAskedFor() async throws {
        let macOS = FakeMacOS(supported: ["de", "en", "fr"])
        let engine = engine(answeredBy: macOS)
        let client = AppleTranslationClient(engine: engine)
        let request = Task { try await client.translate([Self.english, Self.french], into: self.language("de")) }
        try await waitUntil { engine.hosts.count == 2 }
        let worked = Box<[UUID]>([])
        var served: [Task<Void, Never>] = []
        for host in engine.hosts {
            served.append(Task {
                await engine.serve(host, prepare: { try await macOS.prepare(host) }, work: { worked.value.append(host.id) })
            })
        }
        _ = try await request.value
        try await waitUntil { engine.hostsWaitingToLoad == 1 }
        let asked = try XCTUnwrap(macOS.preparing.first)
        macOS.installEverything()
        macOS.finish(asked, installing: true)
        for task in served { await task.value }
        XCTAssertEqual(macOS.asked, [asked])
        XCTAssertEqual(worked.value.count, 2)
        client.cancel()
    }

    /// Translating turned off while one pair is asked for and another waits for its turn: the one
    /// that waits ends without asking, and the question that is up closes with its view. Its
    /// call does not return then (macOS never answers it): the host does not wait for it.
    func testTurningTranslatingOffClosesTheQuestionAndEndsTheHostsThatWait() async throws {
        let macOS = FakeMacOS(supported: ["de", "en", "fr"])
        let engine = engine(answeredBy: macOS)
        let client = AppleTranslationClient(engine: engine)
        let request = Task { try await client.translate([Self.english, Self.french], into: self.language("de")) }
        try await waitUntil { engine.hosts.count == 2 }
        var served: [Task<Void, Never>] = []
        for host in engine.hosts {
            served.append(Task { await engine.serve(host, prepare: { try await macOS.prepare(host) }, work: {}) })
        }
        _ = try await request.value
        try await waitUntil { engine.hostsWaitingToLoad == 1 }
        let asked = try XCTUnwrap(macOS.preparing.first)
        client.cancel()
        // the view that asked is gone at once, which closes the question
        XCTAssertFalse(engine.hosts.contains { $0.id == asked })
        for task in served { try await waitFor(task) }
        XCTAssertTrue(engine.hosts.isEmpty)
        XCTAssertEqual(engine.hostsWaitingToLoad, 0)
        XCTAssertEqual(macOS.asked, [asked])
        // what macOS does with the call afterwards changes nothing
        XCTAssertEqual(macOS.preparing, [asked])
        macOS.finish(asked, installing: true)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(engine.hosts.isEmpty)
    }

    /// The question closes when nobody wants the pair any more, and the window of the views goes
    /// back to its place outside of the screens. Turned on again, the pair is asked for anew at
    /// once: the call of the closed question, which never returns, does not hold it up.
    func testTheQuestionClosesWhenTranslatingIsTurnedOffAndComesBackWhenItIsTurnedOn() async throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "no screen")
        let macOS = FakeMacOS(supported: ["de", "en"])
        let engine = engine(answeredBy: macOS)
        engine.pickUpLimit = 3
        let window = NSWindow(contentRect: NSRect(x: -400, y: -400, width: 1, height: 1), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        engine.makeWindow = { _ in window }
        func isOnAScreen() -> Bool { NSScreen.screens.contains { $0.frame.intersects(window.frame) } }

        var served: [Task<Void, Never>] = []
        var askedFor: [UUID] = []
        for round in 1...3 {
            let label = "round \(round)"
            let client = AppleTranslationClient(engine: engine)
            let request = Task { try await client.translate([Self.english], into: self.language("de")) }
            try await waitUntil { engine.hosts.count == 1 }
            let host = engine.hosts[0]
            XCTAssertFalse(askedFor.contains(host.id), label)
            served.append(Task { await engine.serve(host, prepare: { try await macOS.prepare(host) }, work: {}) })
            _ = try await request.value
            try await waitUntil { macOS.asked.count == round }
            askedFor.append(host.id)
            XCTAssertTrue(isOnAScreen(), label)
            XCTAssertGreaterThan(window.level.rawValue, NSWindow.Level.floating.rawValue, label)

            client.cancel()
            XCTAssertTrue(engine.hosts.isEmpty, label)
            try await waitFor(served.last)
            XCTAssertFalse(isOnAScreen(), label)
            XCTAssertEqual(window.level, .normal, label)
        }
        // every question was a new one; none of them was answered
        XCTAssertEqual(macOS.asked, askedFor)
        XCTAssertEqual(macOS.preparing, askedFor)
        for id in askedFor { macOS.finish(id, installing: false) }
    }

    /// Another window that still translates into the same pair keeps the question
    func testTheQuestionStaysWhileAnotherWindowWantsThePair() async throws {
        let macOS = FakeMacOS(supported: ["de", "en", "fr"])
        let engine = engine(answeredBy: macOS)
        engine.pickUpLimit = 3
        let first = AppleTranslationClient(engine: engine)
        let request = Task { try await first.translate([Self.english], into: self.language("de")) }
        try await waitUntil { engine.hosts.count == 1 }
        let host = engine.hosts[0]
        let served = Task { await engine.serve(host, prepare: { try await macOS.prepare(host) }, work: {}) }
        _ = try await request.value
        try await waitUntil { macOS.preparing.count == 1 }
        let second = AppleTranslationClient(engine: engine)
        // asks during the question: "not now", and no second question
        let again = try await second.translate([Self.english], into: language("de"))
        XCTAssertEqual(again, [nil])
        first.cancel()
        XCTAssertEqual(engine.hosts.map(\.id), [host.id])
        // a window that translates other languages does not keep it
        let third = AppleTranslationClient(engine: engine)
        let other = Task { try await third.translate([Self.french], into: self.language("de")) }
        try await waitUntil { engine.hosts.count == 2 }
        second.cancel()
        XCTAssertFalse(engine.hosts.contains { $0.id == host.id })
        try await waitFor(served)
        third.cancel()
        _ = try await other.value
        XCTAssertTrue(engine.hosts.isEmpty)
        macOS.finish(host, installing: false)
    }

    /// What the host of a pair may be doing when the last window that wants the pair turns
    /// Translate off
    private enum HostState: CaseIterable {
        case viewNotStarted, waitingForItsTurn, betweenItsTurnAndAsking, asking, downloading, serving
    }

    /// The last window that wants a pair turns Translate off while another window still
    /// translates other languages: whatever the pair's host is doing, it ends, and macOS does not
    /// ask about the pair afterwards. The other window's host is left alone.
    func testAHostWhosePairNobodyWantsAnyMoreEndsWhateverItIsDoing() async throws {
        for state in HostState.allCases {
            do {
                try await endHostNobodyWants(in: state)
            } catch {
                // `waitUntil` has said what did not happen; the next state is tried all the same
                XCTFail("while the host is \(state)")
            }
        }
    }

    private func endHostNobodyWants(in state: HostState) async throws {
        let label = "\(state)"
        let macOS = FakeMacOS(supported: ["de", "en", "fr"])
        if state == .serving { macOS.install("fr") }
        let engine = engine(answeredBy: macOS)
        engine.loadingCheckInterval = 0.02
        // the window that goes on translating; macOS asks about its pair
        let first = AppleTranslationClient(engine: engine)
        let firstRequest = Task { try await first.translate([Self.english], into: self.language("de")) }
        try await waitUntil { engine.hosts.count == 1 }
        let english = engine.hosts[0]
        let servedEnglish = Task {
            await engine.serve(english, prepare: { try await macOS.prepare(english) }, work: {})
        }
        _ = try await firstRequest.value
        try await waitUntil { macOS.preparing == [english.id] }

        // the window that turns Translate off
        let second = AppleTranslationClient(engine: engine)
        let statuses = Box<[String?]>([])
        second.notifyStatus = { status in MainActor.assumeIsolated { statuses.value.append(status) } }
        let secondRequest = Task { try await second.translate([Self.french], into: self.language("de")) }
        try await waitUntil { engine.hosts.count == 2 }
        let french = try XCTUnwrap(engine.hosts.first { $0.id != english.id }, label)
        let working = Box(false)
        func serveFrench() -> Task<Void, Never> {
            Task {
                await engine.serve(french, prepare: { try await macOS.prepare(french) }, work: {
                    working.value = true
                    while engine.takesJobs(french) { try? await Task.sleep(nanoseconds: 10_000_000) }
                })
            }
        }
        var servedFrench: Task<Void, Never>?
        switch state {
        case .viewNotStarted:
            break
        case .waitingForItsTurn:
            servedFrench = serveFrench()
            try await waitUntil { engine.hostsWaitingToLoad == 1 }
        case .betweenItsTurnAndAsking:
            servedFrench = serveFrench()
            try await waitUntil { engine.hostsWaitingToLoad == 1 }
            // its turn comes with the answer to the question before; then it looks at the pair again
            macOS.holdStatus(of: "fr")
            macOS.finish(english, installing: false)
            try await waitUntil { macOS.isHoldingStatus }
        case .asking, .downloading:
            servedFrench = serveFrench()
            try await waitUntil { engine.hostsWaitingToLoad == 1 }
            macOS.finish(english, installing: false)
            try await waitUntil { macOS.preparing == [french.id] }
            if state == .downloading {
                macOS.finish(french, installing: false)
                let downloading = engine.waitingNotice(for: french)
                try await waitUntil { statuses.value.last == downloading }
            }
        case .serving:
            servedFrench = serveFrench()
            try await waitUntil { working.value }
        }

        second.cancel()
        XCTAssertEqual(engine.hostsWaitingToLoad, 0, label)
        XCTAssertTrue(engine.hosts.contains { $0.id == english.id }, label)
        let answer = try await secondRequest.value
        XCTAssertEqual(answer, [nil], label)
        // what happens afterwards brings up no question about French: the question before is
        // answered, macOS says what it has, a view that had not started starts now
        macOS.finish(english, installing: false)
        macOS.releaseStatus()
        if state == .viewNotStarted { servedFrench = serveFrench() }
        try await waitFor(servedFrench)
        XCTAssertFalse(engine.hosts.contains { $0.id == french.id }, label)
        let askedAboutFrench = state == .asking || state == .downloading ? 1 : 0
        XCTAssertEqual(macOS.asked.filter { $0 == french.id }.count, askedAboutFrench, label)
        XCTAssertEqual(working.value, state == .serving, label)
        XCTAssertTrue(engine.hosts.contains { $0.id == english.id }, label)

        first.cancel()
        try await waitFor(servedEnglish)
        XCTAssertTrue(engine.hosts.isEmpty, label)
        XCTAssertEqual(engine.hostsWaitingToLoad, 0, label)
        for id in macOS.preparing { macOS.finish(id, installing: false) }
    }

    /// For as long as macOS asks, the turn is told so, and that nothing is loaded before the user
    /// answers; once the answer lets the languages come, that they are on their way; once they are
    /// there, nothing. A turn that asks only while the question is up is told the same.
    func testTheTurnIsToldForAsLongAsMacOSAsksAndTheLanguagesLoad() async throws {
        let macOS = FakeMacOS(supported: ["de", "en"])
        let engine = engine(answeredBy: macOS)
        engine.pickUpLimit = 3
        let first = AppleTranslationClient(engine: engine)
        let notices = Box<[String]>([])
        let statuses = Box<[String?]>([])
        first.notify = { message in MainActor.assumeIsolated { notices.value.append(message) } }
        first.notifyStatus = { status in MainActor.assumeIsolated { statuses.value.append(status) } }
        let request = Task { try await first.translate([Self.english], into: self.language("de")) }
        try await waitUntil { engine.hosts.count == 1 }
        let host = engine.hosts[0]
        let asking = engine.askingNotice(for: host)
        let downloading = engine.waitingNotice(for: host)
        XCTAssertNotEqual(asking, downloading)
        let served = Task { await engine.serve(host, prepare: { try await macOS.prepare(host) }, work: {}) }
        _ = try await request.value
        try await waitUntil { macOS.preparing.count == 1 }
        XCTAssertEqual(statuses.value, [asking])

        let second = AppleTranslationClient(engine: engine)
        let secondStatuses = Box<[String?]>([])
        second.notifyStatus = { status in MainActor.assumeIsolated { secondStatuses.value.append(status) } }
        let again = try await second.translate([Self.english], into: language("de"))
        XCTAssertEqual(again, [nil])
        XCTAssertEqual(secondStatuses.value, [asking])
        // asked again meanwhile: nothing new to say
        _ = try await first.translate([Self.english], into: language("de"))
        XCTAssertEqual(statuses.value, [asking])

        macOS.finish(host, installing: false)
        try await waitUntil { statuses.value.count == 2 }
        XCTAssertEqual(statuses.value, [asking, downloading])
        XCTAssertEqual(secondStatuses.value, [asking, downloading])
        macOS.installEverything()
        try await waitUntil { statuses.value.count == 3 }
        XCTAssertEqual(statuses.value, [asking, downloading, nil])
        XCTAssertEqual(secondStatuses.value, [asking, downloading, nil])
        // all of it said lastingly, none of it as a passing notice
        XCTAssertEqual(notices.value, [])
        first.cancel()
        second.cancel()
        try await waitFor(served)
    }

    /// The user does not let macOS load the languages: the lasting notice goes, and a passing one
    /// says what to do
    func testADeclinedQuestionEndsTheLastingNotice() async throws {
        let macOS = FakeMacOS(supported: ["de", "en"])
        let engine = engine(answeredBy: macOS)
        let client = AppleTranslationClient(engine: engine)
        let notices = Box<[String]>([])
        let statuses = Box<[String?]>([])
        client.notify = { message in MainActor.assumeIsolated { notices.value.append(message) } }
        client.notifyStatus = { status in MainActor.assumeIsolated { statuses.value.append(status) } }
        let request = Task { try await client.translate([Self.english], into: self.language("de")) }
        try await waitUntil { engine.hosts.count == 1 }
        let host = engine.hosts[0]
        let served = Task { await engine.serve(host, prepare: { try await macOS.prepare(host) }, work: {}) }
        _ = try await request.value
        try await waitUntil { macOS.preparing.count == 1 }
        macOS.decline(host.id)
        try await waitFor(served)
        XCTAssertEqual(statuses.value, [engine.askingNotice(for: host), nil])
        XCTAssertEqual(notices.value.count, 1)
        client.cancel()
    }

    /// The user closes the question of macOS with "Done" without downloading: prepareTranslation
    /// returns as it does after a download, and macOS says "supported" as it does during one. So
    /// no notice claims a download: first that translating starts once the languages are there,
    /// after `downloadPatience` what to do if they were not downloaded, while the engine keeps
    /// looking for them without asking again. After `loadingLimit` the pair counts as declined.
    func testAQuestionClosedWithoutDownloadingSaysWhatToDo() async throws {
        let macOS = FakeMacOS(supported: ["de", "en"])
        let engine = engine(answeredBy: macOS)
        engine.loadingCheckInterval = 0.02
        engine.downloadPatience = 0.3
        engine.loadingLimit = 1.5
        let client = AppleTranslationClient(engine: engine)
        let notices = Box<[String]>([])
        let statuses = Box<[String?]>([])
        client.notify = { message in MainActor.assumeIsolated { notices.value.append(message) } }
        client.notifyStatus = { status in MainActor.assumeIsolated { statuses.value.append(status) } }
        let request = Task { try await client.translate([Self.english], into: self.language("de")) }
        try await waitUntil { engine.hosts.count == 1 }
        let host = engine.hosts[0]
        let worked = Box(false)
        let served = Task {
            await engine.serve(host, prepare: { try await macOS.prepare(host) }, work: { worked.value = true })
        }
        _ = try await request.value
        try await waitUntil { macOS.preparing.count == 1 }
        let asking = engine.askingNotice(for: host)
        let waiting = engine.waitingNotice(for: host)
        let missing = engine.missingNotice(for: host)
        XCTAssertEqual(Set([asking, waiting, missing]).count, 3)
        // "Done": nothing is downloaded
        macOS.finish(host, installing: false)
        try await waitUntil { statuses.value.count == 3 }
        XCTAssertEqual(statuses.value, [asking, waiting, missing])
        XCTAssertEqual(notices.value, [])
        // it keeps looking, and asks nothing
        let looked = macOS.statusAsked.count
        try await waitUntil { macOS.statusAsked.count > looked + 2 }
        XCTAssertEqual(macOS.asked, [host.id])
        try await waitFor(served)
        XCTAssertFalse(worked.value)
        XCTAssertEqual(statuses.value, [asking, waiting, missing, nil])
        XCTAssertEqual(notices.value.count, 1)
        // not asked for again in this turn of translating
        let again = try await client.translate([Self.english], into: language("de"))
        XCTAssertEqual(again, [nil])
        XCTAssertTrue(engine.hosts.isEmpty)
        XCTAssertEqual(macOS.asked, [host.id])
        client.cancel()
    }

    /// A download that takes longer than `downloadPatience`: the notice says what to do if the
    /// languages were not downloaded, and goes once they are there; then they translate
    func testLanguagesThatComeLaterAreStillUsed() async throws {
        let macOS = FakeMacOS(supported: ["de", "en"])
        let engine = engine(answeredBy: macOS)
        engine.loadingCheckInterval = 0.02
        engine.downloadPatience = 0.3
        let client = AppleTranslationClient(engine: engine)
        let notices = Box<[String]>([])
        let statuses = Box<[String?]>([])
        client.notify = { message in MainActor.assumeIsolated { notices.value.append(message) } }
        client.notifyStatus = { status in MainActor.assumeIsolated { statuses.value.append(status) } }
        let request = Task { try await client.translate([Self.english], into: self.language("de")) }
        try await waitUntil { engine.hosts.count == 1 }
        let host = engine.hosts[0]
        let worked = Box(false)
        let served = Task {
            await engine.serve(host, prepare: { try await macOS.prepare(host) }, work: { worked.value = true })
        }
        _ = try await request.value
        try await waitUntil { macOS.preparing.count == 1 }
        macOS.finish(host, installing: false)
        try await waitUntil { statuses.value.count == 3 }
        XCTAssertEqual(statuses.value.last, engine.missingNotice(for: host))
        macOS.installEverything()
        try await waitFor(served)
        XCTAssertTrue(worked.value)
        XCTAssertEqual(statuses.value, [engine.askingNotice(for: host), engine.waitingNotice(for: host),
                                        engine.missingNotice(for: host), nil])
        XCTAssertEqual(notices.value, [])
        client.cancel()
    }

    /// Two windows translate the same pair, and the question was closed without downloading:
    /// turning translating off and on in one of them asks again, as the notice says, although the
    /// other window still wants the pair
    func testTurningTranslatingOnAgainAsksAgainWhileAnotherWindowWaitsForTheLanguages() async throws {
        let macOS = FakeMacOS(supported: ["de", "en"])
        let engine = engine(answeredBy: macOS)
        engine.loadingCheckInterval = 0.02
        engine.downloadPatience = 0.1
        let first = AppleTranslationClient(engine: engine)
        let other = AppleTranslationClient(engine: engine)
        let statuses = Box<[ObjectIdentifier: String?]>([:])
        for client in [first, other] {
            let key = ObjectIdentifier(client)
            client.notifyStatus = { status in MainActor.assumeIsolated { statuses.value[key] = status } }
        }
        let request = Task { try await first.translate([Self.english], into: self.language("de")) }
        try await waitUntil { engine.hosts.count == 1 }
        let host = engine.hosts[0]
        let served = Task { await engine.serve(host, prepare: { try await macOS.prepare(host) }, work: {}) }
        _ = try await request.value
        try await waitUntil { macOS.preparing.count == 1 }
        // the other window asks during the question: "not now"
        let waiting = try await other.translate([Self.english], into: language("de"))
        XCTAssertEqual(waiting, [nil])
        // "Done" without downloading; both are told what to do
        macOS.finish(host, installing: false)
        let missing = engine.missingNotice(for: host)
        try await waitUntil {
            [first, other].allSatisfy { (statuses.value[ObjectIdentifier($0)] ?? nil) == missing }
        }
        // off and on again in the first window
        first.cancel()
        let again = AppleTranslationClient(engine: engine)
        let asked = Task { try await again.translate([Self.english], into: self.language("de")) }
        try await waitUntil { engine.hosts.contains { $0.id != host.id } }
        let next = try XCTUnwrap(engine.hosts.first { $0.id != host.id })
        let servedNext = Task { await engine.serve(next, prepare: { try await macOS.prepare(next) }, work: {}) }
        try await waitUntil { macOS.asked == [host.id, next.id] }
        // the host before goes
        try await waitFor(served)
        XCTAssertFalse(engine.hosts.contains { $0.id == host.id })
        other.cancel()
        again.cancel()
        _ = try await asked.value
        try await waitFor(servedNext)
        XCTAssertTrue(engine.hosts.isEmpty)
        macOS.finish(next, installing: false)
    }

    // MARK: Languages of the texts (the language recognizer of macOS; needs no download)

    func testTheLanguageOfWholeSentencesIsDecided() {
        let found = languages(of: [
            "Das ist ein ganz gewöhnlicher deutscher Satz über das Wetter von heute und von morgen.",
            "This is an ordinary English sentence about the weather today.",
            "OK",
        ])
        XCTAssertEqual(found.findings.count, 3)
        XCTAssertEqual(found.findings[0].decided?.languageCode?.identifier, "de")
        XCTAssertEqual(found.findings[1].decided?.languageCode?.identifier, "en")
        // too short to tell
        XCTAssertNil(found.findings[2].decided)
        XCTAssertEqual(found.findings[2].letters, 2)
        // most of the text is German
        XCTAssertEqual(found.screen?.language.languageCode?.identifier, "de")
    }

    func testTextsAreSortedByTheirLanguage() {
        let texts = [
            "This is an ordinary English sentence about the weather today.",
            "Das ist ein ganz gewöhnlicher deutscher Satz über das Wetter von heute und von morgen.",
            "OK",
            "Ceci est une phrase française tout à fait ordinaire sur le temps qu’il fait aujourd’hui.",
            "12:30",
        ]
        let found = languages(of: texts)
        let plan = LanguageMatching.Plan(findings: found.findings,
                                         screen: LanguageMatching.ScreenLanguage(language: language("en"), letters: 100),
                                         target: language("de-DE"), supported: supported)
        XCTAssertEqual(plan.groups.map(\.indices), [[0, 2], [3]])
        XCTAssertEqual(plan.groups.map { $0.source.languageCode?.identifier }, ["en", "fr"])
        XCTAssertEqual(plan.unchanged, [1, 4])
        XCTAssertEqual(plan.postponed, [])
        XCTAssertEqual(plan.results(for: texts), [nil, texts[1], nil, nil, "12:30"])
    }

    func testATextInALanguageMacOSDoesNotTranslateStaysAsItIs() {
        let finnish = "Tämä on aivan tavallinen suomenkielinen lause tämän päivän säästä ja huomisesta."
        let found = languages(of: [finnish])
        XCTAssertEqual(found.findings.first?.decided?.languageCode?.identifier, "fi")
        let plan = LanguageMatching.Plan(findings: found.findings, screen: found.screen, target: language("de-DE"),
                                         supported: supported)
        XCTAssertEqual(plan.unchanged, [0])
        XCTAssertTrue(plan.groups.isEmpty)
        XCTAssertEqual(plan.unknown.map { $0.languageCode?.identifier }, ["fi"])
    }

    func testShortLabelsAreReadTogether() {
        // none is long enough on its own
        let labels = ["Allgemein", "Datenschutz", "Abbrechen", "Speichern", "Löschen", "Hinzufügen", "Nachrichten",
                      "Einladung"]
        let found = languages(of: labels)
        XCTAssertTrue(found.findings.allSatisfy { $0.decided == nil })
        XCTAssertEqual(found.screen?.language.languageCode?.identifier, "de")
    }

    /// Japanese and Chinese set no spaces between words: a date, a number or a brand name in a
    /// sentence must not take the whole sentence with it
    func testSentencesWithoutSpacesKeepTheirLanguageAroundNumbersAndNames() {
        let japanese = ["2025年11月13日のお知らせ", "新しいメッセージが3件あります。確認してください。",
                        "iPhoneを最新のバージョンにアップデートしてください。", "YouTubeで動画を見る"]
        let screen = languages(of: japanese)
        XCTAssertEqual(screen.findings.map { $0.decided?.languageCode?.identifier }, ["ja", "ja", "ja", "ja"])
        XCTAssertEqual(screen.screen?.language.languageCode?.identifier, "ja")
        let plan = LanguageMatching.Plan(findings: screen.findings, screen: screen.screen, target: language("en"),
                                         supported: supported)
        XCTAssertEqual(plan.groups.map(\.indices), [[0, 1, 2, 3]])
        XCTAssertEqual(plan.groups.map(\.mayAskForTheLanguage), [true])
        // a Japanese paragraph with a number on a German page keeps its language
        let page = languages(of: ["Heute kochen wir eine einfache Gemüsesuppe, die schnell fertig ist und allen schmeckt.",
                                  "この料理は30分で作れます。野菜をたくさん使った、体にやさしいスープです。",
                                  "请将iPhone更新到最新版本以获得更好的体验，这样可以使用所有的新功能。"])
        XCTAssertEqual(page.findings.map { $0.decided?.languageCode?.identifier }, ["de", "ja", "zh"])
        XCTAssertTrue(page.findings.allSatisfy(\.standsApart))
    }

    /// Android's About phone and its Modell page, as Vision read them. The recognizer takes the
    /// model name for Indonesian and "Telefonnummer" for Norwegian; neither is a language of the
    /// screen, and macOS is asked about neither (no download question, no word about Apple
    /// Intelligence). Everything goes with German. The Modell page comes as a request of its
    /// own, and stays German as well.
    func testNamesAndSingleWordsAskForNoLanguage() async throws {
        let about = ["Über emuliertes Gerät", "Allgemeine Informationen", "Geratename", "sdk_gphone64_arm64",
                     "Telefonnummer", "Rechtliche Informationen", "Rechtliche Hinweise", "Gerätedetails",
                     "Status der SIM-Karte", "T-Mobile", "Modell", "sdk_gphone64_arm64", "IMEI", "Android-Version 16"]
        let modell = ["Modell", "Modell", "sdk_gphone64_arm64", "Seriennummer", "EMULATOR37X1X11X0"]
        let macOS = FakeMacOS(onDevice: Self.onDevice + ["id"], all: Self.onDevice + ["id", "nb"])
        macOS.appleIntelligence = .off
        let engine = engine(answeredBy: macOS)
        // no session is served: the jobs are given up soon
        engine.pickUpLimit = 0.2
        let client = AppleTranslationClient(engine: engine)
        let notices = Box<[String]>([])
        client.notify = { message in MainActor.assumeIsolated { notices.value.append(message) } }
        for texts in [about, modell] {
            let translations = try await client.translate(texts, into: language("en"))
            XCTAssertEqual(translations.count, texts.count)
        }
        XCTAssertEqual(Set(macOS.statusAsked.map(\.source)), ["de"])
        XCTAssertEqual(macOS.appleIntelligenceAsked, 0)
        XCTAssertTrue(macOS.asked.isEmpty)
        XCTAssertFalse(notices.value.contains { $0.contains("Apple Intelligence") || $0.contains("Indonesian") }, "\(notices.value)")
        client.cancel()
    }

    /// Turned on over a page of single words (Android's Modell page): nothing decides a language,
    /// and the words are translated from the likeliest one where its pair is on this Mac, without
    /// a question; where it is not, they wait, and macOS is not asked either
    func testSingleWordsAloneUseAPairThatIsOnThisMac() async throws {
        let modell = ["Modell", "Modell", "sdk_gphone64_arm64", "Seriennummer", "EMULATOR37X1X11X0"]
        for installed in [true, false] {
            let macOS = FakeMacOS(supported: ["de", "en", "nb", "sv"])
            if installed { macOS.install("de") }
            let engine = engine(answeredBy: macOS)
            engine.pickUpLimit = 0.2
            let client = AppleTranslationClient(engine: engine)
            let request = Task { try await client.translate(modell, into: self.language("en")) }
            if installed {
                try await waitUntil { engine.hosts.count == 1 }
                XCTAssertEqual(engine.hosts[0].source.languageCode?.identifier, "de")
            }
            _ = try await request.value
            XCTAssertEqual(Set(macOS.statusAsked.map(\.source)), ["de"], "installed: \(installed)")
            XCTAssertTrue(macOS.asked.isEmpty)
            if !installed { XCTAssertTrue(engine.hosts.isEmpty) }
            client.cancel()
        }
    }

    /// Translate goes on while only "Apps" can be read, and the German labels come in the next
    /// frames: none of them comes back as it is (which the caller would keep for good), whatever
    /// the first word was taken for
    func testAGuessOnTheFirstFrameLeavesNoTextAsItIs() async throws {
        let macOS = FakeMacOS(supported: ["de", "en"])
        macOS.install("de")
        let engine = engine(answeredBy: macOS)
        // no session is served: the jobs are given up soon
        engine.pickUpLimit = 0.2
        let client = AppleTranslationClient(engine: engine)
        let requests = [["Apps"], ["Apps", "Verbundene Geräte", "Akku"], ["Dunkles Design", "Helligkeit"]]
        let german: Set<String> = ["Verbundene Geräte", "Akku", "Dunkles Design", "Helligkeit"]
        for texts in requests {
            let translations = try await client.translate(texts, into: language("en"))
            for (text, translation) in zip(texts, translations) where german.contains(text) {
                XCTAssertNil(translation, text)
            }
        }
        // they were meant for the German pair
        XCTAssertEqual(Set(macOS.statusAsked.map(\.source)), ["de"])
        client.cancel()
    }

    /// A paragraph in another language keeps its own pair, and a screen in that language may
    /// have it loaded; a single word of it may not
    func testOnlyEnoughTextAsksForALanguageThatIsNotOnThisMac() async throws {
        let macOS = FakeMacOS(supported: ["de", "en", "fr"])
        macOS.install("de")
        let engine = engine(answeredBy: macOS)
        engine.pickUpLimit = 0.2
        let client = AppleTranslationClient(engine: engine)
        // German labels, and a French word the recognizer is sure of
        let labels = ["Netzwerk und Internet", "Verbundene Geräte", "Akku", "Speicher", "Bonjour tout le monde"]
        _ = try await client.translate(labels, into: language("en"))
        XCTAssertEqual(Set(macOS.statusAsked.map(\.source)), ["de"])
        // a French paragraph on the same screen
        let request = Task { try await client.translate([Self.french], into: self.language("en")) }
        try await waitUntil { engine.hosts.contains { $0.source.languageCode?.identifier == "fr" } }
        client.cancel()
        _ = try await request.value
    }

    // MARK: Short labels together (FakeSession answers in place of the framework)

    /// Rows of Android's Network & internet page as Vision read them, and a paragraph
    private static let rows = ["Netzwerk & Internet", "Aus", AppleTranslationEngineTests.german, "Datensparmodus", "An", "Abbrechen"]
    private static let toEnglish = ["Netzwerk & Internet": "Network & internet", "Aus": "Off", "Datensparmodus": "Data Saver",
                                  "An": "On", "Abbrechen": "Cancel", "Benachrichtigungen": "Notifications",
                                  AppleTranslationEngineTests.german: "This is a quite ordinary German sentence about today's and tomorrow's weather."]

    /// What a label is: short, one line, no sentence, without the separator
    func testWhatALabelIs() {
        let labels = ["Aus", "Passwort vergessen?", "Mittwoch, 13. November", "Suchen …", "Laden...", "An / Clock",
                      "Mobile Daten, WLAN, Hotspot", "Assistant, kürzlich geöffnete Apps, Standard-Apps",
                      "eins zwei drei vier fünf sechs", String(repeating: "a", count: 50), "通知設定", "100 %",
                      "Netzwerktyp, Verschlüsselung"]
        let others = ["eins zwei drei vier fünf sechs sieben", String(repeating: "a", count: 51),
                      String(repeating: "設", count: 17), "Your device is up to date.", "Fertig. Weiter",
                      "Ton | Bild", "Ton ｜ Bild", "Ton\nBild", "", "   ", "設定が完了しました。"]
        for text in labels { XCTAssertTrue(AppleTranslationJoining.isLabel(text), text) }
        for text in others { XCTAssertFalse(AppleTranslationJoining.isLabel(text), text) }
    }

    /// The labels of a job in its order, at most twelve in a text, as even as possible; the rest,
    /// and a label with nothing to join it to, alone
    func testHowLabelsAreGrouped() {
        let long = Self.german
        func packets(_ texts: [String]) -> [[Int]] { AppleTranslationJoining.packets(for: texts) }
        XCTAssertEqual(packets([]), [])
        XCTAssertEqual(packets(["Aus"]), [[0]])
        XCTAssertEqual(packets(["Aus", long]), [[0], [1]])
        XCTAssertEqual(packets([long, "Aus", long, "An"]), [[0], [1, 3], [2]])
        let labels = (1...25).map { "Zeile \($0)" }
        XCTAssertEqual(packets(Array(labels.prefix(12))), [Array(0..<12)])
        XCTAssertEqual(packets(Array(labels.prefix(13))), [Array(0..<7), Array(7..<13)])
        XCTAssertEqual(packets(labels).map(\.count), [9, 8, 8])
        XCTAssertEqual(AppleTranslationJoining.text(of: [1, 3], in: [long, "Aus", long, "An"]), "Aus | An")
    }

    /// An answer is split at the separators; it counts only with one part per label, none empty
    /// and none many times longer than its label
    func testHowAnAnswerIsSplit() {
        let labels = ["Aus", "An", "Abbrechen"]
        func parts(_ answer: String) -> [String]? { AppleTranslationJoining.parts(of: answer, for: labels) }
        XCTAssertEqual(parts("Off | On | Cancel"), ["Off", "On", "Cancel"])
        XCTAssertEqual(parts(" Off|On |  Cancel "), ["Off", "On", "Cancel"])
        XCTAssertEqual(parts("Off ｜ On ｜ Cancel"), ["Off", "On", "Cancel"])
        XCTAssertNil(parts("Off | On"))
        XCTAssertNil(parts("Off | On | Cancel | "))
        XCTAssertNil(parts("Off |  | Cancel"))
        XCTAssertNil(parts("Off On Cancel"))
        // "An" weighs 2: up to 18 letters
        XCTAssertEqual(parts("Off | Switched on now | Cancel"), ["Off", "Switched on now", "Cancel"])
        XCTAssertNil(parts("Off | Switched on and then cancelled | Cancel"))
        // what was measured stays believable
        XCTAssertNotNil(AppleTranslationJoining.parts(of: "Hinzufügen | Rechtliche und regulatorische Informationen",
                                                      for: ["Add", "Legal & regulatory"]))
    }

    /// The log line of a call says how many texts it translated
    func testTheLogLineOfACallTellsTheNumberOfTexts() {
        XCTAssertEqual(AppleTranslationEngine.callLine("de→en", texts: 18, requests: 7, milliseconds: 343),
                       "Translation: Apple de→en: 18 texts in 7 requests, 343 ms")
    }

    /// Sends `texts` through the engine into English, with German installed, on `session`
    private func translate(_ texts: [String], on session: FakeSession) async throws
        -> (translations: [String?], client: AppleTranslationClient, served: Task<Void, Never>) {
        let macOS = FakeMacOS(supported: ["de", "en"])
        macOS.install("de")
        let engine = engine(answeredBy: macOS)
        let client = AppleTranslationClient(engine: engine)
        let request = Task { try await client.translate(texts, into: self.language("en")) }
        try await waitUntil { engine.hosts.count == 1 }
        let host = engine.hosts[0]
        let served = Task { await engine.serve(host, prepare: {}, work: { await engine.work(for: host, calling: session.call) }) }
        return (try await request.value, client, served)
    }

    /// The short labels of a job go into the framework as one text, in their order, and their
    /// answer is split again; a paragraph goes alone. Each label gets its own translation.
    func testTheShortLabelsOfAJobGoAsOneTextAndComeBackApart() async throws {
        let session = FakeSession(Self.toEnglish)
        let (translations, client, served) = try await translate(Self.rows, on: session)
        XCTAssertEqual(translations, Self.rows.map { Self.toEnglish[$0] })
        XCTAssertEqual(session.calls.count, 1)
        XCTAssertEqual(session.calls.first.map(Set.init),
                       ["Netzwerk & Internet | Aus | Datensparmodus | An | Abbrechen", Self.german])
        client.cancel()
        try await waitFor(served)
    }

    /// A text that holds the separator, a long one and a label with nothing to join it to go
    /// alone, as before
    func testATextWithTheSeparatorALongOneAndALoneLabelGoAlone() async throws {
        let long = "Gesamten Inhalt von Benachrichtigungen auf dem Sperrbildschirm anzeigen"
        let session = FakeSession(["Ton | Bild": "Sound | Picture", long: "Show all notification content on the lock screen",
                                   "Aus": "Off"])
        let (translations, client, served) = try await translate(["Aus", "Ton | Bild", long], on: session)
        XCTAssertEqual(translations, ["Off", "Sound | Picture", "Show all notification content on the lock screen"])
        XCTAssertEqual(session.calls.map(Set.init), [["Aus", "Ton | Bild", long]])
        client.cancel()
        try await waitFor(served)
    }

    /// An answer that does not split into one part per label, has an empty part, or a part many
    /// times longer than its label, is not used: the labels of that text are asked for one by one
    /// in one more call, and none of them gets a part that belongs to another
    func testAnAnswerThatDoesNotSplitAsksForTheLabelsOneByOne() async throws {
        let labels = ["Aus", "An", "Abbrechen"]
        let joined = labels.joined(separator: " | ")
        for answer in ["Off | On", "Off | On | Cancel | More", "Off |  | Cancel", "Off | | Cancel",
                       "Off | On, and every other setting there is on this phone | Cancel", "Off On Cancel"] {
            let session = FakeSession(Self.toEnglish)
            session.answers[joined] = answer
            let (translations, client, served) = try await translate(labels + [Self.german], on: session)
            XCTAssertEqual(translations, ["Off", "On", "Cancel", Self.toEnglish[Self.german]], answer)
            XCTAssertEqual(session.calls.count, 2, answer)
            XCTAssertEqual(session.calls.last, labels, answer)
            client.cancel()
            try await waitFor(served)
        }
    }

    /// Translate goes off while the framework works on a joined text whose answer would not fit:
    /// the request is answered "not now" at once, and the labels are not asked for again
    func testTurningTranslatingOffDuringAJoinedTextAsksNothingMore() async throws {
        let labels = ["Aus", "An", "Abbrechen"]
        let session = FakeSession(Self.toEnglish)
        session.answers[labels.joined(separator: " | ")] = "Off | On"
        session.holdsNextCall = true
        let macOS = FakeMacOS(supported: ["de", "en"])
        macOS.install("de")
        let engine = engine(answeredBy: macOS)
        let client = AppleTranslationClient(engine: engine)
        let request = Task { try await client.translate(labels, into: self.language("en")) }
        try await waitUntil { engine.hosts.count == 1 }
        let host = engine.hosts[0]
        let served = Task { await engine.serve(host, prepare: {}, work: { await engine.work(for: host, calling: session.call) }) }
        try await waitUntil { session.isHolding }
        client.cancel()
        let translations = try await request.value
        XCTAssertEqual(translations, [nil, nil, nil])
        session.release()
        try await waitFor(served)
        XCTAssertEqual(session.calls, [[labels.joined(separator: " | ")]])
        XCTAssertTrue(engine.hosts.isEmpty)
    }
}

/// Answers in place of a session of the framework (`TranslationSession.translations(from:)`)
@MainActor
private final class FakeSession {
    /// what a text comes back as; a text not in here, and each part of a joined text that is,
    /// see `answer`
    var answers: [String: String]
    /// the texts of each call, in the order of its requests
    private(set) var calls: [[String]] = []
    /// the next call does not answer before `release`
    var holdsNextCall = false
    private var held: CheckedContinuation<Void, Never>?

    init(_ answers: [String: String]) {
        self.answers = answers
    }

    var isHolding: Bool { held != nil }

    func release() {
        held?.resume()
        held = nil
    }

    var call: AppleTranslationCall {
        { requests in await self.translations(from: requests) }
    }

    /// A text of its own, or part by part (" | " between them, as the framework keeps it)
    private func answer(_ text: String) -> String {
        answers[text] ?? text.components(separatedBy: " | ").map { answers[$0] ?? $0 }.joined(separator: " | ")
    }

    private func translations(from requests: [TranslationSession.Request]) async -> [TranslationSession.Response] {
        calls.append(requests.map(\.sourceText))
        if holdsNextCall {
            holdsNextCall = false
            await withCheckedContinuation { held = $0 }
        }
        return requests.map {
            TranslationSession.Response(sourceLanguage: Locale.Language(identifier: "de"),
                                        targetLanguage: Locale.Language(identifier: "en"), sourceText: $0.sourceText,
                                        targetText: answer($0.sourceText), clientIdentifier: $0.clientIdentifier)
        }
    }
}

/// A value the tasks of a test share (they all run on the main actor)
@MainActor
private final class Box<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// Answers for macOS: which languages it translates, whether those of a pair are on this Mac,
/// and prepareTranslation, which waits until the test answers the question in place of the user.
@MainActor
private final class FakeMacOS {
    /// the languages of the on-device models, and of all models
    let onDevice: [Locale.Language]
    let all: [Locale.Language]
    /// hosts whose prepareTranslation was called, in that order
    private(set) var asked: [UUID] = []
    /// what the status of a pair was asked for
    private(set) var statusAsked: [(source: String, strategy: AppleTranslationStrategy)] = []
    var appleIntelligence = AppleIntelligence.on
    private(set) var appleIntelligenceAsked = 0
    /// what the status of a pair was asked for: its targets
    private(set) var targetsAsked: [String] = []
    /// sources whose pairs into every target are on this Mac
    private var installed: Set<String> = []
    private var installedPairs: Set<String> = []
    private var everything = false
    /// the language whose next status is held back until `releaseStatus`
    private var holdsStatus: String?
    private var heldStatus: CheckedContinuation<Void, Never>?
    private var pending: [(id: UUID, source: String, continuation: CheckedContinuation<Void, Error>)] = []

    /// macOS 26.4 and later: two kinds of models
    init(onDevice: [String], all: [String]) {
        self.onDevice = onDevice.map { Locale.Language(identifier: $0) }
        self.all = all.map { Locale.Language(identifier: $0) }
    }

    /// one kind of models (before macOS 26.4)
    convenience init(supported: [String]) {
        self.init(onDevice: supported, all: supported)
    }

    /// hosts whose question is up
    var preparing: [UUID] { pending.map(\.id) }

    var availability: AppleTranslationAvailability {
        // the closures are made on the main actor and run there
        AppleTranslationAvailability(languages: { AppleTranslationLanguages(onDevice: self.onDevice, all: self.all) },
                                     status: { source, target, strategy in
            self.statusAsked.append((source: source.minimalIdentifier, strategy: strategy))
            self.targetsAsked.append(target.minimalIdentifier)
            if self.holdsStatus == LanguageMatching.key(source) {
                self.holdsStatus = nil
                await withCheckedContinuation { self.heldStatus = $0 }
            }
            return self.status(of: source, to: target)
        }, appleIntelligence: {
            self.appleIntelligenceAsked += 1
            return self.appleIntelligence
        })
    }

    private func status(of source: Locale.Language, to target: Locale.Language) -> LanguageAvailability.Status {
        let pair = LanguageMatching.key(source) + "→" + LanguageMatching.key(target)
        return everything || installed.contains(LanguageMatching.key(source)) || installedPairs.contains(pair)
            ? .installed : .supported
    }

    /// The languages of this pair alone are on this Mac
    func installPair(_ source: String, _ target: String) {
        installedPairs.insert(LanguageMatching.key(Locale.Language(identifier: source)) + "→"
                              + LanguageMatching.key(Locale.Language(identifier: target)))
    }

    func prepare(_ host: AppleTranslationHost) async throws {
        asked.append(host.id)
        try await withCheckedThrowingContinuation { continuation in
            pending.append((id: host.id, source: LanguageMatching.key(host.source), continuation: continuation))
        }
    }

    func installEverything() {
        everything = true
    }

    /// The languages are on this Mac already: no question
    func install(_ language: String) {
        installed.insert(LanguageMatching.key(Locale.Language(identifier: language)))
    }

    /// The next answer about `language` does not come before `releaseStatus`
    func holdStatus(of language: String) {
        holdsStatus = LanguageMatching.key(Locale.Language(identifier: language))
    }

    /// an answer about the status of a pair is held back
    var isHoldingStatus: Bool { heldStatus != nil }

    func releaseStatus() {
        heldStatus?.resume()
        heldStatus = nil
    }

    /// The user answers the question of a host: prepareTranslation returns
    func finish(_ id: UUID, installing: Bool) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let entry = pending.remove(at: index)
        if installing { installed.insert(entry.source) }
        entry.continuation.resume()
    }

    func finish(_ host: AppleTranslationHost, installing: Bool) {
        finish(host.id, installing: installing)
    }

    /// The user closes the question without loading: prepareTranslation throws
    func decline(_ id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

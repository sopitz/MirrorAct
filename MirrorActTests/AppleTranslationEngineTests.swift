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

    private func languages(of texts: [String]) -> (findings: [LanguageMatching.Finding], common: Locale.Language?) {
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
            XCTAssertEqual(macOS.statusAsked.map(\.strategy), [entry.strategy], label)
            client.cancel()
            _ = try await request.value
            XCTAssertTrue(engine.hosts.isEmpty, label)
        }
    }

    /// Without Apple Intelligence a pair that only its models know is not asked for: macOS would
    /// show "Apple Intelligence Required", and its calls would not return before the user closes
    /// that. A target that needs it ends the turn with a word; texts in a language that needs it
    /// stay as they are. Before macOS 26.4 there are no such pairs.
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
        for entry in cases {
            let label = "\(entry.wanted) chosen: \(entry.chosen), \(entry.lists.onDevice.count) on the device"
            let macOS = FakeMacOS(onDevice: entry.lists.onDevice, all: entry.lists.all)
            macOS.appleIntelligenceIsOn = false
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
                    XCTAssertFalse(failure.message.isEmpty, label)
                }
                XCTAssertTrue(macOS.statusAsked.isEmpty, label)
                client.cancel()
            case .leftAsTheyAre:
                let translations = try await request.value
                XCTAssertEqual(translations, [entry.text], label)
                XCTAssertEqual(notices.value.count, 1, label)
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

    /// Turned on in the meantime: the next turn of translating asks again
    func testANewTurnAsksAgainWhetherAppleIntelligenceIsOn() async throws {
        let macOS = FakeMacOS(onDevice: Self.onDevice, all: Self.onDevice + Self.onlyWithAppleIntelligence)
        macOS.appleIntelligenceIsOn = false
        let engine = engine(answeredBy: macOS)
        let first = AppleTranslationClient(engine: engine)
        let unchanged = try await first.translate([Self.danish], into: language("de"))
        XCTAssertEqual(unchanged, [Self.danish])
        first.cancel()
        macOS.appleIntelligenceIsOn = true
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
        let asking = AppleTranslationEngine.askingNotice(host.source, host.target)
        let downloading = AppleTranslationEngine.downloadingNotice(host.source, host.target)
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
        XCTAssertEqual(statuses.value, [AppleTranslationEngine.askingNotice(host.source, host.target), nil])
        XCTAssertEqual(notices.value.count, 1)
        client.cancel()
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
        XCTAssertEqual(found.common?.languageCode?.identifier, "de")
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
        let plan = LanguageMatching.Plan(findings: found.findings, common: language("en"), target: language("de-DE"),
                                         supported: supported)
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
        let plan = LanguageMatching.Plan(findings: found.findings, common: found.common, target: language("de-DE"),
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
        XCTAssertEqual(found.common?.languageCode?.identifier, "de")
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
    var appleIntelligenceIsOn = true
    private(set) var appleIntelligenceAsked = 0
    private var installed: Set<String> = []
    private var everything = false
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
                                     status: { source, _, strategy in
            self.statusAsked.append((source: source.minimalIdentifier, strategy: strategy))
            return self.status(of: source)
        }, appleIntelligenceIsOn: {
            self.appleIntelligenceAsked += 1
            return self.appleIntelligenceIsOn
        })
    }

    private func status(of source: Locale.Language) -> LanguageAvailability.Status {
        everything || installed.contains(LanguageMatching.key(source)) ? .installed : .supported
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

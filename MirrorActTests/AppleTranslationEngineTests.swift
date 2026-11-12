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
        let first = AppleTranslationHost(pair: "en→de", source: language("en-US"), target: language("de-DE"))
        let second = AppleTranslationHost(pair: "en→de", source: language("en-US"), target: language("de-DE"))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.configuration.source?.maximalIdentifier, language("en-US").maximalIdentifier)
        XCTAssertEqual(first.configuration.target?.maximalIdentifier, language("de-DE").maximalIdentifier)
        // a copy of a host hands the view the same configuration: its task is not started again
        let copy = first
        XCTAssertEqual(copy.id, first.id)
        XCTAssertEqual(copy.configuration, first.configuration)
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
    /// that waits ends at once, and nothing is asked anymore
    func testHostsThatWaitForTheirTurnEndWhenTranslatingIsTurnedOff() async throws {
        let macOS = FakeMacOS(supported: ["de", "en", "fr"])
        let engine = engine(answeredBy: macOS)
        let client = AppleTranslationClient(engine: engine)
        let request = Task { try await client.translate([Self.english, Self.french], into: self.language("de")) }
        try await waitUntil { engine.hosts.count == 2 }
        var served: [UUID: Task<Void, Never>] = [:]
        for host in engine.hosts {
            served[host.id] = Task { await engine.serve(host, prepare: { try await macOS.prepare(host) }, work: {}) }
        }
        _ = try await request.value
        try await waitUntil { engine.hostsWaitingToLoad == 1 }
        let asked = try XCTUnwrap(macOS.preparing.first)
        client.cancel()
        // the one in line goes without asking
        let other = try XCTUnwrap(served.keys.first { $0 != asked })
        await served[other]?.value
        XCTAssertEqual(engine.hostsWaitingToLoad, 0)
        // the question that is up has to be answered (closing it is not up to the app)
        XCTAssertEqual(engine.hosts.map(\.id), [asked])
        macOS.finish(asked, installing: false)
        await served[asked]?.value
        XCTAssertEqual(macOS.asked, [asked])
        XCTAssertTrue(engine.hosts.isEmpty)
    }

    /// Translating turned off and on again while macOS still asks about a pair: the question
    /// stays, and no second one is queued behind it for the same pair. The new turn is told,
    /// as the first one was, that the languages are loading.
    func testAPairWhoseQuestionIsStillUpIsNotAskedForAgain() async throws {
        let macOS = FakeMacOS(supported: ["de", "en"])
        let engine = engine(answeredBy: macOS)
        // a job no view takes is not waited for long
        engine.pickUpLimit = 3
        let first = AppleTranslationClient(engine: engine)
        let firstNotices = Box<[String]>([])
        first.notify = { message in MainActor.assumeIsolated { firstNotices.value.append(message) } }
        let request = Task { try await first.translate([Self.english], into: self.language("de")) }
        try await waitUntil { engine.hosts.count == 1 }
        let host = engine.hosts[0]
        let served = Task { await engine.serve(host, prepare: { try await macOS.prepare(host) }, work: {}) }
        _ = try await request.value
        try await waitUntil { macOS.preparing.count == 1 }
        XCTAssertEqual(firstNotices.value.count, 1)
        first.cancel()

        let second = AppleTranslationClient(engine: engine)
        let secondNotices = Box<[String]>([])
        second.notify = { message in MainActor.assumeIsolated { secondNotices.value.append(message) } }
        let answered = Box<Bool>(false)
        let again = Task {
            defer { answered.value = true }
            return try await second.translate([Self.english], into: self.language("de"))
        }
        try await waitUntil { answered.value || engine.hosts.count > 1 }
        XCTAssertEqual(engine.hosts.map(\.id), [host.id])
        // "not now": asked again once the question is answered
        let translations = try await again.value
        XCTAssertEqual(translations, [nil])
        XCTAssertEqual(engine.hosts.map(\.id), [host.id])
        // the same notice ("Loading English for translating …"), once
        XCTAssertEqual(secondNotices.value, firstNotices.value)
        _ = try await second.translate([Self.english], into: language("de"))
        XCTAssertEqual(secondNotices.value, firstNotices.value)

        macOS.finish(host, installing: false)
        await served.value
        XCTAssertTrue(engine.hosts.isEmpty)
        second.cancel()
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
    let supported: [Locale.Language]
    /// hosts whose prepareTranslation was called, in that order
    private(set) var asked: [UUID] = []
    private var installed: Set<String> = []
    private var everything = false
    private var pending: [(id: UUID, source: String, continuation: CheckedContinuation<Void, Error>)] = []

    init(supported: [String]) {
        self.supported = supported.map { Locale.Language(identifier: $0) }
    }

    /// hosts whose question is up
    var preparing: [UUID] { pending.map(\.id) }

    var availability: AppleTranslationAvailability {
        // the closures are made on the main actor and run there
        AppleTranslationAvailability(supportedLanguages: { self.supported },
                                     status: { source, _ in self.status(of: source) })
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
}

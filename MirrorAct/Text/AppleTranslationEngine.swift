// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import FoundationModels
import NaturalLanguage
import SwiftUI
import Translation

/// Translates on this Mac with Apple's Translation framework; no text leaves the Mac.
///
/// The framework hands out its sessions only to SwiftUI views (`translationTask`), one language
/// pair per session, and a session may only be used while its view exists. So the engine keeps
/// one invisible view per language pair in use (`AppleTranslationHost`, shown in a window nobody
/// sees). The task of each view runs `serve`, which translates the jobs queued for its pair and
/// does not return before the pair is no longer needed. The texts of a request are sorted by
/// their language first (`LanguageMatching`), because a session translates from one language only.
/// The short labels of one language go to the framework together, as one text, so that each has
/// the others for context (`AppleTranslationJoining`).
///
/// From macOS 26.4 on, Translation has two kinds of models: the on-device ones (`.lowLatency`)
/// and those that need Apple Intelligence for many of their languages (`.highFidelity`, which
/// macOS takes when nothing is said). A screen translated live wants the fast ones, and without
/// Apple Intelligence the others translate nothing. So the engine takes the on-device models for
/// every pair they know, and the others only for a language only they have (Danish, or a region
/// the user chose such as Portuguese (Portugal)). Without Apple Intelligence such a pair is not
/// asked for: macOS would show its question "Apple Intelligence Required", and prepareTranslation
/// and translations(from:) would not return before the user closes it.
///
/// All mirror windows share the engine. Each turn of translating of a window talks to it
/// through an `AppleTranslationClient` of its own, which gets the notices of its requests and
/// whose `cancel` ends its own work only.
@MainActor
final class AppleTranslationEngine: ObservableObject {
    /// One for the whole app: all mirror windows share the sessions and the window that holds them.
    static let shared = AppleTranslationEngine()

    init() {}

    /// One entry per language pair in use; `AppleTranslationHostView` shows a view for each
    @Published private(set) var hosts: [AppleTranslationHost] = []

    /// seconds macOS may take to say which languages and pairs it translates
    var questionLimit: TimeInterval = 20
    /// seconds a job waits for a session before it is given up
    var pickUpLimit: TimeInterval = 20
    /// seconds a session may take to answer before the caller stops waiting for it
    var answerLimit: TimeInterval = 60
    /// seconds without work after which a pair gives its session back
    var idleLimit: TimeInterval = 300
    /// seconds a pair whose languages could not be loaded is left alone
    var retryPause: TimeInterval = 60
    /// seconds to wait for languages that macOS is loading
    var loadingLimit: TimeInterval = 1800
    /// Seconds after the question of macOS is answered from which the user is told what to do
    /// if the languages were not downloaded. macOS does not tell a download from a question that
    /// was closed without one, so no wait would be long enough for every download (German and
    /// English, about 730 MB, took 49 s on a fast line); the notice is worded to hold for both,
    /// and the user learns within half a minute what to do if nothing comes.
    var downloadPatience: TimeInterval = 20
    /// seconds between two looks at languages that are on their way
    var loadingCheckInterval: TimeInterval = 2

    /// What macOS says about its languages. The tests answer in its place, so that they depend
    /// neither on the languages of this Mac nor on a download.
    var availability = AppleTranslationAvailability.system
    /// Makes the window for the views that are given the sessions. The tests make none and run
    /// `serve` themselves, so that macOS never hands them a session.
    var makeWindow: @MainActor (AppleTranslationEngine) -> NSWindow? = { AppleTranslationHostWindow.make(for: $0) }

    private var window: NSWindow?
    /// The window normally lies outside of all screens. Should the views not start there, it is
    /// moved onto the main screen for good (it is not to be seen there either).
    private var keepsWindowOnScreen = false
    /// the languages macOS translates; asked once, the lists do not change while the app runs
    private var languages = AppleTranslationLanguages([])

    private var signals: [UUID: AppleTranslationSignal] = [:]
    /// hosts whose view has started and holds a session
    private var serving: Set<UUID> = []
    /// hosts that take no more jobs and end after what they are doing
    private var ending: Set<UUID> = []
    /// hosts that wait for macOS to load their languages
    private var loading: Set<UUID> = []
    /// hosts whose prepareTranslation has not returned yet: macOS shows its question. Giving
    /// nil stops waiting for the call (see `ask`).
    private var questions: [UUID: AppleTranslationFirstAnswer<Result<Void, Error>>] = [:]
    /// hosts of `loading` whose question was answered: their languages are on their way, or the
    /// question was closed without downloading them (macOS does not say which)
    private var downloading: Set<UUID> = []
    /// hosts of `downloading` whose languages are not there after `downloadPatience` seconds
    private var missing: Set<UUID> = []
    /// the host that asks macOS to load its languages right now, and those that wait for their
    /// turn, oldest first
    private var loadingTurn: UUID?
    private var waitingForTurn: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    /// jobs no session has taken yet, oldest first
    private var waiting: [AppleTranslationJob] = []
    /// jobs a session is working on
    private var running: [AppleTranslationJob] = []

    /// the clients whose translating is on, by `ObjectIdentifier`
    private var clients: [ObjectIdentifier: AppleTranslationClient.Reference] = [:]

    // What follows is forgotten when translating is turned on again (a new client asks).
    /// pairs whose languages the user did not let macOS load
    private var declined: Set<String> = []
    /// whether macOS can translate a pair at all
    private var pairSupport: [String: Bool] = [:]
    /// pairs whose languages are on this Mac
    private var installedPairs: Set<String> = []
    /// pairs whose languages were not on this Mac when macOS was last asked, and when that was
    private var notInstalledSince: [String: TimeInterval] = [:]
    /// seconds for which an answer that the languages of a pair are not on this Mac holds
    var statusAge: TimeInterval = 5
    /// what this Mac says about Apple Intelligence; nil = not asked yet
    private var appleIntelligence: AppleIntelligence?

    /// pairs whose languages failed to load, and when they may be tried again
    private var blockedUntil: [String: TimeInterval] = [:]

    private static var clock: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// the language the app shows its own texts in
    private static var noticeLocale: Locale {
        Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    }

    private static func pair(_ source: Locale.Language, _ target: Locale.Language) -> String {
        "\(LanguageMatching.key(source))→\(LanguageMatching.key(target))"
    }

    // MARK: Requests

    /// What `AppleTranslationClient.translate` does: the texts of one request of `client`.
    func translate(_ texts: [String], into wanted: Locale.Language,
                   for client: AppleTranslationClient) async throws -> [String?] {
        guard !texts.isEmpty else { return [] }
        guard register(client) else { return [String?](repeating: nil, count: texts.count) }
        guard let languages = await supportedLanguages() else {
            // no answer from macOS: not now
            noteNoAnswer(to: client)
            return [String?](repeating: nil, count: texts.count)
        }
        // A form the user chose in the settings is taken as chosen. The language of the system
        // gets the form of the on-device models wherever they have the language: es for es-AR,
        // pt for pt-PT, en-GB for en-DE.
        let found = client.targetIsChosen ? LanguageMatching.match(wanted, in: languages.all)
                                          : LanguageMatching.match(wanted, inFirstOf: languages.lists)
        guard let target = found else {
            let language = LanguageMatching.name(of: wanted, in: Self.noticeLocale)
            throw TranslationFailure(message: String(localized: "Translation into \(language) isn’t available on this Mac"),
                                     isPermanent: true)
        }
        if !languages.isOnDevice(target) {
            let state = appleIntelligenceState()
            guard state == .on else {
                throw TranslationFailure(message: Self.targetNeedsAppleIntelligenceNotice(target, state), isPermanent: true)
            }
        }
        // telling the languages apart takes a moment: not on the main thread
        let all = languages.all
        let tags = LanguageMatching.recognizerTags(for: all)
        let before = client.screenLanguage
        let read = await Task.detached(priority: .userInitiated) {
            AppleTranslationEngine.readLanguages(of: texts, tags: tags, supported: all, before: before)
        }.value
        client.screenLanguage = read.screen
        // the languages on the screen, too, as the on-device models know them where they can
        let plan = LanguageMatching.Plan(findings: read.findings, screen: read.screen, target: target,
                                         lists: languages.lists)
        var results = plan.results(for: texts)
        for language in plan.unknown { noteUntranslatable(language, to: [client]) }

        // one job per language; their sessions work side by side
        var pending: [(group: LanguageMatching.Plan.Group, answer: Task<[String?], Error>)] = []
        for group in plan.groups {
            // the language of the system in a form whose pair with this language is on this Mac
            // (not looked for where the pair needs Apple Intelligence and it is off)
            var pairTarget = target
            if !client.targetIsChosen, languages.strategy(from: group.source, to: target) == .lowLatency
                || appleIntelligenceState() == .on {
                pairTarget = await installedForm(of: target, from: group.source, in: languages)
            }
            let pair = Self.pair(group.source, pairTarget)
            let strategy = languages.strategy(from: group.source, to: pairTarget)
            client.pairs.insert(pair)
            let groupTexts = group.indices.map { texts[$0] }
            if strategy == .highFidelity {
                let state = appleIntelligenceState()
                guard state == .on else {
                    // Too little text speaks for the language to say anything about it: "not now"
                    // (a name or a single word on the screen is no reason to mention Apple Intelligence)
                    guard group.mayAskForTheLanguage else { continue }
                    // the language of these texts only the models that need Apple Intelligence
                    // know: they stay as they are
                    group.place(groupTexts.map { Optional($0) }, in: &results)
                    noteNeedsAppleIntelligence(group.source, pairTarget, state, to: [client])
                    continue
                }
            }
            guard let translatable = await isSupported(pair, from: group.source, to: pairTarget, with: strategy) else {
                noteNoAnswer(to: client)
                continue
            }
            guard translatable else {
                // nothing to be done for this language: its texts stay, and are not asked for again
                group.place(groupTexts.map { Optional($0) }, in: &results)
                if group.mayAskForTheLanguage { noteUntranslatable(group.source, to: [client]) }
                continue
            }
            // A pair whose languages macOS would have to download first is asked for only when
            // enough of the text is in the language; until then its texts are "not now"
            if !group.mayAskForTheLanguage,
               await !isInstalled(pair, from: group.source, to: pairTarget, with: strategy) {
                continue
            }
            // turned off meanwhile, or the languages are not on this Mac (yet): nil, the caller asks again
            if Task.isCancelled || client.isCancelled { continue }
            if isPostponed(pair) {
                // a client that asks only after the loading began is told as well
                if isLoading(pair) { updateStatuses() }
                continue
            }
            let job = AppleTranslationJob(client: client, pair: pair, source: group.source, target: pairTarget,
                                          strategy: strategy, texts: groupTexts)
            pending.append((group: group, answer: Task { try await self.answer(to: job) }))
        }
        var failure: Error?
        var translated = false
        for entry in pending {
            do {
                let translations = try await entry.answer.value
                entry.group.place(translations, in: &results)
                translated = true
            } catch {
                if failure == nil { failure = error }
            }
        }
        if let failure {
            // the request as a whole failed only if nothing came of it
            guard translated else { throw failure }
            let message = (failure as? TranslationFailure)?.message ?? failure.localizedDescription
            note("failed " + message, message, to: [client])
        }
        return results
    }

    /// The first request of a client turns its translating on. false = it was cancelled already.
    private func register(_ client: AppleTranslationClient) -> Bool {
        guard !client.isCancelled else { return false }
        let key = ObjectIdentifier(client)
        if clients[key]?.client !== client {
            // translating was turned on again: ask macOS again what was declined or unknown
            declined.removeAll()
            pairSupport.removeAll()
            installedPairs.removeAll()
            notInstalledSince.removeAll()
            appleIntelligence = nil
            clients[key] = AppleTranslationClient.Reference(client: client)
            // The notice for languages that did not come says to turn translating off and on to
            // be asked again: that holds also while another window wants the pair and keeps its
            // host looking for them. The host ends, and the next request asks anew.
            for host in hosts where missing.contains(host.id) && !ending.contains(host.id) {
                Log.info("Translation: no longer waiting for the languages for \(host.pair); asking again")
                end(host)
            }
        }
        return true
    }

    /// The clients whose translating is on
    private var activeClients: [AppleTranslationClient] {
        clients.values.compactMap(\.client).filter { !$0.isCancelled }
    }

    /// `AppleTranslationClient.cancel`: its jobs are answered "not now" at once. The hosts of the
    /// pairs no other client wants end, whatever they are doing; the others stay for the other
    /// clients.
    func cancel(_ client: AppleTranslationClient) {
        clients[ObjectIdentifier(client)] = nil
        // (a client that went away without cancelling counts as gone as well)
        clients = clients.filter { $0.value.client.map { !$0.isCancelled } ?? false }
        let jobs = (waiting + running).filter { $0.client === client }
        waiting.removeAll { $0.client === client }
        running.removeAll { $0.client === client }
        for job in jobs { job.finish(job.postponed) }
        // Left alone, a host that waits for its turn, or is about to ask, would bring up the
        // question of macOS once the one before is answered, for languages nobody wants.
        let wanted = Set(activeClients.flatMap(\.pairs))
        for host in hosts where !wanted.contains(host.pair) {
            if questions[host.id] != nil {
                // the question of macOS goes away with the view
                Log.info("Translation: closing the question about the languages for \(host.pair)")
                remove(host)
            } else if serving.contains(host.id) {
                // Waiting for its turn, about to ask, waiting for the download or translating:
                // it ends without asking, and after a call on its session that is under way
                end(host)
            } else {
                // its view has not started, and will not get a session now
                remove(host)
            }
        }
        guard clients.isEmpty else { return }
        declined.removeAll()
        pairSupport.removeAll()
        installedPairs.removeAll()
        notInstalledSince.removeAll()
        appleIntelligence = nil
    }

    /// nil = macOS did not answer in time
    private func supportedLanguages() async -> AppleTranslationLanguages? {
        if languages.isEmpty {
            // an empty answer is not kept: the next request asks again
            let availability = self.availability
            guard let answer = await inTime({ await availability.languages() }) else {
                Log.error("Translation: macOS did not say within \(Int(questionLimit)) s which languages it translates")
                return nil
            }
            languages = answer
            func list(_ languages: [Locale.Language]) -> String {
                languages.map(\.minimalIdentifier).sorted().joined(separator: " ")
            }
            Log.info("Translation: macOS translates \(list(answer.all)), on this Mac alone \(list(answer.onDevice))")
        }
        return languages
    }

    /// macOS knows both languages, but not every pair of them. nil = it did not answer in time.
    private func isSupported(_ pair: String, from source: Locale.Language, to target: Locale.Language,
                             with strategy: AppleTranslationStrategy) async -> Bool? {
        if let known = pairSupport[pair] { return known }
        let availability = self.availability
        guard let status = await inTime({ await availability.status(source, target, strategy) }) else {
            Log.error("Translation: macOS did not say within \(Int(questionLimit)) s whether it translates \(pair)")
            return nil
        }
        pairSupport[pair] = status != .unsupported
        return status != .unsupported
    }

    /// Whether the languages of a pair are on this Mac. Once they are, macOS is not asked again
    /// in this turn, and while they are not, at most every `statusAge` seconds. false also when
    /// macOS does not answer in time.
    private func isInstalled(_ pair: String, from source: Locale.Language, to target: Locale.Language,
                             with strategy: AppleTranslationStrategy) async -> Bool {
        if installedPairs.contains(pair) { return true }
        if let asked = notInstalledSince[pair], Self.clock - asked < statusAge { return false }
        let availability = self.availability
        guard let status = await inTime({ await availability.status(source, target, strategy) }) else { return false }
        pairSupport[pair] = status != .unsupported
        if status == .installed {
            installedPairs.insert(pair)
            notInstalledSince[pair] = nil
        } else {
            notInstalledSince[pair] = Self.clock
        }
        return status == .installed
    }

    /// The form of `target` (the language of the system as the models know it: "en-GB" for
    /// "en-DE") to translate `source` into: `target` itself if its pair with `source` is on this
    /// Mac, otherwise the first other form of the same language and script in the same list of
    /// languages whose pair is ("en" when German and English (US) are there). Where no pair with
    /// `source` is on this Mac yet, a form that a pair with another language was seen on this Mac
    /// with in this turn, in the same order (French goes into English (US) as well then, and macOS
    /// asks for French alone). Otherwise `target`. A form the user chose in the settings is not
    /// looked for (see `translate`).
    private func installedForm(of target: Locale.Language, from source: Locale.Language,
                               in languages: AppleTranslationLanguages) async -> Locale.Language {
        let list = languages.isOnDevice(target) ? languages.onDevice : languages.all
        let others = Self.otherForms(of: target, in: list)
        // nothing to choose from: macOS need not be asked here
        guard !others.isEmpty else { return target }
        let forms = [target] + others
        for form in forms {
            let pair = Self.pair(source, form)
            if await isInstalled(pair, from: source, to: form, with: languages.strategy(from: source, to: form)) {
                return form
            }
        }
        for form in forms {
            let ending = "→" + LanguageMatching.key(form)
            if installedPairs.contains(where: { $0.hasSuffix(ending) }) { return form }
        }
        return target
    }

    /// The entries of `list` in the same language and script as `language`, but another form of it
    private static func otherForms(of language: Locale.Language, in list: [Locale.Language]) -> [Locale.Language] {
        let key = LanguageMatching.key(language)
        let script = Locale.Language(identifier: language.maximalIdentifier).script
        return list.filter {
            LanguageMatching.sameLanguage($0, language) && LanguageMatching.key($0) != key
                && Locale.Language(identifier: $0.maximalIdentifier).script == script
        }
    }

    /// Asked once per turn of translating: the user may turn Apple Intelligence on meanwhile
    private func appleIntelligenceState() -> AppleIntelligence {
        if let known = appleIntelligence { return known }
        let state = availability.appleIntelligence()
        appleIntelligence = state
        switch state {
        case .on: break
        case .off: Log.info("Translation: Apple Intelligence is off; languages only its models know are left alone")
        case .notOnThisMac: Log.info("Translation: this Mac has no Apple Intelligence; languages only its models know are left alone")
        }
        return state
    }

    /// The answer to a question to macOS, or nil when it takes longer than `questionLimit`: a
    /// request must come back even if the framework does not.
    private func inTime<Answer>(_ question: @escaping () async -> Answer) async -> Answer? {
        let limit = UInt64(questionLimit * 1_000_000_000)
        return await withCheckedContinuation { continuation in
            let first = AppleTranslationFirstAnswer(continuation)
            Task { first.give(await question()) }
            Task {
                try? await Task.sleep(nanoseconds: limit)
                first.give(nil)
            }
        }
    }

    /// The texts of this pair cannot be translated right now: they are answered with nil, without a job
    private func isPostponed(_ pair: String) -> Bool {
        if declined.contains(pair) { return true }
        if let until = blockedUntil[pair] {
            if Self.clock < until { return true }
            blockedUntil[pair] = nil
        }
        // also while another host of the pair waits for its languages: a new host would only ask
        // a second time (a host whose question is up and nobody wants is removed, see `cancel`)
        return isLoading(pair)
    }

    /// A host of the pair waits for macOS to load its languages (and is not on its way out)
    private func isLoading(_ pair: String) -> Bool {
        hosts.contains { $0.pair == pair && loading.contains($0.id) && !ending.contains($0.id) }
    }

    // MARK: Jobs

    /// Queues a job and waits for its answer. There always is one: from a session, or nil for
    /// every text when no session took the job in time or translating was turned off.
    private func answer(to job: AppleTranslationJob) async throws -> [String?] {
        try await withCheckedThrowingContinuation { continuation in
            job.wait(for: continuation)
            enqueue(job)
        }
    }

    private func enqueue(_ job: AppleTranslationJob) {
        // decided while the job was on its way here
        guard !job.client.isCancelled, !isPostponed(job.pair) else {
            job.finish(job.postponed)
            return
        }
        waiting.append(job)
        wakeHost(for: job)
        let limit = UInt64(pickUpLimit * 1_000_000_000)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: limit)
            self?.giveUp(job)
        }
    }

    /// No session took the job in time.
    private func giveUp(_ job: AppleTranslationJob) {
        guard let index = waiting.firstIndex(where: { $0 === job }) else { return }
        waiting.remove(at: index)
        if hosts.contains(where: { $0.pair == job.pair && serving.contains($0.id) }) {
            Log.error("Translation: the session for \(job.pair) was busy for \(Int(pickUpLimit)) s")
        } else {
            Log.error("Translation: no session for \(job.pair) within \(Int(pickUpLimit)) s; "
                      + "the view that is to get it may not be running")
            // a host whose view never started has no session: the next job gets a new one
            for host in hosts where host.pair == job.pair {
                remove(host)
            }
            if !keepsWindowOnScreen, window != nil {
                keepsWindowOnScreen = true
                Log.info("Translation: moving the window of the views onto the screen")
                placeWindow()
            }
            // others that wait for the pair do not have to wait for nothing
            if let next = waiting.first(where: { $0.pair == job.pair }) { wakeHost(for: next) }
        }
        noteNoAnswer(to: job.client)
        job.finish(job.postponed)
    }

    /// The session did not answer in time. Its call cannot be taken back; the caller stops waiting.
    private func overdue(_ job: AppleTranslationJob, on host: AppleTranslationHost) {
        guard let index = running.firstIndex(where: { $0 === job }) else { return }
        running.remove(at: index)
        Log.error("Translation: no answer for \(job.pair) within \(Int(answerLimit)) s")
        // the next job of the pair gets a new session
        end(host)
        noteNoAnswer(to: job.client)
        job.finish(job.postponed)
    }

    private func takeJob(for pair: String) -> AppleTranslationJob? {
        guard let index = waiting.firstIndex(where: { $0.pair == pair }) else { return nil }
        return waiting.remove(at: index)
    }

    private func finishWaitingJobs(of pair: String, with answer: (AppleTranslationJob) -> [String?]) {
        let jobs = waiting.filter { $0.pair == pair }
        waiting.removeAll { $0.pair == pair }
        for job in jobs { job.finish(answer(job)) }
    }

    // MARK: Hosts

    /// Makes sure the pair of a job has a host that takes jobs, and wakes it.
    private func wakeHost(for job: AppleTranslationJob) {
        if !hosts.contains(where: { $0.pair == job.pair && !ending.contains($0.id) }) {
            if window == nil { openWindow() }
            let host = AppleTranslationHost(pair: job.pair, source: job.source, target: job.target,
                                            strategy: job.strategy)
            let (stream, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            signals[host.id] = AppleTranslationSignal(stream: stream, wake: wake)
            hosts.append(host)
            Log.info("Translation: session for \(host.pair) requested")
        }
        for host in hosts where host.pair == job.pair {
            signals[host.id]?.wake.yield()
        }
    }

    /// Tells a host to end after what it is doing. It takes itself out of the list then.
    private func end(_ host: AppleTranslationHost) {
        ending.insert(host.id)
        signals[host.id]?.wake.finish()
        leaveLineToLoad(host)
    }

    /// Takes a host out of the list, which ends its view and with it the session. Never while the
    /// session is in use: `serve` does this when it is done, everyone else only for a host whose
    /// view has not started, or whose view waits for the answer to the question of macOS.
    private func remove(_ host: AppleTranslationHost) {
        // the question closes with the view, and its call never returns: `serve` goes on without it
        questions.removeValue(forKey: host.id)?.give(nil)
        signals.removeValue(forKey: host.id)?.wake.finish()
        serving.remove(host.id)
        ending.remove(host.id)
        leaveLineToLoad(host)
        passOnTurnToLoad(from: host)
        hosts.removeAll { $0.id == host.id }
        setLoading(false, for: host)
    }

    /// (a host that was taken out of the list ends as well)
    private func isEnding(_ host: AppleTranslationHost) -> Bool {
        Task.isCancelled || ending.contains(host.id) || signals[host.id] == nil
    }

    private func setLoading(_ isLoading: Bool, for host: AppleTranslationHost) {
        if isLoading {
            loading.insert(host.id)
        } else {
            loading.remove(host.id)
            downloading.remove(host.id)
            missing.remove(host.id)
        }
        updateStatuses()
        placeWindow()
    }

    /// macOS may attach its question about loading languages to the window that asks: it has to
    /// be on a screen while a question may be up, and above mirror windows that are kept on top.
    /// Once the question is answered (`downloading`) it goes back to its place outside the screens.
    private func placeWindow() {
        guard let window else { return }
        let mayAsk = loading.contains { !downloading.contains($0) }
        AppleTranslationHostWindow.place(window, onScreen: mayAsk || keepsWindowOnScreen)
        AppleTranslationHostWindow.raise(window, mayAsk)
    }

    /// The question of macOS is a sheet of the window. A window moved while a sheet is attached is
    /// moved back by AppKit when the sheet ends, so it is placed again then.
    private func openWindow() {
        window = makeWindow(self)
        guard let window else { return }
        NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: window,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeWindow() }
        }
    }

    /// macOS asks about one pair at a time. A `prepareTranslation` that starts while the question
    /// for another pair is up returns at once, with nothing loaded. true = it is this host's turn;
    /// false = the host has to end before that.
    private func waitForTurnToLoad(_ host: AppleTranslationHost) async -> Bool {
        if loadingTurn == nil {
            loadingTurn = host.id
            return true
        }
        return await withCheckedContinuation { continuation in
            waitingForTurn.append((id: host.id, continuation: continuation))
        }
    }

    private func passOnTurnToLoad(from host: AppleTranslationHost) {
        guard loadingTurn == host.id else { return }
        loadingTurn = nil
        guard !waitingForTurn.isEmpty else { return }
        let next = waitingForTurn.removeFirst()
        loadingTurn = next.id
        next.continuation.resume(returning: true)
    }

    /// A host that ends does not keep the others waiting
    private func leaveLineToLoad(_ host: AppleTranslationHost) {
        guard let index = waitingForTurn.firstIndex(where: { $0.id == host.id }) else { return }
        waitingForTurn.remove(at: index).continuation.resume(returning: false)
    }

    /// hosts that wait for their turn to ask macOS to load their languages (for the tests)
    var hostsWaitingToLoad: Int { waitingForTurn.count }

    /// whether a host whose view has started still takes jobs (for the tests, which serve
    /// without a session)
    func takesJobs(_ host: AppleTranslationHost) -> Bool {
        serving.contains(host.id) && !isEnding(host)
    }

    /// Runs inside the `translationTask` of the host's view, on its session, and returns when the
    /// pair is no longer needed. Only in here the session is valid, and the view has to stay
    /// until this returns; that is why nobody else removes a host that is served.
    func serve(_ host: AppleTranslationHost, with session: TranslationSession) async {
        await serve(host, prepare: { try await session.prepareTranslation() },
                    work: { await self.work(for: host, calling: { try await session.translations(from: $0) }) })
    }

    /// `serve` with what it does on the session handed in, so that the tests can run it without one
    func serve(_ host: AppleTranslationHost, prepare: @escaping () async throws -> Void,
               work: () async -> Void) async {
        // a host that was given up meanwhile, or a second session for the same view
        guard signals[host.id] != nil, !serving.contains(host.id) else { return }
        serving.insert(host.id)
        if await load(host, prepare: prepare) {
            await work()
        }
        remove(host)
        Log.info("Translation: session for \(host.pair) ended")
        // a job that came while this host was on its way out
        if let job = waiting.first(where: { $0.pair == host.pair }) { wakeHost(for: job) }
    }

    /// Makes sure the languages of the pair are on this Mac. macOS asks the user before it loads
    /// them. false = this host cannot translate.
    private func load(_ host: AppleTranslationHost, prepare: @escaping () async throws -> Void) async -> Bool {
        var status = await availability.status(host.source, host.target, host.strategy)
        if status == .supported, !isEnding(host) {
            setLoading(true, for: host)
            // loading takes minutes: those who wait for this pair ask again later
            finishWaitingJobs(of: host.pair) { $0.postponed }
            let language = LanguageMatching.name(of: host.source, in: Self.noticeLocale)
            guard await waitForTurnToLoad(host) else {
                setLoading(false, for: host)
                return false
            }
            // the pair before may have brought these languages along
            status = await availability.status(host.source, host.target, host.strategy)
            let asks = status == .supported && !isEnding(host)
            var failure: Error?
            if asks {
                Log.info("Translation: asking macOS to load the languages for \(host.pair)")
                switch await ask(host, prepare) {
                case nil:
                    // translating was turned off, and the question closed with the view
                    return false
                case .failure(let error):
                    failure = error
                case .success:
                    break
                }
            }
            // The turn is for the question, which is gone once prepareTranslation returns: the
            // next pair may ask while these languages are still on their way.
            passOnTurnToLoad(from: host)
            if asks {
                if let error = failure {
                    setLoading(false, for: host)
                    // translating was turned off meanwhile: what became of the question no longer matters
                    if isEnding(host) { return false }
                    if Self.isCancellation(error) {
                        declinedLoading(for: host)
                    } else {
                        blockedUntil[host.pair] = Self.clock + retryPause
                        Log.error("Translation: loading the languages for \(host.pair) failed: \(Self.describe(error))")
                        note("not loaded " + host.pair, String(localized: "Loading \(language) failed"),
                             to: clients(using: host.pair))
                    }
                    return false
                }
                // prepareTranslation returns in the same way whether the user downloaded the
                // languages or closed the question with "Done" without downloading, and macOS
                // says "supported" during a download as well: whether they come shows only when
                // they are there. The notices hold in both cases.
                downloading.insert(host.id)
                updateStatuses()
                placeWindow()
                let start = Self.clock
                status = await availability.status(host.source, host.target, host.strategy)
                while status == .supported, !isEnding(host), Self.clock - start < loadingLimit {
                    if !missing.contains(host.id), Self.clock - start >= downloadPatience {
                        // so far for a download; the user is told what to do should they not come
                        Log.info("Translation: the languages for \(host.pair) are not there after "
                                 + "\(Int(downloadPatience)) s; still looking for them")
                        missing.insert(host.id)
                        updateStatuses()
                    }
                    try? await Task.sleep(nanoseconds: UInt64(loadingCheckInterval * 1_000_000_000))
                    status = await availability.status(host.source, host.target, host.strategy)
                }
                if status == .supported, !isEnding(host) {
                    setLoading(false, for: host)
                    Log.info("Translation: the languages for \(host.pair) are not there after \(Int(loadingLimit)) s")
                    // most likely they were never downloaded: as if the question had been declined
                    declinedLoading(for: host)
                    return false
                }
                if status == .installed { Log.info("Translation: the languages for \(host.pair) are loaded") }
            }
            setLoading(false, for: host)
        }
        if isEnding(host) { return false }
        if status == .installed { return true }
        // the answer has changed since the request looked: macOS cannot translate this pair
        pairSupport[host.pair] = false
        noteUntranslatable(host.source, to: clients(using: host.pair))
        finishWaitingJobs(of: host.pair) { $0.unchanged }
        return false
    }

    /// prepareTranslation, which returns once the user has answered the question of macOS. nil =
    /// the host was removed meanwhile. Only taking the view away closes the question, and then
    /// the call never returns; TranslationSession.cancel() neither closes it nor ends the call.
    /// So the call runs on its own, and the host does not wait for it: it ends, and a new host for
    /// the pair brings up a new question at once.
    private func ask(_ host: AppleTranslationHost,
                     _ prepare: @escaping () async throws -> Void) async -> Result<Void, Error>? {
        let answer = await withCheckedContinuation { continuation in
            let first = AppleTranslationFirstAnswer<Result<Void, Error>>(continuation)
            questions[host.id] = first
            Task {
                do {
                    try await prepare()
                    first.give(.success(()))
                } catch {
                    first.give(.failure(error))
                }
            }
        }
        questions[host.id] = nil
        return answer
    }

    /// The user closed the question of macOS or its progress window, or the languages did not
    /// come: not now. Nothing is asked again until translating is turned off and on.
    private func declinedLoading(for host: AppleTranslationHost) {
        declined.insert(host.pair)
        Log.info("Translation: the languages for \(host.pair) were not loaded")
        let language = LanguageMatching.name(of: host.source, in: Self.noticeLocale)
        note("declined " + host.pair,
             String(localized: "\(language) is not loaded yet – turn translating on again to load it"),
             to: clients(using: host.pair))
        finishWaitingJobs(of: host.pair) { $0.postponed }
    }

    /// Translates the jobs of the pair as they come, until the host has to end. `call` is
    /// `translations(from:)` of the host's session; the tests answer in its place.
    func work(for host: AppleTranslationHost, calling call: AppleTranslationCall) async {
        guard let signal = signals[host.id] else { return }
        var idle = idleTimer(for: host)
        // woken once when the host was made, so jobs that were queued before the view started are seen
        for await _ in signal.stream {
            idle.cancel()
            var intact = true
            while intact, !isEnding(host), let job = takeJob(for: host.pair) {
                intact = await run(job, calling: call, for: host)
            }
            if !intact || isEnding(host) { break }
            idle = idleTimer(for: host)
        }
        idle.cancel()
    }

    /// Ends the host when no job came for a while.
    private func idleTimer(for host: AppleTranslationHost) -> Task<Void, Never> {
        let limit = UInt64(idleLimit * 1_000_000_000)
        return Task { [weak self] in
            try? await Task.sleep(nanoseconds: limit)
            guard !Task.isCancelled else { return }
            self?.end(host)
        }
    }

    /// One call on the session, and one more where the answer to labels sent together does not
    /// fit (`AppleTranslationJoining`). false = the session may be broken and is not used again.
    private func run(_ job: AppleTranslationJob, calling call: AppleTranslationCall, for host: AppleTranslationHost) async -> Bool {
        let packets = AppleTranslationJoining.packets(for: job.texts)
        running.append(job)
        let limit = UInt64(answerLimit * 1_000_000_000)
        let watch = Task { [weak self] in
            try? await Task.sleep(nanoseconds: limit)
            guard !Task.isCancelled else { return }
            self?.overdue(job, on: host)
        }
        defer {
            watch.cancel()
            running.removeAll { $0 === job }
        }
        var start = Self.clock
        var count = job.texts.count
        do {
            let texts = packets.map { AppleTranslationJoining.text(of: $0, in: job.texts) }
            let answers = try await Self.answers(to: texts, calling: call)
            Log.info(Self.callLine(job.pair, texts: count, requests: texts.count, milliseconds: Self.milliseconds(since: start)))
            var translations = [String?](repeating: nil, count: job.texts.count)
            var again: [Int] = []
            for (packet, answer) in zip(packets, answers) {
                guard let answer else { continue }
                if packet.count == 1 {
                    translations[packet[0]] = answer
                } else if let parts = AppleTranslationJoining.parts(of: answer, for: packet.map { job.texts[$0] }) {
                    for (position, part) in zip(packet, parts) { translations[position] = part }
                } else {
                    again += packet
                }
            }
            // Translate was turned off, or the call took too long: the job is answered already
            if !again.isEmpty, running.contains(where: { $0 === job }), !isEnding(host) {
                start = Self.clock
                count = again.count
                let single = try await Self.answers(to: again.map { job.texts[$0] }, calling: call)
                Log.info(Self.callLine(job.pair, texts: count, requests: count, milliseconds: Self.milliseconds(since: start))
                         + " (again one by one: the labels sent together did not come back apart)")
                for (position, answer) in zip(again, single) { translations[position] = answer }
            }
            job.finish(translations)
            return true
        } catch {
            Log.info("Translation: Apple \(job.pair): \(count) texts failed after "
                     + "\(Self.milliseconds(since: start)) ms (\(Self.describe(error)))")
            if isEnding(host) {
                // translating was turned off meanwhile, and the job is answered already
                job.finish(job.postponed)
            } else if Self.isCancellation(error) {
                // macOS asked the user after all (the languages were removed?) and got no for an answer
                declinedLoading(for: host)
                job.finish(job.postponed)
            } else if TranslationError.unsupportedLanguagePairing ~= error
                        || TranslationError.unsupportedSourceLanguage ~= error
                        || TranslationError.unsupportedTargetLanguage ~= error {
                pairSupport[host.pair] = false
                noteUntranslatable(host.source, to: clients(using: host.pair))
                job.finish(job.unchanged)
                finishWaitingJobs(of: host.pair) { $0.unchanged }
            } else {
                Log.error("Translation: \(host.pair) failed: \(Self.describe(error))")
                job.fail(TranslationFailure(message: String(localized: "Translation failed: \(error.localizedDescription)")))
            }
            return false
        }
    }

    /// One call for `texts`: the translation of each, in their order; nil where no response
    /// belongs to it. An empty translation stands for the text itself: it would blank the text
    /// on the screen.
    private static func answers(to texts: [String], calling call: AppleTranslationCall) async throws -> [String?] {
        let requests = texts.enumerated().map {
            TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
        }
        let responses = try await call(requests)
        var answers = [String?](repeating: nil, count: texts.count)
        for (position, response) in responses.enumerated() {
            // the identifier says which text a response belongs to; without one, the order does
            var index = response.clientIdentifier.flatMap { Int($0) }
            if index == nil, responses.count == texts.count { index = position }
            guard let index, answers.indices.contains(index) else { continue }
            let translation = response.targetText
            let isEmpty = translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            answers[index] = isEmpty ? texts[index] : translation
        }
        return answers
    }

    /// The log line of a call: "Translation: Apple de→en: 18 texts in 7 requests, 343 ms"
    static func callLine(_ pair: String, texts: Int, requests: Int, milliseconds: Int) -> String {
        "Translation: Apple \(pair): \(texts) texts in \(requests) requests, \(milliseconds) ms"
    }

    // MARK: Notices

    /// Shows a notice to each of `receivers` whose translating is on, once per turn of translating.
    private func note(_ key: String, _ message: String, to receivers: [AppleTranslationClient]) {
        for client in receivers where !client.isCancelled {
            guard client.noticed.insert(key).inserted, let handler = client.notify else { continue }
            handler(message)
        }
    }

    /// The clients that asked for a pair: they are told what becomes of it
    private func clients(using pair: String) -> [AppleTranslationClient] {
        activeClients.filter { $0.pairs.contains(pair) }
    }

    /// Without this the user would see nothing at all when the framework does not answer.
    private func noteNoAnswer(to client: AppleTranslationClient) {
        note("no answer", String(localized: "Translation on this Mac is not responding"), to: [client])
    }

    /// Tells each client whose translating is on why texts of its pairs stay untranslated for
    /// now, for as long as that lasts: macOS asks whether it may download the languages of a
    /// pair (or will ask once the question before is answered), or they are on their way.
    private func updateStatuses() {
        for client in activeClients {
            let waiting = hosts.filter { loading.contains($0.id) && client.pairs.contains($0.pair) }
            var status: String?
            if let host = waiting.first(where: { !downloading.contains($0.id) }) {
                status = askingNotice(for: host)
            } else if let host = waiting.first(where: { !missing.contains($0.id) }) {
                status = waitingNotice(for: host)
            } else if let host = waiting.first {
                status = missingNotice(for: host)
            }
            guard status != client.status else { continue }
            client.status = status
            client.notifyStatus?(status)
        }
    }

    /// The lasting notice while macOS asks: until the user answers, nothing loads
    func askingNotice(for host: AppleTranslationHost) -> String {
        let (sourceName, targetName) = noticeNames(for: host)
        return String(localized: "macOS asks whether it may download \(sourceName) and \(targetName) – answer its question")
    }

    /// The lasting notice once the user has answered: the languages may be downloading, or the
    /// question may have been closed without downloading them
    func waitingNotice(for host: AppleTranslationHost) -> String {
        let (sourceName, targetName) = noticeNames(for: host)
        return String(localized: "Translating starts once \(sourceName) and \(targetName) are on this Mac …")
    }

    /// The lasting notice when the languages are not there `downloadPatience` seconds after the answer
    func missingNotice(for host: AppleTranslationHost) -> String {
        let (sourceName, targetName) = noticeNames(for: host)
        return String(localized: "\(sourceName) and \(targetName) aren’t on this Mac yet – if they weren’t downloaded, turn translating off and on again to be asked once more")
    }

    /// The languages of a pair as macOS names them in its question: with the region where its
    /// models have another form of the language ("English (United Kingdom)" next to English (US))
    func noticeNames(for host: AppleTranslationHost) -> (source: String, target: String) {
        let list = host.strategy == .lowLatency ? languages.onDevice : languages.all
        func name(_ language: Locale.Language) -> String {
            let plain = LanguageMatching.name(of: language, in: Self.noticeLocale)
            guard !Self.otherForms(of: language, in: list).isEmpty,
                  let region = language.region ?? Locale.Language(identifier: language.maximalIdentifier).region,
                  let place = Self.noticeLocale.localizedString(forRegionCode: region.identifier) else { return plain }
            return "\(plain) (\(place))"
        }
        return (name(host.source), name(host.target))
    }

    private func noteNeedsAppleIntelligence(_ source: Locale.Language, _ target: Locale.Language,
                                            _ state: AppleIntelligence, to receivers: [AppleTranslationClient]) {
        note("needs Apple Intelligence " + Self.pair(source, target),
             Self.sourceNeedsAppleIntelligenceNotice(source, target, state), to: receivers)
    }

    /// Why nothing is translated into `target`: Apple Intelligence is off, or this Mac cannot
    /// run it, so that there is nothing to turn on
    static func targetNeedsAppleIntelligenceNotice(_ target: Locale.Language, _ state: AppleIntelligence) -> String {
        let language = fullName(of: target)
        return state == .notOnThisMac
            ? String(localized: "Translating into \(language) needs Apple Intelligence, which this Mac doesn’t support – choose another language")
            : String(localized: "Translating into \(language) needs Apple Intelligence – turn it on in System Settings, or choose another language")
    }

    /// Why texts in `source` stay as they are
    static func sourceNeedsAppleIntelligenceNotice(_ source: Locale.Language, _ target: Locale.Language,
                                                   _ state: AppleIntelligence) -> String {
        let sourceName = fullName(of: source), targetName = fullName(of: target)
        return state == .notOnThisMac
            ? String(localized: "Translating from \(sourceName) into \(targetName) needs Apple Intelligence, which this Mac doesn’t support")
            : String(localized: "Translating from \(sourceName) into \(targetName) needs Apple Intelligence – turn it on in System Settings")
    }

    /// "Danish", "English (India)": the region where the identifier names one, as macOS does in
    /// its question about Apple Intelligence
    private static func fullName(of language: Locale.Language) -> String {
        let name = LanguageMatching.name(of: language, in: noticeLocale)
        guard language.minimalIdentifier.contains("-"), let region = language.region?.identifier,
              let place = noticeLocale.localizedString(forRegionCode: region) else { return name }
        return "\(name) (\(place))"
    }

    private func noteUntranslatable(_ language: Locale.Language, to receivers: [AppleTranslationClient]) {
        let languageName = LanguageMatching.name(of: language, in: Self.noticeLocale)
        note("untranslatable " + LanguageMatching.key(language),
             String(localized: "\(languageName) can’t be translated on this Mac"), to: receivers)
    }

    /// The user said no, or the task of the view was cancelled
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }

    private static func milliseconds(since start: TimeInterval) -> Int {
        Int(((clock - start) * 1000).rounded())
    }

    /// Domain and code tell more about an error of the framework than its text
    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code): \(error.localizedDescription)"
    }

    // MARK: Languages of the texts

    /// What the language recognizer makes of the words of each text, and the language of the
    /// screen after these texts when it was `before` (nil = cannot be told). Only the words of a
    /// text are read (`LanguageMatching.wording`): names, numbers and identifiers say nothing
    /// about a language. The texts that decide nothing on their own (short labels) are read
    /// together as well, for the language of the screen. Takes a moment: call it off the main thread.
    nonisolated static func readLanguages(of texts: [String], tags: [String], supported: [Locale.Language],
                                          before: LanguageMatching.ScreenLanguage? = nil)
        -> (findings: [LanguageMatching.Finding], screen: LanguageMatching.ScreenLanguage?) {
        // one recognizer, used by this call only; it must not be shared between threads
        let recognizer = NLLanguageRecognizer()
        let constraints = tags.map { NLLanguage(rawValue: $0) }
        let wordings = texts.map(LanguageMatching.wording(of:))
        let findings = zip(texts, wordings).map { text, wording in
            finding(for: wording, letters: LanguageMatching.letterCount(text), with: recognizer,
                    constraints: constraints, supported: supported)
        }
        var evidence = findings
        var joint: LanguageMatching.Finding?
        if let words = LanguageMatching.jointWording(of: wordings, findings: findings) {
            // a list of settings for example: together the labels are long enough
            joint = finding(for: words, letters: words.letters, with: recognizer, constraints: constraints,
                            supported: supported)
            evidence.append(joint!)
        }
        let guess = LanguageMatching.screenGuess(of: findings, joint: joint)
        return (findings, LanguageMatching.screenLanguage(of: evidence, before: before, guess: guess))
    }

    /// What the recognizer says about the words of a text with `letters` letters in all
    private nonisolated static func finding(for wording: LanguageMatching.Wording, letters: Int,
                                            with recognizer: NLLanguageRecognizer, constraints: [NLLanguage],
                                            supported: [Locale.Language]) -> LanguageMatching.Finding {
        var open: [LanguageMatching.Hypothesis] = []
        var constrained: [LanguageMatching.Hypothesis] = []
        if wording.letters > 0 {
            recognizer.reset()
            recognizer.processString(wording.text)
            open = hypotheses(of: recognizer)
            // reset also removes the constraints
            recognizer.reset()
            recognizer.languageConstraints = constraints
            recognizer.processString(wording.text)
            constrained = hypotheses(of: recognizer)
        }
        return LanguageMatching.finding(of: wording, letters: letters, open: open, constrained: constrained,
                                        supported: supported)
    }

    private nonisolated static func hypotheses(of recognizer: NLLanguageRecognizer) -> [LanguageMatching.Hypothesis] {
        recognizer.languageHypotheses(withMaximum: 2).map {
            LanguageMatching.Hypothesis(tag: $0.key.rawValue, probability: $0.value)
        }
    }
}

/// One turn of translating of one mirror window, on the engine all windows share
/// (`AppleTranslationEngine.shared`). Its notices go to this turn only, and `cancel` ends this
/// turn's work only: the sessions stay for the other windows. Like the engines of the language
/// model services it serves one turn: once cancelled it answers every request with "not now".
final class AppleTranslationClient: TranslationEngine, @unchecked Sendable {
    let engine: AppleTranslationEngine
    /// The user chose the language in the settings: it is translated into as chosen. Otherwise it
    /// is the language of the system, which gets the closest form of the on-device models.
    let targetIsChosen: Bool
    let name = "Apple"
    let isRemote = false
    let prefersSettledText = false

    /// how the engine keeps its clients without keeping them alive
    struct Reference {
        weak var client: AppleTranslationClient?
    }

    /// protects `handler`, `statusHandler` and `cancelled`
    private let lock = NSLock()
    private var handler: ((String) -> Void)?
    private var statusHandler: ((String?) -> Void)?
    private var cancelled = false

    // Used by the engine, on the main actor only
    /// notices shown already
    fileprivate var noticed: Set<String> = []
    /// the language of the screen, for texts that do not have one of their own
    fileprivate var screenLanguage: LanguageMatching.ScreenLanguage?
    /// the language pairs this client asked for: it is told what becomes of them
    fileprivate var pairs: Set<String> = []
    /// the lasting notice given last
    fileprivate var status: String?

    init(engine: AppleTranslationEngine, targetIsChosen: Bool = false) {
        self.engine = engine
        self.targetIsChosen = targetIsChosen
    }

    var notify: ((String) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return handler
        }
        set {
            lock.lock()
            handler = newValue
            lock.unlock()
        }
    }

    var notifyStatus: ((String?) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return statusHandler
        }
        set {
            lock.lock()
            statusHandler = newValue
            lock.unlock()
        }
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func translate(_ texts: [String], into target: Locale.Language) async throws -> [String?] {
        guard !texts.isEmpty else { return [] }
        guard !isCancelled else { return [String?](repeating: nil, count: texts.count) }
        return try await engine.translate(texts, into: target, for: self)
    }

    func cancel() {
        lock.lock()
        let wasCancelled = cancelled
        cancelled = true
        lock.unlock()
        guard !wasCancelled else { return }
        let engine = self.engine
        // at once where possible, so that turning translating off and on again keeps its order
        if Thread.isMainThread {
            MainActor.assumeIsolated { engine.cancel(self) }
        } else {
            Task { @MainActor in engine.cancel(self) }
        }
    }
}

/// `translations(from:)` of a session: what `AppleTranslationEngine.work` asks of it
typealias AppleTranslationCall = @MainActor ([TranslationSession.Request]) async throws -> [TranslationSession.Response]

/// Which texts of a job go into the framework together, as one text, and how its answer is
/// split again.
///
/// The on-device models translate a single word without context badly ("Aus" (off) comes back
/// as "From", "An" (on) as "To", "Abbrechen" (cancel) as "Break off"), and a phone screen is
/// mostly short labels. Sent as one text, with `separator` between them, the labels of a screen
/// give each other the context, and the answer comes back with as many separators. Line breaks
/// do not do this: the framework translates each line alone.
///
/// The rule:
/// - A label is a text of at most `maximumWords` words (runs between white space) and at most
///   `maximumWeight` letters and digits, a letter of Chinese, Japanese or Korean counting
///   `LanguageMatching.denseLetterWeight` times; with no line break, no separator ("|" or its
///   full-width form "｜") and no sentence in it: it does not end with a full stop after a letter,
///   and no ".", "!" or "?" after a letter is followed by more text ("13. November" and "Fertig?"
///   are labels). Everything else goes alone, as before.
/// - The labels of a job go in its order, up to `groupSize` in one text, in as few texts as
///   possible and these as even as possible (13 labels are 7 and 6). A label with nothing to join
///   it to goes alone.
/// - An answer counts only if it splits at the separators into exactly as many parts as labels
///   went in, no part is empty, and no part is longer than `longestPart` for its label (4 times
///   its weight and 10 more: a separator that moved shifts words from one label to another).
///   Otherwise the labels of that text are sent once more, one by one, in one more call: a failure
///   costs one call, never a label that shows the translation of another.
///
/// Measured with German and English (US) on macOS 26.5, the only pair on the Mac it was made on,
/// with 141 German and 139 English texts of Android's Settings, a login page and a list of common
/// labels, through this engine: one by one 26 and 31 were wrong, with this rule 9 and 4. Six in a
/// text did worse than twelve (13 against 9 wrong into English), twenty no better. Labels of up to
/// six words gained most; summaries of 7 to 9 words came back as good or a little better joined,
/// sentences of 12 words and more as good alone, so these go alone, where an answer that does not
/// split would cost most. Every joined answer split into as many parts as went in. A label may
/// come back differently next to other labels: in shuffled screens about one in ten turned right
/// or wrong with its neighbours, and the order of the screen (a row's title next to its summary)
/// did best; the tracker keeps the translation of a text for the turn. Names, numbers and texts
/// in the target language inside a joined text came back as they were ("Google", "T-Mobile",
/// "sdk_gphone64_arm64", "IMEI"); alone, "sdk_gphone64_arm64" came back as "Sdk_gphone64_arm64"
/// and "Google" into German as "Googeln". Other pairs could not be measured: should one of them
/// not keep the separators, the labels are translated one by one as before.
enum AppleTranslationJoining {
    static let separator = " | "
    /// what an answer is split at: the separator, and the full-width form a translation into
    /// Chinese or Japanese may give it
    private static let marks: Set<Character> = ["|", "｜"]
    static let groupSize = 12
    static let maximumWords = 6
    static let maximumWeight = 50

    /// The positions of `texts` that go into the framework together, one entry per text sent,
    /// in the order of their first position
    static func packets(for texts: [String]) -> [[Int]] {
        let labels = texts.indices.filter { isLabel(texts[$0]) }
        guard labels.count >= 2 else { return texts.indices.map { [$0] } }
        var packets = texts.indices.filter { !isLabel(texts[$0]) }.map { [$0] }
        var start = 0
        let count = (labels.count + groupSize - 1) / groupSize
        for made in 0..<count {
            let left = count - made
            let size = (labels.count - start + left - 1) / left
            packets.append(Array(labels[start..<(start + size)]))
            start += size
        }
        return packets.sorted { $0[0] < $1[0] }
    }

    /// What is sent for a packet
    static func text(of packet: [Int], in texts: [String]) -> String {
        packet.map { texts[$0] }.joined(separator: separator)
    }

    static func isLabel(_ text: String) -> Bool {
        guard !text.contains(where: { marks.contains($0) || $0.isNewline }) else { return false }
        let words = text.split(whereSeparator: \.isWhitespace).count
        return words >= 1 && words <= maximumWords && weight(of: text) <= maximumWeight && !holdsASentence(text)
    }

    /// Ends with a full stop after a letter, or a sentence after a letter is followed by more text
    static func holdsASentence(_ text: String) -> Bool {
        let characters = Array(text.trimmingCharacters(in: .whitespaces))
        for index in characters.indices.dropFirst() where characters[index - 1].isLetter {
            let character = characters[index]
            if index == characters.count - 1 {
                if character == "." || character == "。" || character == "｡" { return true }
            } else if ".!?。！？".contains(character), characters[index + 1].isWhitespace {
                return true
            }
        }
        return false
    }

    /// The translations of `labels`, sent as one text, from its `answer`; nil = the answer is
    /// not to be trusted
    static func parts(of answer: String, for labels: [String]) -> [String]? {
        let parts = answer.split(omittingEmptySubsequences: false, whereSeparator: { marks.contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == labels.count else { return nil }
        for (part, label) in zip(parts, labels) where part.isEmpty || weight(of: part) > longestPart(for: label) {
            return nil
        }
        return parts
    }

    /// The weight of the longest translation of `label` that is believed (measured up to 3.3
    /// times its weight: "Add" as "Hinzufügen", and 25 more: "Legal & regulatory" as "Rechtliche
    /// und regulatorische Informationen")
    static func longestPart(for label: String) -> Int {
        4 * max(weight(of: label), 1) + 10
    }

    /// Letters and digits, a letter of Chinese, Japanese or Korean `LanguageMatching.denseLetterWeight` times
    static func weight(of text: String) -> Int {
        text.reduce(0) { sum, character in
            if character.isLetter { return sum + LanguageMatching.letterWeight(character) }
            return character.isNumber ? sum + 1 : sum
        }
    }
}

/// Apple's kinds of translation models. Before macOS 26.4 there are only the on-device ones,
/// and nothing is said about the kind.
enum AppleTranslationStrategy: Equatable {
    /// the on-device models: fast, and without Apple Intelligence
    case lowLatency
    /// the models that need Apple Intelligence for many of their languages
    case highFidelity

    @available(macOS 26.4, *)
    var framework: TranslationSession.Strategy {
        self == .lowLatency ? .lowLatency : .highFidelity
    }
}

/// The languages macOS translates, by kind of models
struct AppleTranslationLanguages {
    /// those of the on-device models, which the engine prefers
    let onDevice: [Locale.Language]
    /// those of all models, the on-device ones included
    let all: [Locale.Language]

    init(onDevice: [Locale.Language], all: [Locale.Language]) {
        self.onDevice = onDevice
        let keys = Set(all.map(LanguageMatching.key))
        self.all = all + onDevice.filter { !keys.contains(LanguageMatching.key($0)) }
    }

    /// one kind of models only (before macOS 26.4)
    init(_ languages: [Locale.Language]) {
        self.init(onDevice: languages, all: languages)
    }

    var isEmpty: Bool { all.isEmpty }

    /// the lists in the order a language is looked for in them
    var lists: [[Locale.Language]] { [onDevice, all] }

    /// The on-device models where they know both languages, the others only for a language that
    /// only they have. `source` and `target` are entries of the lists.
    func strategy(from source: Locale.Language, to target: Locale.Language) -> AppleTranslationStrategy {
        isOnDevice(source) && isOnDevice(target) ? .lowLatency : .highFidelity
    }

    func isOnDevice(_ language: Locale.Language) -> Bool {
        let key = LanguageMatching.key(language)
        return onDevice.contains { LanguageMatching.key($0) == key }
    }
}

/// What `AppleTranslationEngine` asks macOS about its languages
struct AppleTranslationAvailability {
    var languages: () async -> AppleTranslationLanguages
    var status: (_ source: Locale.Language, _ target: Locale.Language,
                 _ strategy: AppleTranslationStrategy) async -> LanguageAvailability.Status
    /// what this Mac says about Apple Intelligence, which the models of `.highFidelity` need for
    /// many languages
    var appleIntelligence: () -> AppleIntelligence

    /// the answers of macOS
    static var system: AppleTranslationAvailability {
        AppleTranslationAvailability(languages: { await systemLanguages() },
                                     status: { source, target, strategy in
            if #available(macOS 26.4, *) {
                return await LanguageAvailability(preferredStrategy: strategy.framework).status(from: source, to: target)
            }
            return await LanguageAvailability().status(from: source, to: target)
        }, appleIntelligence: { systemAppleIntelligence() })
    }

    /// Translation says nothing about it: what Foundation Models says about the language model
    /// of Apple Intelligence stands in. Its models still on their way count as on, macOS says
    /// then what is missing. (Before macOS 26.4 Translation has no models that need it.)
    static func systemAppleIntelligence() -> AppleIntelligence {
        guard #available(macOS 26.4, *) else { return .notOnThisMac }
        return AppleIntelligence(SystemLanguageModel.default.availability)
    }

    /// From macOS 26.4 on, a LanguageAvailability without a strategy answers for `.highFidelity`:
    /// both kinds are asked for by name.
    static func systemLanguages() async -> AppleTranslationLanguages {
        if #available(macOS 26.4, *) {
            let onDevice = await LanguageAvailability(preferredStrategy: .lowLatency).supportedLanguages
            let all = await LanguageAvailability(preferredStrategy: .highFidelity).supportedLanguages
            return AppleTranslationLanguages(onDevice: onDevice, all: all)
        }
        return AppleTranslationLanguages(await LanguageAvailability().supportedLanguages)
    }
}

/// Whether the models of Translation that need Apple Intelligence can be used on this Mac
enum AppleIntelligence: Equatable {
    case on
    /// this Mac can run it, and it can be turned on in System Settings
    case off
    /// this Mac cannot run it: there is nothing to turn on
    case notOnThisMac

    @available(macOS 26.0, *)
    init(_ availability: SystemLanguageModel.Availability) {
        switch availability {
        case .unavailable(.deviceNotEligible): self = .notOnThisMac
        case .unavailable(.appleIntelligenceNotEnabled): self = .off
        default: self = .on
        }
    }
}

/// Gives a continuation the first of several answers and drops the others.
private final class AppleTranslationFirstAnswer<Answer>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Answer?, Never>?

    init(_ continuation: CheckedContinuation<Answer?, Never>) {
        self.continuation = continuation
    }

    func give(_ answer: Answer?) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: answer)
    }
}

/// Wakes the `serve` of one host; finished = the host has to end
private struct AppleTranslationSignal {
    let stream: AsyncStream<Void>
    let wake: AsyncStream<Void>.Continuation
}

/// Texts in one language that wait for the session of their pair
private final class AppleTranslationJob {
    /// whose request it is
    let client: AppleTranslationClient
    let pair: String
    let source: Locale.Language
    let target: Locale.Language
    let strategy: AppleTranslationStrategy
    let texts: [String]
    private var continuation: CheckedContinuation<[String?], Error>?

    init(client: AppleTranslationClient, pair: String, source: Locale.Language, target: Locale.Language,
         strategy: AppleTranslationStrategy, texts: [String]) {
        self.client = client
        self.pair = pair
        self.source = source
        self.target = target
        self.strategy = strategy
        self.texts = texts
    }

    /// "not now" for every text: the caller asks again
    var postponed: [String?] { [String?](repeating: nil, count: texts.count) }
    /// "leave them as they are": the caller does not ask again
    var unchanged: [String?] { texts.map { Optional($0) } }

    func wait(for continuation: CheckedContinuation<[String?], Error>) {
        self.continuation = continuation
    }

    /// Only the first answer counts: a job may be answered for its session when translating is
    /// turned off or the session takes too long.
    func finish(_ translations: [String?]) {
        continuation?.resume(returning: translations)
        continuation = nil
    }

    func fail(_ error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

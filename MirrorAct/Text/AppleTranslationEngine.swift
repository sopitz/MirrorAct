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
    /// hosts of `loading` whose question was answered: their languages are on their way
    private var downloading: Set<UUID> = []
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
        let read = await Task.detached(priority: .userInitiated) {
            AppleTranslationEngine.readLanguages(of: texts, tags: tags, supported: all)
        }.value
        if let common = read.common { client.commonLanguage = common }
        // the languages on the screen, too, as the on-device models know them where they can
        let plan = LanguageMatching.Plan(findings: read.findings, common: client.commonLanguage, target: target,
                                         lists: languages.lists)
        var results = plan.results(for: texts)
        for language in plan.unknown { noteUntranslatable(language, to: [client]) }

        // one job per language; their sessions work side by side
        var pending: [(group: LanguageMatching.Plan.Group, answer: Task<[String?], Error>)] = []
        for group in plan.groups {
            let pair = Self.pair(group.source, target)
            let strategy = languages.strategy(from: group.source, to: target)
            client.pairs.insert(pair)
            let groupTexts = group.indices.map { texts[$0] }
            if strategy == .highFidelity {
                let state = appleIntelligenceState()
                guard state == .on else {
                    // the language of these texts only the models that need Apple Intelligence
                    // know: they stay as they are
                    group.place(groupTexts.map { Optional($0) }, in: &results)
                    noteNeedsAppleIntelligence(group.source, target, state, to: [client])
                    continue
                }
            }
            guard let translatable = await isSupported(pair, from: group.source, to: target, with: strategy) else {
                noteNoAnswer(to: client)
                continue
            }
            guard translatable else {
                // nothing to be done for this language: its texts stay, and are not asked for again
                group.place(groupTexts.map { Optional($0) }, in: &results)
                noteUntranslatable(group.source, to: [client])
                continue
            }
            // turned off meanwhile, or the languages are not on this Mac (yet): nil, the caller asks again
            if Task.isCancelled || client.isCancelled { continue }
            if isPostponed(pair) {
                // a client that asks only after the loading began is told as well
                if isLoading(pair) { updateStatuses() }
                continue
            }
            let job = AppleTranslationJob(client: client, pair: pair, source: group.source, target: target,
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
            appleIntelligence = nil
            clients[key] = AppleTranslationClient.Reference(client: client)
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

    /// A host of the pair waits for macOS to load its languages
    private func isLoading(_ pair: String) -> Bool {
        hosts.contains { $0.pair == pair && loading.contains($0.id) }
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
            if !keepsWindowOnScreen, let window {
                keepsWindowOnScreen = true
                Log.info("Translation: moving the window of the views onto the screen")
                AppleTranslationHostWindow.place(window, onScreen: true)
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
            if window == nil { window = makeWindow(self) }
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
        let wasLoading = !loading.isEmpty
        if isLoading {
            loading.insert(host.id)
        } else {
            loading.remove(host.id)
            downloading.remove(host.id)
        }
        updateStatuses()
        // macOS may attach its question about loading languages to the window that asks: it has
        // to be on a screen for that long, and above mirror windows that are kept on top
        if wasLoading != !loading.isEmpty, let window {
            if !keepsWindowOnScreen { AppleTranslationHostWindow.place(window, onScreen: !loading.isEmpty) }
            AppleTranslationHostWindow.raise(window, !loading.isEmpty)
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
                    work: { await self.work(for: host, with: session) })
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
                // prepareTranslation also returns while the languages are still on their way
                downloading.insert(host.id)
                updateStatuses()
                let start = Self.clock
                status = await availability.status(host.source, host.target, host.strategy)
                while status == .supported, !isEnding(host), Self.clock - start < loadingLimit {
                    try? await Task.sleep(nanoseconds: UInt64(loadingCheckInterval * 1_000_000_000))
                    status = await availability.status(host.source, host.target, host.strategy)
                }
                if status == .supported, !isEnding(host) {
                    setLoading(false, for: host)
                    blockedUntil[host.pair] = Self.clock + retryPause
                    Log.error("Translation: the languages for \(host.pair) are not there after \(Int(loadingLimit)) s")
                    note("not loaded " + host.pair, String(localized: "Loading \(language) failed"),
                         to: clients(using: host.pair))
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

    /// The user closed the question of macOS or its progress window: not now. Nothing is asked
    /// again until translating is turned off and on.
    private func declinedLoading(for host: AppleTranslationHost) {
        declined.insert(host.pair)
        Log.info("Translation: the languages for \(host.pair) were not loaded (cancelled)")
        let language = LanguageMatching.name(of: host.source, in: Self.noticeLocale)
        note("declined " + host.pair,
             String(localized: "\(language) is not loaded yet – turn translating on again to load it"),
             to: clients(using: host.pair))
        finishWaitingJobs(of: host.pair) { $0.postponed }
    }

    /// Translates the jobs of the pair as they come, until the host has to end.
    private func work(for host: AppleTranslationHost, with session: TranslationSession) async {
        guard let signal = signals[host.id] else { return }
        var idle = idleTimer(for: host)
        // woken once when the host was made, so jobs that were queued before the view started are seen
        for await _ in signal.stream {
            idle.cancel()
            var intact = true
            while intact, !isEnding(host), let job = takeJob(for: host.pair) {
                intact = await run(job, on: session, for: host)
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

    /// One call on the session. false = the session may be broken and is not used again.
    private func run(_ job: AppleTranslationJob, on session: TranslationSession, for host: AppleTranslationHost) async -> Bool {
        var requests: [TranslationSession.Request] = []
        for (index, text) in job.texts.enumerated() {
            requests.append(TranslationSession.Request(sourceText: text, clientIdentifier: String(index)))
        }
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
        do {
            let responses = try await session.translations(from: requests)
            var translations = [String?](repeating: nil, count: job.texts.count)
            for (position, response) in responses.enumerated() {
                // the identifier says which text a response belongs to; without one, the order does
                var index = response.clientIdentifier.flatMap { Int($0) }
                if index == nil, responses.count == job.texts.count { index = position }
                guard let index, translations.indices.contains(index) else { continue }
                let translation = response.targetText
                // an empty translation would blank the text on the screen
                let isEmpty = translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                translations[index] = isEmpty ? job.texts[index] : translation
            }
            job.finish(translations)
            return true
        } catch {
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
                status = Self.askingNotice(host.source, host.target)
            } else if let host = waiting.first {
                status = Self.downloadingNotice(host.source, host.target)
            }
            guard status != client.status else { continue }
            client.status = status
            client.notifyStatus?(status)
        }
    }

    /// The lasting notice while macOS asks: until the user answers, nothing loads
    static func askingNotice(_ source: Locale.Language, _ target: Locale.Language) -> String {
        let sourceName = LanguageMatching.name(of: source, in: noticeLocale)
        let targetName = LanguageMatching.name(of: target, in: noticeLocale)
        return String(localized: "macOS asks whether it may download \(sourceName) and \(targetName) – answer its question")
    }

    /// The lasting notice once the user has agreed
    static func downloadingNotice(_ source: Locale.Language, _ target: Locale.Language) -> String {
        let sourceName = LanguageMatching.name(of: source, in: noticeLocale)
        let targetName = LanguageMatching.name(of: target, in: noticeLocale)
        return String(localized: "Downloading \(sourceName) and \(targetName) for translating …")
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

    /// Domain and code tell more about an error of the framework than its text
    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code): \(error.localizedDescription)"
    }

    // MARK: Languages of the texts

    /// What the language recognizer makes of each text, and the language the texts have in
    /// common (nil = cannot be told). Takes a moment: call it off the main thread.
    nonisolated static func readLanguages(of texts: [String], tags: [String], supported: [Locale.Language])
        -> (findings: [LanguageMatching.Finding], common: Locale.Language?) {
        // one recognizer, used by this call only; it must not be shared between threads
        let recognizer = NLLanguageRecognizer()
        let constraints = tags.map { NLLanguage(rawValue: $0) }
        let findings = texts.map { finding(for: [$0], with: recognizer, constraints: constraints, supported: supported) }
        var common = LanguageMatching.prevailingLanguage(of: findings)
        if common == nil, texts.count > 1 {
            // nothing but short texts, a list of settings for example: together they are long enough
            common = finding(for: texts, with: recognizer, constraints: constraints, supported: supported).decided
        }
        return (findings, common)
    }

    /// `texts` are read as one text.
    private nonisolated static func finding(for texts: [String], with recognizer: NLLanguageRecognizer,
                                            constraints: [NLLanguage], supported: [Locale.Language]) -> LanguageMatching.Finding {
        recognizer.reset()
        for text in texts { recognizer.processString(text) }
        let open = hypotheses(of: recognizer)
        // reset also removes the constraints
        recognizer.reset()
        recognizer.languageConstraints = constraints
        for text in texts { recognizer.processString(text) }
        let constrained = hypotheses(of: recognizer)
        let letters = texts.reduce(0) { $0 + LanguageMatching.letterCount($1) }
        return LanguageMatching.finding(letters: letters, open: open, constrained: constrained, supported: supported)
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
    /// the language most of the last requests was in, for texts too short to tell
    fileprivate var commonLanguage: Locale.Language?
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
